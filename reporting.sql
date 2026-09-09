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
    AND e.calls >= b.calls
    AND e.total_exec_time >= b.total_exec_time
    AND e.rows >= b.rows
    AND e.shared_blks_read >= b.shared_blks_read
    AND e.shared_blks_hit >= b.shared_blks_hit
    AND e.temp_blks_written >= b.temp_blks_written
    AND e.wal_bytes >= b.wal_bytes;
$$;

REVOKE ALL ON FUNCTION dba_mon._html_escape(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION dba_mon.report_interval(bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION dba_mon.report_quality(bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION dba_mon.report_pgss_delta(bigint, bigint) FROM PUBLIC;
