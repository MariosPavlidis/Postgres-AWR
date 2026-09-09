\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION dba_mon._html_escape(p_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
RETURN replace(replace(replace(replace(replace(coalesce(p_value, ''),
  '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;');

CREATE OR REPLACE FUNCTION dba_mon.report_interval(
  p_begin_snapshot_id bigint,
  p_end_snapshot_id bigint
) RETURNS TABLE (
  cluster_id bigint,
  cluster_name text,
  begin_snapshot_id bigint,
  end_snapshot_id bigint,
  begin_time timestamptz,
  end_time timestamptz,
  interval_seconds numeric,
  begin_status text,
  end_status text,
  server_version text,
  collector_version text,
  in_recovery boolean,
  restart_crossed boolean,
  database_stats_reset_crossed boolean,
  pgss_reset_crossed boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, dba_mon
AS $$
BEGIN
  IF p_begin_snapshot_id IS NULL OR p_end_snapshot_id IS NULL
     OR p_begin_snapshot_id >= p_end_snapshot_id THEN
    RAISE EXCEPTION 'begin snapshot (%) must be lower than end snapshot (%)',
      p_begin_snapshot_id, p_end_snapshot_id USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM dba_mon.snapshot WHERE snapshot_id = p_begin_snapshot_id)
     OR NOT EXISTS (SELECT 1 FROM dba_mon.snapshot WHERE snapshot_id = p_end_snapshot_id) THEN
    RAISE EXCEPTION 'snapshot endpoint not found: begin %, end %',
      p_begin_snapshot_id, p_end_snapshot_id USING ERRCODE = '22023';
  END IF;

  IF (SELECT s.cluster_id FROM dba_mon.snapshot AS s
      WHERE s.snapshot_id = p_begin_snapshot_id)
     IS DISTINCT FROM
     (SELECT s.cluster_id FROM dba_mon.snapshot AS s
      WHERE s.snapshot_id = p_end_snapshot_id) THEN
    RAISE EXCEPTION 'snapshot endpoints belong to different clusters'
      USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT b.cluster_id, c.cluster_name, b.snapshot_id, e.snapshot_id,
         b.started_at, e.started_at,
         extract(epoch FROM e.started_at - b.started_at)::numeric,
         b.status, e.status, e.server_version, e.collector_version,
         e.in_recovery,
         b.postmaster_start_time IS DISTINCT FROM e.postmaster_start_time,
         b.stats_reset IS DISTINCT FROM e.stats_reset,
         b.pgss_stats_reset IS DISTINCT FROM e.pgss_stats_reset
  FROM dba_mon.snapshot AS b
  JOIN dba_mon.snapshot AS e ON e.snapshot_id = p_end_snapshot_id
  JOIN dba_mon.cluster_target AS c ON c.cluster_id = b.cluster_id
  WHERE b.snapshot_id = p_begin_snapshot_id;
END;
$$;

CREATE OR REPLACE FUNCTION dba_mon.report_quality(
  p_begin_snapshot_id bigint,
  p_end_snapshot_id bigint
) RETURNS TABLE (severity text, check_name text, message text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, dba_mon
AS $$
  WITH i AS (
    SELECT * FROM dba_mon.report_interval($1, $2)
  ), checks AS (
    SELECT CASE WHEN begin_status = 'SUCCESS' THEN 'OK' ELSE 'ERROR' END AS severity,
           'begin_snapshot_status'::text AS check_name,
           ('Begin snapshot status is ' || begin_status)::text AS message FROM i
    UNION ALL
    SELECT CASE WHEN end_status = 'SUCCESS' THEN 'OK' ELSE 'ERROR' END,
           'end_snapshot_status', 'End snapshot status is ' || end_status FROM i
    UNION ALL
    SELECT CASE WHEN restart_crossed THEN 'ERROR' ELSE 'OK' END,
           'postgresql_restart', CASE WHEN restart_crossed
             THEN 'PostgreSQL restarted between endpoints; cumulative deltas are invalid'
             ELSE 'No PostgreSQL restart detected' END FROM i
    UNION ALL
    SELECT CASE WHEN database_stats_reset_crossed THEN 'ERROR' ELSE 'OK' END,
           'database_statistics_reset', CASE WHEN database_stats_reset_crossed
             THEN 'Database statistics reset marker changed between endpoints'
             ELSE 'Database statistics reset marker is stable' END FROM i
    UNION ALL
    SELECT CASE WHEN pgss_reset_crossed THEN 'ERROR' ELSE 'OK' END,
           'pgss_reset', CASE WHEN pgss_reset_crossed
             THEN 'pg_stat_statements reset marker changed between endpoints'
             ELSE 'pg_stat_statements reset marker is stable' END FROM i
    UNION ALL
    SELECT CASE WHEN actual_samples>=greatest(1,floor(interval_seconds/10)*0.8) THEN 'OK' ELSE 'WARNING' END,
           'wait_sampling_coverage',format('%s of approximately %s expected ten-second samples captured',
             actual_samples,greatest(1,floor(interval_seconds/10)))
    FROM i CROSS JOIN LATERAL (
      SELECT count(DISTINCT sampled_at) actual_samples
      FROM dba_mon.wait_sample w
      WHERE w.cluster_id=i.cluster_id AND w.sampled_at>=i.begin_time AND w.sampled_at<=i.end_time
    ) ws
    UNION ALL
    SELECT 'ERROR', 'failed_component',
           format('Snapshot %s component %s target %s failed: %s',
             cc.snapshot_id, cc.component,
             coalesce(cc.database_target_id::text, 'cluster'),
             coalesce(cc.error_message, 'no message'))
    FROM dba_mon.capture_component AS cc
    WHERE cc.snapshot_id IN ($1, $2) AND cc.status = 'FAILED'
    UNION ALL
    SELECT 'WARNING', 'skipped_component',
           format('Snapshot %s component %s target %s was skipped',
             cc.snapshot_id, cc.component,
             coalesce(cc.database_target_id::text, 'cluster'))
    FROM dba_mon.capture_component AS cc
    WHERE cc.snapshot_id IN ($1, $2) AND cc.status = 'SKIPPED'
  )
  SELECT checks.severity, checks.check_name, checks.message FROM checks;
$$;

CREATE OR REPLACE FUNCTION dba_mon.report_pgss_delta(
  p_begin_snapshot_id bigint,
  p_end_snapshot_id bigint
) RETURNS TABLE (
  database_target_id bigint,
  database_name name,
  userid oid,
  dbid oid,
  toplevel boolean,
  queryid bigint,
  query text,
  calls bigint,
  total_exec_time_ms double precision,
  mean_exec_time_ms double precision,
  rows bigint,
  shared_blks_read bigint,
  shared_blks_hit bigint,
  temp_blks_written bigint,
  wal_bytes numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, dba_mon
AS $$
  SELECT e.database_target_id, dt.database_name, e.userid, e.dbid,
         e.toplevel, e.queryid, e.query,
         e.calls - b.calls,
         e.total_exec_time - b.total_exec_time,
         (e.total_exec_time - b.total_exec_time) / NULLIF(e.calls - b.calls, 0),
         e.rows - b.rows,
         e.shared_blks_read - b.shared_blks_read,
         e.shared_blks_hit - b.shared_blks_hit,
         e.temp_blks_written - b.temp_blks_written,
         e.wal_bytes - b.wal_bytes
  FROM dba_mon.pgss_snap AS b
  JOIN dba_mon.pgss_snap AS e
    ON e.database_target_id = b.database_target_id
   AND e.userid = b.userid AND e.dbid = b.dbid
   AND e.toplevel = b.toplevel AND e.queryid = b.queryid
  JOIN dba_mon.database_target AS dt
    ON dt.database_target_id = e.database_target_id
  WHERE b.snapshot_id = $1 AND e.snapshot_id = $2
    AND EXISTS (SELECT 1 FROM dba_mon.snapshot sb,dba_mon.snapshot se
                WHERE sb.snapshot_id=$1 AND se.snapshot_id=$2
                  AND sb.postmaster_start_time=se.postmaster_start_time
                  AND sb.pgss_stats_reset IS NOT DISTINCT FROM se.pgss_stats_reset)
    AND e.calls >= b.calls
    AND e.total_exec_time >= b.total_exec_time
    AND e.rows >= b.rows
    AND e.shared_blks_read >= b.shared_blks_read
    AND e.shared_blks_hit >= b.shared_blks_hit
    AND e.temp_blks_written >= b.temp_blks_written
    AND e.wal_bytes >= b.wal_bytes;
$$;

CREATE OR REPLACE FUNCTION dba_mon.report_database_delta(
  p_begin_snapshot_id bigint, p_end_snapshot_id bigint
) RETURNS TABLE (
  datid oid, datname name, xact_commit bigint, xact_rollback bigint,
  blks_read bigint, blks_hit bigint, cache_hit_pct numeric,
  tup_returned bigint, tup_fetched bigint, tup_inserted bigint,
  tup_updated bigint, tup_deleted bigint, temp_files bigint,
  temp_bytes bigint, deadlocks bigint, sessions bigint,
  sessions_abandoned bigint, sessions_fatal bigint, sessions_killed bigint
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, dba_mon
AS $$
  SELECT e.datid, e.datname,
         e.xact_commit-b.xact_commit, e.xact_rollback-b.xact_rollback,
         e.blks_read-b.blks_read, e.blks_hit-b.blks_hit,
         round(100.0*(e.blks_hit-b.blks_hit) /
           NULLIF((e.blks_hit-b.blks_hit)+(e.blks_read-b.blks_read),0),2),
         e.tup_returned-b.tup_returned, e.tup_fetched-b.tup_fetched,
         e.tup_inserted-b.tup_inserted, e.tup_updated-b.tup_updated,
         e.tup_deleted-b.tup_deleted, e.temp_files-b.temp_files,
         e.temp_bytes-b.temp_bytes, e.deadlocks-b.deadlocks,
         e.sessions-b.sessions, e.sessions_abandoned-b.sessions_abandoned,
         e.sessions_fatal-b.sessions_fatal, e.sessions_killed-b.sessions_killed
  FROM dba_mon.database_snap b JOIN dba_mon.database_snap e USING(datid)
  WHERE b.snapshot_id=$1 AND e.snapshot_id=$2
    AND EXISTS (SELECT 1 FROM dba_mon.snapshot sb,dba_mon.snapshot se
                WHERE sb.snapshot_id=$1 AND se.snapshot_id=$2
                  AND sb.postmaster_start_time=se.postmaster_start_time)
    AND b.stats_reset IS NOT DISTINCT FROM e.stats_reset
    AND e.xact_commit>=b.xact_commit AND e.xact_rollback>=b.xact_rollback
    AND e.blks_read>=b.blks_read AND e.blks_hit>=b.blks_hit
    AND e.tup_returned>=b.tup_returned AND e.tup_fetched>=b.tup_fetched
    AND e.tup_inserted>=b.tup_inserted AND e.tup_updated>=b.tup_updated
    AND e.tup_deleted>=b.tup_deleted AND e.temp_files>=b.temp_files
    AND e.temp_bytes>=b.temp_bytes AND e.deadlocks>=b.deadlocks;
$$;

CREATE OR REPLACE FUNCTION dba_mon.report_wal_delta(
  p_begin_snapshot_id bigint, p_end_snapshot_id bigint
) RETURNS TABLE (wal_records bigint, wal_fpi bigint, wal_bytes numeric,
                 wal_buffers_full bigint)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, dba_mon
AS $$
 SELECT e.wal_records-b.wal_records, e.wal_fpi-b.wal_fpi,
        e.wal_bytes-b.wal_bytes, e.wal_buffers_full-b.wal_buffers_full
 FROM dba_mon.wal_snap b JOIN dba_mon.wal_snap e ON true
 WHERE b.snapshot_id=$1 AND e.snapshot_id=$2
   AND EXISTS (SELECT 1 FROM dba_mon.snapshot sb,dba_mon.snapshot se
               WHERE sb.snapshot_id=$1 AND se.snapshot_id=$2
                 AND sb.postmaster_start_time=se.postmaster_start_time)
   AND b.stats_reset IS NOT DISTINCT FROM e.stats_reset
   AND e.wal_records>=b.wal_records AND e.wal_fpi>=b.wal_fpi
   AND e.wal_bytes>=b.wal_bytes AND e.wal_buffers_full>=b.wal_buffers_full;
$$;

CREATE OR REPLACE FUNCTION dba_mon.report_checkpointer_delta(
  p_begin_snapshot_id bigint, p_end_snapshot_id bigint
) RETURNS TABLE (num_timed bigint, num_requested bigint, num_done bigint,
  restartpoints_timed bigint, restartpoints_requested bigint,
  restartpoints_done bigint, write_time_ms double precision,
  sync_time_ms double precision, buffers_written bigint)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, dba_mon
AS $$
 SELECT e.num_timed-b.num_timed, e.num_requested-b.num_requested,
        CASE WHEN e.num_done IS NULL OR b.num_done IS NULL THEN NULL
             ELSE e.num_done-b.num_done END,
        e.restartpoints_timed-b.restartpoints_timed,
        e.restartpoints_requested-b.restartpoints_requested,
        e.restartpoints_done-b.restartpoints_done,
        e.write_time-b.write_time, e.sync_time-b.sync_time,
        e.buffers_written-b.buffers_written
 FROM dba_mon.checkpointer_snap b JOIN dba_mon.checkpointer_snap e ON true
 WHERE b.snapshot_id=$1 AND e.snapshot_id=$2
   AND EXISTS (SELECT 1 FROM dba_mon.snapshot sb,dba_mon.snapshot se
               WHERE sb.snapshot_id=$1 AND se.snapshot_id=$2
                 AND sb.postmaster_start_time=se.postmaster_start_time)
   AND b.stats_reset IS NOT DISTINCT FROM e.stats_reset
   AND e.num_timed>=b.num_timed AND e.num_requested>=b.num_requested
   AND (e.num_done IS NULL OR b.num_done IS NULL OR e.num_done>=b.num_done)
   AND e.restartpoints_timed>=b.restartpoints_timed
   AND e.restartpoints_requested>=b.restartpoints_requested
   AND e.restartpoints_done>=b.restartpoints_done
   AND e.write_time>=b.write_time AND e.sync_time>=b.sync_time
   AND e.buffers_written>=b.buffers_written;
$$;

CREATE OR REPLACE FUNCTION dba_mon.report_bgwriter_delta(
  p_begin_snapshot_id bigint, p_end_snapshot_id bigint
) RETURNS TABLE (buffers_clean bigint, maxwritten_clean bigint,
                 buffers_alloc bigint)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, dba_mon
AS $$
 SELECT e.buffers_clean-b.buffers_clean,
        e.maxwritten_clean-b.maxwritten_clean,
        e.buffers_alloc-b.buffers_alloc
 FROM dba_mon.bgwriter_snap b JOIN dba_mon.bgwriter_snap e ON true
 WHERE b.snapshot_id=$1 AND e.snapshot_id=$2
   AND EXISTS (SELECT 1 FROM dba_mon.snapshot sb,dba_mon.snapshot se
               WHERE sb.snapshot_id=$1 AND se.snapshot_id=$2
                 AND sb.postmaster_start_time=se.postmaster_start_time)
   AND b.stats_reset IS NOT DISTINCT FROM e.stats_reset
   AND e.buffers_clean>=b.buffers_clean
   AND e.maxwritten_clean>=b.maxwritten_clean
   AND e.buffers_alloc>=b.buffers_alloc;
$$;

CREATE OR REPLACE FUNCTION dba_mon.report_archiver_delta(
  p_begin_snapshot_id bigint, p_end_snapshot_id bigint
) RETURNS TABLE (archived_count bigint, failed_count bigint,
  last_archived_wal text, last_archived_time timestamptz,
  last_failed_wal text, last_failed_time timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, dba_mon
AS $$
 SELECT e.archived_count-b.archived_count,e.failed_count-b.failed_count,
        e.last_archived_wal,e.last_archived_time,e.last_failed_wal,e.last_failed_time
 FROM dba_mon.archiver_snap b JOIN dba_mon.archiver_snap e ON true
 WHERE b.snapshot_id=$1 AND e.snapshot_id=$2
   AND EXISTS (SELECT 1 FROM dba_mon.snapshot sb,dba_mon.snapshot se
               WHERE sb.snapshot_id=$1 AND se.snapshot_id=$2
                 AND sb.postmaster_start_time=se.postmaster_start_time)
   AND b.stats_reset IS NOT DISTINCT FROM e.stats_reset
   AND e.archived_count>=b.archived_count AND e.failed_count>=b.failed_count;
$$;

CREATE OR REPLACE FUNCTION dba_mon.report_io_delta(
  p_begin_snapshot_id bigint, p_end_snapshot_id bigint
) RETURNS TABLE (backend_type text, object text, context text,
  reads bigint, read_bytes numeric, read_time_ms double precision,
  writes bigint, write_bytes numeric, write_time_ms double precision,
  extends bigint, extend_bytes numeric, hits bigint, evictions bigint,
  fsyncs bigint, fsync_time_ms double precision)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, dba_mon
AS $$
 SELECT e.backend_type,e.object,e.context,e.reads-b.reads,
        e.read_bytes-b.read_bytes,e.read_time-b.read_time,
        e.writes-b.writes,e.write_bytes-b.write_bytes,e.write_time-b.write_time,
        e.extends-b.extends,e.extend_bytes-b.extend_bytes,e.hits-b.hits,
        e.evictions-b.evictions,e.fsyncs-b.fsyncs,e.fsync_time-b.fsync_time
 FROM dba_mon.io_snap b JOIN dba_mon.io_snap e
   USING(backend_type,object,context)
 WHERE b.snapshot_id=$1 AND e.snapshot_id=$2
   AND EXISTS (SELECT 1 FROM dba_mon.snapshot sb,dba_mon.snapshot se
               WHERE sb.snapshot_id=$1 AND se.snapshot_id=$2
                 AND sb.postmaster_start_time=se.postmaster_start_time
                 AND sb.stats_reset IS NOT DISTINCT FROM se.stats_reset)
   AND b.stats_reset IS NOT DISTINCT FROM e.stats_reset
   AND e.reads>=b.reads AND e.read_bytes>=b.read_bytes
   AND e.read_time>=b.read_time AND e.writes>=b.writes
   AND e.write_bytes>=b.write_bytes AND e.write_time>=b.write_time
   AND e.extends>=b.extends AND e.extend_bytes>=b.extend_bytes
   AND e.hits>=b.hits AND e.evictions>=b.evictions
   AND e.fsyncs>=b.fsyncs AND e.fsync_time>=b.fsync_time;
$$;

CREATE OR REPLACE FUNCTION dba_mon.report_table_delta(
  p_begin_snapshot_id bigint, p_end_snapshot_id bigint
) RETURNS TABLE (database_target_id bigint, database_name name,
  schemaname name, relname name, seq_scan bigint, seq_tup_read bigint,
  idx_scan bigint, idx_tup_fetch bigint, inserts bigint, updates bigint,
  deletes bigint, hot_updates bigint, live_tuples bigint, dead_tuples bigint,
  modifications_since_analyze bigint, total_relation_size bigint,
  last_vacuum timestamptz, last_autovacuum timestamptz,
  last_analyze timestamptz, last_autoanalyze timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, dba_mon
AS $$
 SELECT e.database_target_id,dt.database_name,e.schemaname,e.relname,
        e.seq_scan-b.seq_scan,e.seq_tup_read-b.seq_tup_read,
        e.idx_scan-b.idx_scan,e.idx_tup_fetch-b.idx_tup_fetch,
        e.n_tup_ins-b.n_tup_ins,e.n_tup_upd-b.n_tup_upd,
        e.n_tup_del-b.n_tup_del,e.n_tup_hot_upd-b.n_tup_hot_upd,
        e.n_live_tup,e.n_dead_tup,e.n_mod_since_analyze,e.total_relation_size,
        e.last_vacuum,e.last_autovacuum,e.last_analyze,e.last_autoanalyze
 FROM dba_mon.table_snap b JOIN dba_mon.table_snap e
   ON e.database_target_id=b.database_target_id AND e.relid=b.relid
 JOIN dba_mon.database_target dt
   ON dt.database_target_id=e.database_target_id
 WHERE b.snapshot_id=$1 AND e.snapshot_id=$2
   AND EXISTS (SELECT 1 FROM dba_mon.snapshot sb,dba_mon.snapshot se
               WHERE sb.snapshot_id=$1 AND se.snapshot_id=$2
                 AND sb.postmaster_start_time=se.postmaster_start_time
                 AND sb.stats_reset IS NOT DISTINCT FROM se.stats_reset)
   AND e.seq_scan>=b.seq_scan AND e.seq_tup_read>=b.seq_tup_read
   AND coalesce(e.idx_scan,0)>=coalesce(b.idx_scan,0)
   AND coalesce(e.idx_tup_fetch,0)>=coalesce(b.idx_tup_fetch,0)
   AND e.n_tup_ins>=b.n_tup_ins AND e.n_tup_upd>=b.n_tup_upd
   AND e.n_tup_del>=b.n_tup_del AND e.n_tup_hot_upd>=b.n_tup_hot_upd;
$$;

CREATE OR REPLACE FUNCTION dba_mon.report_vacuum_delta(
  p_begin_snapshot_id bigint, p_end_snapshot_id bigint
) RETURNS TABLE (database_target_id bigint, database_name name,
  schemaname name, relname name, vacuum_count bigint, autovacuum_count bigint,
  analyze_count bigint, autoanalyze_count bigint, dead_tuples bigint,
  modifications_since_analyze bigint, last_vacuum timestamptz,
  last_autovacuum timestamptz, last_analyze timestamptz,
  last_autoanalyze timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, dba_mon
AS $$
 SELECT e.database_target_id,dt.database_name,e.schemaname,e.relname,
        e.vacuum_count-b.vacuum_count,e.autovacuum_count-b.autovacuum_count,
        e.analyze_count-b.analyze_count,e.autoanalyze_count-b.autoanalyze_count,
        e.n_dead_tup,e.n_mod_since_analyze,e.last_vacuum,e.last_autovacuum,
        e.last_analyze,e.last_autoanalyze
 FROM dba_mon.table_snap b JOIN dba_mon.table_snap e
   ON e.database_target_id=b.database_target_id AND e.relid=b.relid
 JOIN dba_mon.database_target dt
   ON dt.database_target_id=e.database_target_id
 WHERE b.snapshot_id=$1 AND e.snapshot_id=$2
   AND EXISTS (SELECT 1 FROM dba_mon.snapshot sb,dba_mon.snapshot se
               WHERE sb.snapshot_id=$1 AND se.snapshot_id=$2
                 AND sb.postmaster_start_time=se.postmaster_start_time
                 AND sb.stats_reset IS NOT DISTINCT FROM se.stats_reset)
   AND e.vacuum_count>=b.vacuum_count
   AND e.autovacuum_count>=b.autovacuum_count
   AND e.analyze_count>=b.analyze_count
   AND e.autoanalyze_count>=b.autoanalyze_count;
$$;

CREATE OR REPLACE FUNCTION dba_mon.report_index_delta(
  p_begin_snapshot_id bigint, p_end_snapshot_id bigint
) RETURNS TABLE (database_target_id bigint, database_name name,
  schemaname name, relname name, indexrelname name, idx_scan bigint,
  idx_tup_read bigint, idx_tup_fetch bigint, index_size bigint,
  last_idx_scan timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, dba_mon
AS $$
 SELECT e.database_target_id,dt.database_name,e.schemaname,e.relname,
        e.indexrelname,e.idx_scan-b.idx_scan,e.idx_tup_read-b.idx_tup_read,
        e.idx_tup_fetch-b.idx_tup_fetch,e.index_size,e.last_idx_scan
 FROM dba_mon.index_snap b JOIN dba_mon.index_snap e
   ON e.database_target_id=b.database_target_id
  AND e.indexrelid=b.indexrelid
 JOIN dba_mon.database_target dt
   ON dt.database_target_id=e.database_target_id
 WHERE b.snapshot_id=$1 AND e.snapshot_id=$2
   AND EXISTS (SELECT 1 FROM dba_mon.snapshot sb,dba_mon.snapshot se
               WHERE sb.snapshot_id=$1 AND se.snapshot_id=$2
                 AND sb.postmaster_start_time=se.postmaster_start_time
                 AND sb.stats_reset IS NOT DISTINCT FROM se.stats_reset)
   AND e.idx_scan>=b.idx_scan AND e.idx_tup_read>=b.idx_tup_read
   AND e.idx_tup_fetch>=b.idx_tup_fetch;
$$;

CREATE OR REPLACE FUNCTION dba_mon.report_wait_summary(
  p_begin_snapshot_id bigint, p_end_snapshot_id bigint
) RETURNS TABLE (wait_event_type text, wait_event text, sample_count bigint,
  blocked_sample_count bigint, average_active_sessions numeric,
  maximum_active_sessions integer, first_sample timestamptz, last_sample timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, dba_mon
AS $$
 WITH i AS (SELECT * FROM dba_mon.report_interval($1,$2)),
 ticks AS (
   SELECT count(DISTINCT w.sampled_at)::numeric tick_count
   FROM dba_mon.wait_sample w JOIN i ON i.cluster_id=w.cluster_id
   WHERE w.sampled_at>=i.begin_time AND w.sampled_at<=i.end_time
 )
 SELECT w.wait_event_type,w.wait_event,sum(w.session_count),
        sum(w.blocked_session_count),
        round(sum(w.session_count)::numeric/nullif(ticks.tick_count,0),3),
        max(w.session_count),min(w.sampled_at),max(w.sampled_at)
 FROM dba_mon.wait_sample w JOIN i ON i.cluster_id=w.cluster_id CROSS JOIN ticks
 WHERE w.sampled_at>=i.begin_time AND w.sampled_at<=i.end_time
   AND w.session_count>0
 GROUP BY w.wait_event_type,w.wait_event,ticks.tick_count;
$$;

CREATE OR REPLACE FUNCTION dba_mon.report_wait_chart(
  p_begin_snapshot_id bigint, p_end_snapshot_id bigint
) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, dba_mon
AS $$
DECLARE
  i record;
  v_max integer;
  v_areas text;
  v_legend text;
BEGIN
  SELECT * INTO STRICT i
  FROM dba_mon.report_interval(p_begin_snapshot_id,p_end_snapshot_id);

  SELECT max(total_sessions)::integer INTO v_max
  FROM (
    SELECT sampled_at,sum(session_count) AS total_sessions
    FROM dba_mon.wait_sample
    WHERE cluster_id=i.cluster_id AND sampled_at>=i.begin_time AND sampled_at<=i.end_time
    GROUP BY sampled_at
  ) s;
  IF coalesce(v_max,0)=0 THEN
    RETURN '<div class="empty">No active-session samples were captured in this interval</div>';
  END IF;

  WITH RECURSIVE
  raw AS (
    SELECT date_bin(interval '10 seconds',w.sampled_at,timestamptz '2000-01-01') bucket,
           w.wait_event_type||' / '||w.wait_event AS original_label,w.session_count
    FROM dba_mon.wait_sample w
    WHERE w.cluster_id=i.cluster_id AND w.sampled_at>=i.begin_time AND w.sampled_at<=i.end_time
      AND w.session_count>0
  ), ranked AS (
    SELECT original_label,row_number() OVER (ORDER BY sum(session_count) DESC,original_label) rn
    FROM raw GROUP BY original_label
  ), mapped AS (
    SELECT r.bucket,CASE WHEN k.rn<=7 THEN r.original_label ELSE 'Other' END label,
           CASE WHEN k.rn<=7 THEN k.rn ELSE 8 END rank,sum(r.session_count)::integer sessions
    FROM raw r JOIN ranked k USING (original_label)
    GROUP BY r.bucket,CASE WHEN k.rn<=7 THEN r.original_label ELSE 'Other' END,
             CASE WHEN k.rn<=7 THEN k.rn ELSE 8 END
  ), categories AS (
    SELECT label,min(rank)::integer rank FROM mapped GROUP BY label
  ), buckets AS (
    SELECT generate_series(
      date_bin(interval '10 seconds',i.begin_time,timestamptz '2000-01-01'),
      date_bin(interval '10 seconds',i.end_time,timestamptz '2000-01-01'),interval '10 seconds') bucket
  ), grid AS (
    SELECT b.bucket,c.label,c.rank,coalesce(m.sessions,0)::integer sessions
    FROM buckets b CROSS JOIN categories c
    LEFT JOIN mapped m ON m.bucket=b.bucket AND m.label=c.label
  ), stacked AS (
    SELECT *,coalesce(sum(sessions) OVER (PARTITION BY bucket ORDER BY rank
      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0)::numeric lower_value,
      sum(sessions) OVER (PARTITION BY bucket ORDER BY rank ROWS UNBOUNDED PRECEDING)::numeric upper_value
    FROM grid
  ), coords AS (
    SELECT *,55+795*extract(epoch FROM bucket-i.begin_time)/nullif(i.interval_seconds,0) x,
      245-210*upper_value/v_max y_upper,245-210*lower_value/v_max y_lower
    FROM stacked
  ), polygons AS (
    SELECT label,rank,
      string_agg(round(x::numeric,1)||','||round(y_upper::numeric,1),' ' ORDER BY bucket)
      ||' '||string_agg(round(x::numeric,1)||','||round(y_lower::numeric,1),' ' ORDER BY bucket DESC) points
    FROM coords GROUP BY label,rank
  )
  SELECT string_agg(format('<polygon points="%s" fill="%s" fill-opacity="0.82"><title>%s</title></polygon>',
    points,CASE rank WHEN 1 THEN '#2563eb' WHEN 2 THEN '#16a34a' WHEN 3 THEN '#f59e0b'
    WHEN 4 THEN '#dc2626' WHEN 5 THEN '#7c3aed' WHEN 6 THEN '#0891b2'
    WHEN 7 THEN '#db2777' ELSE '#94a3b8' END,dba_mon._html_escape(label)),' ' ORDER BY rank)
  INTO v_areas FROM polygons;

  WITH labels AS (
    SELECT wait_event_type||' / '||wait_event label,sum(sample_count) total,
           row_number() OVER (ORDER BY sum(sample_count) DESC,wait_event_type,wait_event) rn
    FROM dba_mon.report_wait_summary(p_begin_snapshot_id,p_end_snapshot_id)
    GROUP BY wait_event_type,wait_event
  ), shown AS (
    SELECT CASE WHEN rn<=7 THEN label ELSE 'Other' END label,
           CASE WHEN rn<=7 THEN rn ELSE 8 END rank,sum(total) total
    FROM labels GROUP BY CASE WHEN rn<=7 THEN label ELSE 'Other' END,
      CASE WHEN rn<=7 THEN rn ELSE 8 END
  )
  SELECT string_agg(format('<rect x="870" y="%s" width="12" height="12" fill="%s"/>'
    ||'<text x="888" y="%s" font-size="11">%s</text>',
    28+(rank-1)*24,CASE rank WHEN 1 THEN '#2563eb' WHEN 2 THEN '#16a34a' WHEN 3 THEN '#f59e0b'
    WHEN 4 THEN '#dc2626' WHEN 5 THEN '#7c3aed' WHEN 6 THEN '#0891b2'
    WHEN 7 THEN '#db2777' ELSE '#94a3b8' END,39+(rank-1)*24,dba_mon._html_escape(label)),' ' ORDER BY rank)
  INTO v_legend FROM shown;

  RETURN format('<svg class="wait-chart" viewBox="0 0 1100 275" role="img" aria-label="Average active sessions by wait event">'
    ||'<line x1="55" y1="35" x2="55" y2="245" stroke="#64748b"/>'
    ||'<line x1="55" y1="245" x2="850" y2="245" stroke="#64748b"/>'
    ||'<text x="8" y="40" font-size="11">%s</text><text x="35" y="249" font-size="11">0</text>'
    ||'<text x="55" y="265" font-size="11">%s</text><text x="730" y="265" font-size="11">%s</text>'
    ||'%s%s</svg>',v_max,dba_mon._html_escape(i.begin_time::text),
    dba_mon._html_escape(i.end_time::text),v_areas,v_legend);
END;
$$;

CREATE OR REPLACE FUNCTION dba_mon.generate_html_report(
  p_begin_snapshot_id bigint,
  p_end_snapshot_id bigint
) RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, dba_mon
AS $$
DECLARE
  i record;
  r record;
  v_html text;
  v_rows text;
  v_severity text;
  v_metric text;
  v_title text;
BEGIN
  SELECT * INTO STRICT i
  FROM dba_mon.report_interval(p_begin_snapshot_id,p_end_snapshot_id);

  SELECT CASE WHEN count(*) FILTER (WHERE severity='ERROR')>0 THEN 'error'
              WHEN count(*) FILTER (WHERE severity='WARNING')>0 THEN 'warning'
              ELSE 'ok' END INTO v_severity
  FROM dba_mon.report_quality(p_begin_snapshot_id,p_end_snapshot_id);

  v_html := '<!doctype html><html lang="en"><head><meta charset="utf-8">'
    || '<meta name="viewport" content="width=device-width,initial-scale=1">'
    || '<title>PostgreSQL AWR ' || p_begin_snapshot_id || '-' || p_end_snapshot_id || '</title>'
    || '<style>'
    || ':root{--bg:#f4f7fb;--card:#fff;--ink:#152238;--muted:#607087;--line:#dce3ec;'
    || '--blue:#2356a8;--ok:#18794e;--warn:#9a6700;--bad:#b42318}'
    || '*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);'
    || 'font:14px/1.45 system-ui,-apple-system,Segoe UI,sans-serif}'
    || 'main{max-width:1500px;margin:auto;padding:24px}h1{margin:0}h2{margin:28px 0 10px}'
    || '.sub{color:var(--muted);margin:4px 0 20px}.grid{display:grid;'
    || 'grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:10px}'
    || '.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px}'
    || '.label{color:var(--muted);font-size:12px}.value{font-size:17px;font-weight:650}'
    || '.banner{padding:12px;border-radius:8px;color:#fff;font-weight:700;margin:16px 0}'
    || '.banner.ok{background:var(--ok)}.banner.warning{background:var(--warn)}'
    || '.banner.error{background:var(--bad)}.table-wrap{overflow:auto;background:var(--card);'
    || 'border:1px solid var(--line);border-radius:8px}table{border-collapse:collapse;width:100%}'
    || 'th,td{padding:8px 10px;border-bottom:1px solid var(--line);text-align:right;white-space:nowrap}'
    || 'th{position:sticky;top:0;background:#eaf0f8;color:#243b5a}th:first-child,td:first-child{text-align:left}'
    || 'tr:nth-child(even){background:#f8fafc}.query{white-space:normal;min-width:440px;text-align:left}'
    || '.sev-ERROR{color:var(--bad);font-weight:700}.sev-WARNING{color:var(--warn);font-weight:700}'
    || '.sev-OK{color:var(--ok)}.empty{color:var(--muted);padding:12px}'
    || '.back-to-top{display:block;margin:7px 2px 0;text-align:right;font-size:12px}footer{margin:30px 0;color:var(--muted)}'
    || '.chart-wrap{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:10px}'
    || '.wait-chart{display:block;width:100%;height:auto;min-height:260px}'
    || '@media print{body{background:#fff}main{max-width:none;padding:8px}.table-wrap{overflow:visible}'
    || 'th{position:static}section{break-inside:avoid}}'
    || '</style></head><body><main>'
    || '<h1 id="top">PostgreSQL AWR Report</h1><p class="sub">AWR-inspired snapshot comparison</p>'
    || format('<div class="banner %s">Data quality: %s</div>',v_severity,upper(v_severity))
    || '<div class="grid">'
    || format('<div class="card"><div class="label">Cluster</div><div class="value">%s</div></div>',dba_mon._html_escape(i.cluster_name))
    || format('<div class="card"><div class="label">Snapshots</div><div class="value">%s → %s</div></div>',i.begin_snapshot_id,i.end_snapshot_id)
    || format('<div class="card"><div class="label">Begin</div><div class="value">%s</div></div>',dba_mon._html_escape(i.begin_time::text))
    || format('<div class="card"><div class="label">End</div><div class="value">%s</div></div>',dba_mon._html_escape(i.end_time::text))
    || format('<div class="card"><div class="label">Duration</div><div class="value">%s seconds</div></div>',round(i.interval_seconds,2))
    || format('<div class="card"><div class="label">Mode</div><div class="value">%s</div></div>',CASE WHEN i.in_recovery THEN 'Standby' ELSE 'Primary' END)
    || format('<div class="card"><div class="label">Collector</div><div class="value">%s</div></div>',dba_mon._html_escape(i.collector_version))
    || '</div>';

  SELECT coalesce(string_agg(format('<tr><td class="sev-%s">%s</td><td>%s</td><td class="query">%s</td></tr>',
           dba_mon._html_escape(severity),dba_mon._html_escape(severity),
           dba_mon._html_escape(check_name),dba_mon._html_escape(message)),''),
         '<tr><td colspan="3" class="empty">No checks returned</td></tr>') INTO v_rows
  FROM dba_mon.report_quality(p_begin_snapshot_id,p_end_snapshot_id);
  v_html := v_html || '<section><h2>Data Quality</h2><div class="table-wrap"><table>'
    || '<thead><tr><th>Severity</th><th>Check</th><th>Message</th></tr></thead><tbody>'
    || v_rows || '</tbody></table></div><a class="back-to-top" href="#top">Back to top</a></section>';

  SELECT coalesce(sum(calls),0) calls,coalesce(sum(total_exec_time_ms),0) exec_ms,
         coalesce(sum(rows),0) rows,coalesce(sum(shared_blks_read),0) reads,
         coalesce(sum(temp_blks_written),0) temp,coalesce(sum(wal_bytes),0) wal
  INTO r FROM dba_mon.report_pgss_delta(p_begin_snapshot_id,p_end_snapshot_id);
  v_html := v_html || '<section><h2>Workload Profile</h2><div class="grid">'
    || format('<div class="card"><div class="label">SQL calls</div><div class="value">%s</div></div>',r.calls)
    || format('<div class="card"><div class="label">Calls/sec</div><div class="value">%s</div></div>',round((r.calls/NULLIF(i.interval_seconds,0))::numeric,2))
    || format('<div class="card"><div class="label">SQL execution</div><div class="value">%s ms</div></div>',round(r.exec_ms::numeric,2))
    || format('<div class="card"><div class="label">Rows</div><div class="value">%s</div></div>',r.rows)
    || format('<div class="card"><div class="label">Shared block reads</div><div class="value">%s</div></div>',r.reads)
    || format('<div class="card"><div class="label">Temp blocks written</div><div class="value">%s</div></div>',r.temp)
    || format('<div class="card"><div class="label">SQL WAL</div><div class="value">%s</div></div>',pg_size_pretty(r.wal::bigint))
    || '</div></section>';

  SELECT coalesce(string_agg(format('<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td>'
      || '<td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>',
      dba_mon._html_escape(coalesce(datname::text,'Shared objects')),xact_commit,xact_rollback,
      coalesce(cache_hit_pct::text,'n/a'),tup_inserted,tup_updated,tup_deleted,temp_files,
      pg_size_pretty(temp_bytes)),''),'<tr><td colspan="9" class="empty">No valid database deltas</td></tr>') INTO v_rows
  FROM dba_mon.report_database_delta(p_begin_snapshot_id,p_end_snapshot_id);
  v_html := v_html || '<section><h2>Database Workload</h2><div class="table-wrap"><table><thead><tr>'
    || '<th>Database</th><th>Commits</th><th>Rollbacks</th><th>Cache hit %</th><th>Inserts</th>'
    || '<th>Updates</th><th>Deletes</th><th>Temp files</th><th>Temp bytes</th>'
    || '</tr></thead><tbody>' || v_rows || '</tbody></table></div><a class="back-to-top" href="#top">Back to top</a></section>';

  SELECT * INTO r FROM dba_mon.system_snap WHERE snapshot_id=p_end_snapshot_id;
  IF FOUND THEN
    v_html := v_html || '<section><h2>End Snapshot System State</h2><div class="grid">'
      || format('<div class="card"><div class="label">Uptime</div><div class="value">%s seconds</div></div>',round(r.uptime_seconds))
      || format('<div class="card"><div class="label">Connections</div><div class="value">%s / %s</div></div>',r.total_backends,r.max_connections)
      || format('<div class="card"><div class="label">Active</div><div class="value">%s</div></div>',r.active_backends)
      || format('<div class="card"><div class="label">Waiting</div><div class="value">%s</div></div>',r.waiting_backends)
      || format('<div class="card"><div class="label">Idle in transaction</div><div class="value">%s</div></div>',r.idle_in_transaction_backends)
      || format('<div class="card"><div class="label">Waiting locks</div><div class="value">%s</div></div>',r.waiting_locks)
      || format('<div class="card"><div class="label">Database size</div><div class="value">%s</div></div>',pg_size_pretty(r.database_bytes::bigint))
      || '</div></section>';
  END IF;

  v_html := v_html || '<section><h2>Average Active Sessions by Wait Event</h2>'
    || '<p class="sub">Ten-second samples. CPU represents active sessions without a PostgreSQL wait event.</p>'
    || '<div class="chart-wrap">'
    || dba_mon.report_wait_chart(p_begin_snapshot_id,p_end_snapshot_id)
    || '</div></section>';

  SELECT coalesce(string_agg(format('<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td>'
      || '<td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>',
      dba_mon._html_escape(wait_event_type),dba_mon._html_escape(wait_event),sample_count,
      blocked_sample_count,average_active_sessions,maximum_active_sessions,
      dba_mon._html_escape(first_sample::text),dba_mon._html_escape(last_sample::text)),''),
      '<tr><td colspan="8" class="empty">No wait samples in this interval</td></tr>') INTO v_rows
  FROM (SELECT * FROM dba_mon.report_wait_summary(p_begin_snapshot_id,p_end_snapshot_id)
        ORDER BY sample_count DESC LIMIT 30) q;
  v_html := v_html || '<section><h2>Wait Event Summary</h2><div class="table-wrap"><table><thead><tr>'
    || '<th>Wait type</th><th>Wait event</th><th>Session samples</th><th>Blocked samples</th>'
    || '<th>Average active</th><th>Maximum active</th><th>First sample</th><th>Last sample</th>'
    || '</tr></thead><tbody>' || v_rows || '</tbody></table></div>'
    || '<a class="back-to-top" href="#top">Back to top</a></section>';

  FOR v_metric,v_title IN VALUES
    ('total_exec_time_ms','Top SQL by Total Execution Time'),
    ('calls','Top SQL by Calls'),('mean_exec_time_ms','Top SQL by Mean Execution Time'),
    ('shared_blks_read','Top SQL by Shared Blocks Read'),
    ('temp_blks_written','Top SQL by Temporary Blocks Written'),
    ('wal_bytes','Top SQL by WAL Generated'),('rows','Top SQL by Rows')
  LOOP
    EXECUTE format($q$
      SELECT coalesce(string_agg(format('<tr><td>%%s</td><td>%%s</td><td>%%s</td>'
        || '<td>%%s</td><td>%%s</td><td>%%s</td><td>%%s</td><td class="query">%%s</td></tr>',
        dba_mon._html_escape(database_name::text),queryid,calls,
        round(total_exec_time_ms::numeric,3),round(mean_exec_time_ms::numeric,3),
        shared_blks_read,temp_blks_written,dba_mon._html_escape(left(query,500))),''),
        '<tr><td colspan="8" class="empty">No valid SQL deltas</td></tr>')
      FROM (SELECT * FROM dba_mon.report_pgss_delta($1,$2)
            WHERE calls>0 ORDER BY %I DESC NULLS LAST LIMIT 10) q
    $q$,v_metric) INTO v_rows USING p_begin_snapshot_id,p_end_snapshot_id;
    v_html := v_html || format('<section><h2>%s</h2><div class="table-wrap"><table><thead><tr>',v_title)
      || '<th>Database</th><th>Query ID</th><th>Calls</th><th>Total ms</th><th>Mean ms</th>'
      || '<th>Reads</th><th>Temp writes</th><th>SQL text</th></tr></thead><tbody>'
      || v_rows || '</tbody></table></div><a class="back-to-top" href="#top">Back to top</a></section>';
  END LOOP;

  SELECT coalesce(string_agg(format('<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td>'
      || '<td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>',
      dba_mon._html_escape(backend_type),dba_mon._html_escape(object),dba_mon._html_escape(context),
      reads,pg_size_pretty(read_bytes::bigint),writes,pg_size_pretty(write_bytes::bigint),
      round((read_time_ms+write_time_ms)::numeric,3)),''),
      '<tr><td colspan="8" class="empty">No valid I/O deltas</td></tr>') INTO v_rows
  FROM (SELECT * FROM dba_mon.report_io_delta(p_begin_snapshot_id,p_end_snapshot_id)
        ORDER BY read_bytes+write_bytes DESC LIMIT 30) q;
  v_html := v_html || '<section><h2>I/O Profile</h2><div class="table-wrap"><table><thead><tr>'
    || '<th>Backend</th><th>Object</th><th>Context</th><th>Reads</th><th>Read bytes</th>'
    || '<th>Writes</th><th>Write bytes</th><th>I/O time ms</th></tr></thead><tbody>'
    || v_rows || '</tbody></table></div><a class="back-to-top" href="#top">Back to top</a></section>';

  SELECT * INTO r FROM dba_mon.report_wal_delta(p_begin_snapshot_id,p_end_snapshot_id);
  v_html := v_html || '<section><h2>WAL and Checkpoints</h2><div class="grid">';
  IF FOUND THEN v_html := v_html
    || format('<div class="card"><div class="label">WAL generated</div><div class="value">%s</div></div>',pg_size_pretty(r.wal_bytes::bigint))
    || format('<div class="card"><div class="label">WAL records</div><div class="value">%s</div></div>',r.wal_records)
    || format('<div class="card"><div class="label">Full-page images</div><div class="value">%s</div></div>',r.wal_fpi)
    || format('<div class="card"><div class="label">WAL buffers full</div><div class="value">%s</div></div>',r.wal_buffers_full); END IF;
  SELECT * INTO r FROM dba_mon.report_checkpointer_delta(p_begin_snapshot_id,p_end_snapshot_id);
  IF FOUND THEN v_html := v_html
    || format('<div class="card"><div class="label">Timed checkpoints</div><div class="value">%s</div></div>',r.num_timed)
    || format('<div class="card"><div class="label">Requested checkpoints</div><div class="value">%s</div></div>',r.num_requested)
    || format('<div class="card"><div class="label">Checkpoint write time</div><div class="value">%s ms</div></div>',round(r.write_time_ms::numeric,2))
    || format('<div class="card"><div class="label">Checkpoint sync time</div><div class="value">%s ms</div></div>',round(r.sync_time_ms::numeric,2)); END IF;
  SELECT * INTO r FROM dba_mon.report_bgwriter_delta(p_begin_snapshot_id,p_end_snapshot_id);
  IF FOUND THEN v_html := v_html
    || format('<div class="card"><div class="label">Buffers cleaned</div><div class="value">%s</div></div>',r.buffers_clean)
    || format('<div class="card"><div class="label">Maxwritten stops</div><div class="value">%s</div></div>',r.maxwritten_clean); END IF;
  v_html := v_html || '</div></section>';

  SELECT * INTO r FROM dba_mon.report_archiver_delta(p_begin_snapshot_id,p_end_snapshot_id);
  IF FOUND THEN
    v_html := v_html || '<section><h2>WAL Archive Activity</h2><div class="grid">'
      || format('<div class="card"><div class="label">Archived segments</div><div class="value">%s</div></div>',r.archived_count)
      || format('<div class="card"><div class="label">Archive failures</div><div class="value">%s</div></div>',r.failed_count)
      || format('<div class="card"><div class="label">Last archived WAL</div><div class="value">%s</div></div>',dba_mon._html_escape(coalesce(r.last_archived_wal,'n/a')))
      || format('<div class="card"><div class="label">Last failed WAL</div><div class="value">%s</div></div>',dba_mon._html_escape(coalesce(r.last_failed_wal,'n/a')))
      || '</div></section>';
  END IF;

  SELECT coalesce(string_agg(format('<tr><td>%s</td><td>%s.%s</td><td>%s</td><td>%s</td>'
      || '<td>%s</td><td>%s</td><td>%s</td></tr>',dba_mon._html_escape(database_name::text),
      dba_mon._html_escape(schemaname::text),dba_mon._html_escape(relname::text),seq_tup_read,
      inserts,updates,deletes,dead_tuples),''),
      '<tr><td colspan="7" class="empty">No valid table deltas</td></tr>') INTO v_rows
  FROM (SELECT * FROM dba_mon.report_table_delta(p_begin_snapshot_id,p_end_snapshot_id)
        ORDER BY seq_tup_read+inserts+updates+deletes DESC LIMIT 20) q;
  v_html := v_html || '<section><h2>Top Table Activity</h2><div class="table-wrap"><table><thead><tr>'
    || '<th>Database</th><th>Table</th><th>Sequential rows</th><th>Inserts</th><th>Updates</th>'
    || '<th>Deletes</th><th>Dead tuples</th></tr></thead><tbody>' || v_rows || '</tbody></table></div><a class="back-to-top" href="#top">Back to top</a></section>';

  SELECT coalesce(string_agg(format('<tr><td>%s</td><td>%s.%s</td><td>%s</td><td>%s</td>'
      || '<td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>',
      dba_mon._html_escape(database_name::text),dba_mon._html_escape(schemaname::text),
      dba_mon._html_escape(relname::text),vacuum_count,autovacuum_count,analyze_count,
      autoanalyze_count,dead_tuples,modifications_since_analyze,
      dba_mon._html_escape(coalesce(greatest(last_vacuum,last_autovacuum)::text,'never'))),''),
      '<tr><td colspan="9" class="empty">No valid vacuum statistics</td></tr>') INTO v_rows
  FROM (SELECT * FROM dba_mon.report_vacuum_delta(p_begin_snapshot_id,p_end_snapshot_id)
        ORDER BY vacuum_count+autovacuum_count DESC,dead_tuples DESC LIMIT 20) q;
  v_html := v_html || '<section><h2>Vacuum and Analyze Statistics</h2><div class="table-wrap"><table><thead><tr>'
    || '<th>Database</th><th>Table</th><th>Manual vacuum</th><th>Autovacuum</th>'
    || '<th>Manual analyze</th><th>Autoanalyze</th><th>Dead tuples</th><th>Changes since analyze</th>'
    || '<th>Last vacuum</th></tr></thead><tbody>' || v_rows || '</tbody></table></div>'
    || '<a class="back-to-top" href="#top">Back to top</a></section>';

  SELECT coalesce(string_agg(format('<tr><td>%s</td><td>%s.%s</td><td>%s</td><td>%s</td>'
      || '<td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>',dba_mon._html_escape(database_name::text),
      dba_mon._html_escape(schemaname::text),dba_mon._html_escape(indexrelname::text),
      dba_mon._html_escape(relname::text),idx_scan,idx_tup_read,idx_tup_fetch,
      pg_size_pretty(index_size),dba_mon._html_escape(coalesce(last_idx_scan::text,'never'))),''),
      '<tr><td colspan="8" class="empty">No valid index deltas</td></tr>') INTO v_rows
  FROM (SELECT * FROM dba_mon.report_index_delta(p_begin_snapshot_id,p_end_snapshot_id)
        ORDER BY idx_scan DESC,index_size DESC LIMIT 20) q;
  v_html := v_html || '<section><h2>Index Activity</h2><div class="table-wrap"><table><thead><tr>'
    || '<th>Database</th><th>Index</th><th>Table</th><th>Scans</th><th>Entries read</th><th>Tuples fetched</th>'
    || '<th>Size</th><th>Last scan</th></tr></thead><tbody>' || v_rows || '</tbody></table></div>'
    || '<a class="back-to-top" href="#top">Back to top</a></section>';

  SELECT coalesce(string_agg(format('<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>',
      dba_mon._html_escape(application_name),dba_mon._html_escape(coalesce(client_addr::text,'')),
      dba_mon._html_escape(state),dba_mon._html_escape(sync_state),
      dba_mon._html_escape(coalesce(replay_lag::text,''))),''),
      '<tr><td colspan="5" class="empty">No replication senders (normal for standalone servers)</td></tr>') INTO v_rows
  FROM dba_mon.replication_snap WHERE snapshot_id=p_end_snapshot_id;
  v_html := v_html || '<section><h2>Replication at End Snapshot</h2><div class="table-wrap"><table><thead><tr>'
    || '<th>Application</th><th>Client</th><th>State</th><th>Sync state</th><th>Replay lag</th>'
    || '</tr></thead><tbody>' || v_rows || '</tbody></table></div><a class="back-to-top" href="#top">Back to top</a></section>';

  SELECT coalesce(string_agg(format('<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>',
      dba_mon._html_escape(slot_name::text),dba_mon._html_escape(slot_type),active,
      dba_mon._html_escape(coalesce(wal_status,'')),coalesce(pg_size_pretty(safe_wal_size),'')),''),
      '<tr><td colspan="5" class="empty">No replication slots</td></tr>') INTO v_rows
  FROM dba_mon.slot_snap WHERE snapshot_id=p_end_snapshot_id;
  v_html := v_html || '<section><h2>Replication Slots at End Snapshot</h2><div class="table-wrap"><table><thead><tr>'
    || '<th>Slot</th><th>Type</th><th>Active</th><th>WAL status</th><th>Safe WAL size</th>'
    || '</tr></thead><tbody>' || v_rows || '</tbody></table></div><a class="back-to-top" href="#top">Back to top</a></section>';

  SELECT coalesce(string_agg(format('<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td class="query">%s</td></tr>',
      snapshot_id,dba_mon._html_escape(component),dba_mon._html_escape(status),coalesce(row_count::text,''),
      dba_mon._html_escape(coalesce(error_sqlstate||': ','')||coalesce(error_message,''))),''),
      '<tr><td colspan="5" class="empty">No component diagnostics</td></tr>') INTO v_rows
  FROM dba_mon.capture_component WHERE snapshot_id IN (p_begin_snapshot_id,p_end_snapshot_id);
  v_html := v_html || '<section><h2>Capture Diagnostics</h2><div class="table-wrap"><table><thead><tr>'
    || '<th>Snapshot</th><th>Component</th><th>Status</th><th>Rows</th><th>Message</th>'
    || '</tr></thead><tbody>' || v_rows || '</tbody></table></div><a class="back-to-top" href="#top">Back to top</a></section>'
    || format('<footer>Generated at %s by postgres-awr %s. Deltas are valid only where counters and reset markers are stable.</footer>',
       clock_timestamp(),dba_mon._html_escape(i.collector_version))
    || '</main></body></html>';
  RETURN v_html;
END;
$$;

REVOKE ALL ON FUNCTION dba_mon._html_escape(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION dba_mon.report_interval(bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION dba_mon.report_quality(bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION dba_mon.report_pgss_delta(bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION dba_mon.report_database_delta(bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION dba_mon.report_wal_delta(bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION dba_mon.report_checkpointer_delta(bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION dba_mon.report_bgwriter_delta(bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION dba_mon.report_archiver_delta(bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION dba_mon.report_io_delta(bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION dba_mon.report_table_delta(bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION dba_mon.report_vacuum_delta(bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION dba_mon.report_index_delta(bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION dba_mon.report_wait_summary(bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION dba_mon.report_wait_chart(bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION dba_mon.generate_html_report(bigint, bigint) FROM PUBLIC;
