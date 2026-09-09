\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION dba_mon._component_begin(
  p_snapshot_id bigint, p_component text, p_database_target_id bigint DEFAULT NULL
) RETURNS void LANGUAGE sql AS $$
  INSERT INTO dba_mon.capture_component
    (snapshot_id, component, database_target_id, status)
  VALUES ($1, $2, $3, 'RUNNING');
$$;

CREATE OR REPLACE FUNCTION dba_mon._component_end(
  p_snapshot_id bigint, p_component text, p_database_target_id bigint,
  p_status text, p_rows bigint DEFAULT NULL, p_state text DEFAULT NULL,
  p_message text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog, dba_mon AS $$
BEGIN
  UPDATE dba_mon.capture_component
     SET completed_at = clock_timestamp(), status = $4, row_count = $5,
         error_sqlstate = $6, error_message = left($7, 4000)
   WHERE snapshot_id = $1 AND component = $2
     AND database_target_id IS NOT DISTINCT FROM $3;

  -- An exception rolls back the component's RUNNING row together with the
  -- failed collector statement. Preserve the failure instead of silently
  -- leaving a PARTIAL snapshot with no FAILED component.
  IF NOT FOUND THEN
    INSERT INTO dba_mon.capture_component(
      snapshot_id, component, database_target_id, started_at, completed_at,
      status, row_count, error_sqlstate, error_message
    ) VALUES (
      $1, $2, $3, clock_timestamp(), clock_timestamp(),
      $4, $5, $6, left($7, 4000)
    );
  END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE dba_mon.capture_snapshot(p_cluster_id bigint DEFAULT NULL)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, dba_mon AS $$
DECLARE
  v_cluster dba_mon.cluster_target%ROWTYPE;
  v_snapshot bigint;
  v_rows bigint;
  v_db dba_mon.database_target%ROWTYPE;
  v_conn text;
  v_sql text;
  v_dblink_schema name;
  v_failures integer := 0;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtextextended('dba_mon.capture_snapshot', 0)) THEN
    RAISE EXCEPTION 'another dba_mon snapshot is running' USING ERRCODE='55P03';
  END IF;

  SELECT * INTO STRICT v_cluster
  FROM dba_mon.cluster_target
  WHERE enabled AND is_local AND (p_cluster_id IS NULL OR cluster_id=p_cluster_id);

  SELECT n.nspname INTO STRICT v_dblink_schema
  FROM pg_extension AS e
  JOIN pg_namespace AS n ON n.oid = e.extnamespace
  WHERE e.extname = 'dblink';

  INSERT INTO dba_mon.snapshot(
    cluster_id, server_version_num, server_version, system_identifier,
    timeline_id, in_recovery, postmaster_start_time, stats_reset,
    pgss_stats_reset, block_size, wal_segment_size
  )
  SELECT v_cluster.cluster_id, current_setting('server_version_num')::integer,
         version(), (pg_control_system()).system_identifier,
         (pg_control_checkpoint()).timeline_id, pg_is_in_recovery(),
         pg_postmaster_start_time(),
         (SELECT min(stats_reset) FROM pg_stat_database),
         (SELECT stats_reset FROM dba_mon.pgss_info_source),
         current_setting('block_size')::integer,
         pg_size_bytes(current_setting('wal_segment_size'))::integer
  RETURNING snapshot_id INTO v_snapshot;

  BEGIN
    PERFORM dba_mon._component_begin(v_snapshot, 'system');
    INSERT INTO dba_mon.system_snap
    SELECT v_snapshot,
           extract(epoch FROM clock_timestamp() - pg_postmaster_start_time()),
           current_setting('max_connections')::integer,
           count(*) FILTER (WHERE backend_type = 'client backend'),
           count(*) FILTER (WHERE backend_type = 'client backend' AND state = 'active'),
           count(*) FILTER (WHERE backend_type = 'client backend' AND state = 'idle in transaction'),
           count(*) FILTER (WHERE backend_type = 'client backend' AND wait_event IS NOT NULL),
           (SELECT count(*) FROM pg_locks WHERE granted),
           (SELECT count(*) FROM pg_locks WHERE NOT granted),
           (SELECT coalesce(sum(pg_database_size(datname)),0)
              FROM pg_database WHERE datallowconn)
      FROM pg_stat_activity;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    PERFORM dba_mon._component_end(v_snapshot,'system',NULL,'SUCCESS',v_rows);
  EXCEPTION WHEN OTHERS THEN
    v_failures:=v_failures+1;
    PERFORM dba_mon._component_end(v_snapshot,'system',NULL,'FAILED',NULL,SQLSTATE,SQLERRM);
  END;

  BEGIN
    PERFORM dba_mon._component_begin(v_snapshot, 'database');
    INSERT INTO dba_mon.database_snap
    SELECT v_snapshot, datid, datname, xact_commit, xact_rollback, blks_read,
           blks_hit, tup_returned, tup_fetched, tup_inserted, tup_updated,
           tup_deleted, temp_files, temp_bytes, deadlocks, checksum_failures,
           sessions, sessions_abandoned, sessions_fatal, sessions_killed, stats_reset
    FROM pg_stat_database;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    PERFORM dba_mon._component_end(v_snapshot,'database',NULL,'SUCCESS',v_rows);
  EXCEPTION WHEN OTHERS THEN
    v_failures:=v_failures+1;
    PERFORM dba_mon._component_end(v_snapshot,'database',NULL,'FAILED',NULL,SQLSTATE,SQLERRM);
  END;

  BEGIN
    PERFORM dba_mon._component_begin(v_snapshot, 'wal');
    INSERT INTO dba_mon.wal_snap
      SELECT v_snapshot, wal_records, wal_fpi, wal_bytes, wal_buffers_full, stats_reset
      FROM pg_stat_wal;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    PERFORM dba_mon._component_end(v_snapshot,'wal',NULL,'SUCCESS',v_rows);
  EXCEPTION WHEN OTHERS THEN
    v_failures:=v_failures+1;
    PERFORM dba_mon._component_end(v_snapshot,'wal',NULL,'FAILED',NULL,SQLSTATE,SQLERRM);
  END;

  BEGIN
    PERFORM dba_mon._component_begin(v_snapshot, 'io');
    IF current_setting('server_version_num')::integer >= 180000 THEN
      EXECUTE format($sql$
        INSERT INTO dba_mon.io_snap
        SELECT %s, backend_type, object, context, coalesce(reads,0),
               coalesce(read_bytes,0), coalesce(read_time,0), coalesce(writes,0),
               coalesce(write_bytes,0), coalesce(write_time,0),
               coalesce(writebacks,0), coalesce(writeback_time,0),
               coalesce(extends,0), coalesce(extend_bytes,0),
               coalesce(extend_time,0), coalesce(hits,0), coalesce(evictions,0),
               coalesce(reuses,0), coalesce(fsyncs,0), coalesce(fsync_time,0),
               stats_reset
        FROM pg_stat_io
      $sql$,v_snapshot);
    ELSE
      EXECUTE format($sql$
        INSERT INTO dba_mon.io_snap
        SELECT %s, backend_type, object, context, coalesce(reads,0),
               coalesce(reads,0)::numeric*op_bytes, coalesce(read_time,0),
               coalesce(writes,0), coalesce(writes,0)::numeric*op_bytes,
               coalesce(write_time,0), coalesce(writebacks,0),
               coalesce(writeback_time,0), coalesce(extends,0),
               coalesce(extends,0)::numeric*op_bytes, coalesce(extend_time,0),
               coalesce(hits,0), coalesce(evictions,0), coalesce(reuses,0),
               coalesce(fsyncs,0), coalesce(fsync_time,0), stats_reset
        FROM pg_stat_io
      $sql$,v_snapshot);
    END IF;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    PERFORM dba_mon._component_end(v_snapshot,'io',NULL,'SUCCESS',v_rows);
  EXCEPTION WHEN OTHERS THEN
    v_failures:=v_failures+1;
    PERFORM dba_mon._component_end(v_snapshot,'io',NULL,'FAILED',NULL,SQLSTATE,SQLERRM);
  END;

  BEGIN
    PERFORM dba_mon._component_begin(v_snapshot, 'checkpointer');
    IF current_setting('server_version_num')::integer >= 180000 THEN
      EXECUTE format($sql$
        INSERT INTO dba_mon.checkpointer_snap
        SELECT %s, num_timed, num_requested, num_done, restartpoints_timed,
               restartpoints_req, restartpoints_done, write_time, sync_time,
               buffers_written, stats_reset
        FROM pg_stat_checkpointer
      $sql$, v_snapshot);
    ELSE
      INSERT INTO dba_mon.checkpointer_snap
      SELECT v_snapshot, num_timed, num_requested, NULL::bigint,
             restartpoints_timed, restartpoints_req, restartpoints_done,
             write_time, sync_time, buffers_written, stats_reset
      FROM pg_stat_checkpointer;
    END IF;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    PERFORM dba_mon._component_end(v_snapshot,'checkpointer',NULL,'SUCCESS',v_rows);
  EXCEPTION WHEN OTHERS THEN
    v_failures:=v_failures+1;
    PERFORM dba_mon._component_end(v_snapshot,'checkpointer',NULL,'FAILED',NULL,SQLSTATE,SQLERRM);
  END;

  BEGIN
    PERFORM dba_mon._component_begin(v_snapshot, 'bgwriter');
    INSERT INTO dba_mon.bgwriter_snap
    SELECT v_snapshot, buffers_clean, maxwritten_clean, buffers_alloc, stats_reset
    FROM pg_stat_bgwriter;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    PERFORM dba_mon._component_end(v_snapshot,'bgwriter',NULL,'SUCCESS',v_rows);
  EXCEPTION WHEN OTHERS THEN
    v_failures:=v_failures+1;
    PERFORM dba_mon._component_end(v_snapshot,'bgwriter',NULL,'FAILED',NULL,SQLSTATE,SQLERRM);
  END;

  BEGIN
    PERFORM dba_mon._component_begin(v_snapshot, 'archiver');
    INSERT INTO dba_mon.archiver_snap
    SELECT v_snapshot, archived_count, last_archived_wal, last_archived_time,
           failed_count, last_failed_wal, last_failed_time, stats_reset
    FROM pg_stat_archiver;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    PERFORM dba_mon._component_end(v_snapshot,'archiver',NULL,'SUCCESS',v_rows);
  EXCEPTION WHEN OTHERS THEN
    v_failures:=v_failures+1;
    PERFORM dba_mon._component_end(v_snapshot,'archiver',NULL,'FAILED',NULL,SQLSTATE,SQLERRM);
  END;

  BEGIN
    PERFORM dba_mon._component_begin(v_snapshot, 'replication');
    INSERT INTO dba_mon.replication_snap
    SELECT v_snapshot, pid, usesysid, usename, application_name, client_addr,
           state, sent_lsn, write_lsn, flush_lsn, replay_lsn, write_lag,
           flush_lag, replay_lag, sync_state, reply_time FROM pg_stat_replication;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    PERFORM dba_mon._component_end(v_snapshot,'replication',NULL,'SUCCESS',v_rows);
  EXCEPTION WHEN OTHERS THEN
    v_failures:=v_failures+1;
    PERFORM dba_mon._component_end(v_snapshot,'replication',NULL,'FAILED',NULL,SQLSTATE,SQLERRM);
  END;

  BEGIN
    PERFORM dba_mon._component_begin(v_snapshot, 'slots');
    INSERT INTO dba_mon.slot_snap
    SELECT v_snapshot, slot_name, slot_type, database, active, active_pid,
           restart_lsn, confirmed_flush_lsn, wal_status, safe_wal_size,
           inactive_since, conflicting FROM pg_replication_slots;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    PERFORM dba_mon._component_end(v_snapshot,'slots',NULL,'SUCCESS',v_rows);
  EXCEPTION WHEN OTHERS THEN
    v_failures:=v_failures+1;
    PERFORM dba_mon._component_end(v_snapshot,'slots',NULL,'FAILED',NULL,SQLSTATE,SQLERRM);
  END;

  FOR v_db IN SELECT * FROM dba_mon.database_target
              WHERE enabled AND cluster_id=v_cluster.cluster_id
  LOOP
    v_conn := CASE WHEN v_db.service_name IS NOT NULL
                   THEN format('service=%L connect_timeout=%s',
                               v_db.service_name,v_db.connect_timeout_seconds)
                   ELSE format('dbname=%L connect_timeout=%s',
                               v_db.database_name,v_db.connect_timeout_seconds) END;
    BEGIN
      PERFORM dba_mon._component_begin(v_snapshot,'pgss',v_db.database_target_id);
      IF NOT v_db.collect_pgss THEN
        PERFORM dba_mon._component_end(v_snapshot,'pgss',v_db.database_target_id,'SKIPPED',0);
      ELSE
        v_sql := format($q$
          INSERT INTO dba_mon.pgss_snap
          SELECT %s, %s, *
          FROM %I.dblink(%L::text, $remote$
            SELECT userid, dbid, toplevel, queryid, query, plans, total_plan_time,
                   calls, total_exec_time, rows, shared_blks_hit, shared_blks_read,
                   shared_blks_dirtied, shared_blks_written, local_blks_hit,
                   local_blks_read, local_blks_dirtied, local_blks_written,
                   temp_blks_read, temp_blks_written, shared_blk_read_time,
                   shared_blk_write_time, local_blk_read_time, local_blk_write_time,
                   temp_blk_read_time, temp_blk_write_time, wal_records, wal_fpi, wal_bytes
            FROM pg_stat_statements
          $remote$::text) AS x(
            userid oid, dbid oid, toplevel boolean, queryid bigint, query text,
            plans bigint, total_plan_time float8, calls bigint, total_exec_time float8,
            rows bigint, shared_blks_hit bigint, shared_blks_read bigint,
            shared_blks_dirtied bigint, shared_blks_written bigint, local_blks_hit bigint,
            local_blks_read bigint, local_blks_dirtied bigint, local_blks_written bigint,
            temp_blks_read bigint, temp_blks_written bigint, shared_blk_read_time float8,
            shared_blk_write_time float8, local_blk_read_time float8,
            local_blk_write_time float8, temp_blk_read_time float8,
            temp_blk_write_time float8, wal_records bigint, wal_fpi bigint, wal_bytes numeric)
        $q$,v_snapshot,v_db.database_target_id,v_dblink_schema,v_conn);
        EXECUTE v_sql; GET DIAGNOSTICS v_rows=ROW_COUNT;
        PERFORM dba_mon._component_end(v_snapshot,'pgss',v_db.database_target_id,'SUCCESS',v_rows);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_failures:=v_failures+1;
      PERFORM dba_mon._component_end(v_snapshot,'pgss',v_db.database_target_id,'FAILED',NULL,SQLSTATE,SQLERRM);
    END;

    BEGIN
      PERFORM dba_mon._component_begin(v_snapshot,'objects',v_db.database_target_id);
      IF NOT v_db.collect_objects THEN
        PERFORM dba_mon._component_end(v_snapshot,'objects',v_db.database_target_id,'SKIPPED',0);
      ELSE
        v_sql := format($q$
          INSERT INTO dba_mon.table_snap
          SELECT %s, %s, *
          FROM %I.dblink(%L::text, $remote$
            SELECT relid, schemaname, relname, seq_scan, seq_tup_read, idx_scan,
                   idx_tup_fetch, n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
                   n_live_tup, n_dead_tup, n_mod_since_analyze, last_vacuum,
                   last_autovacuum, last_analyze, last_autoanalyze, vacuum_count,
                   autovacuum_count, analyze_count, autoanalyze_count,
                   pg_total_relation_size(relid)
            FROM pg_stat_user_tables
          $remote$::text) AS x(
            relid oid, schemaname name, relname name, seq_scan bigint,
            seq_tup_read bigint, idx_scan bigint, idx_tup_fetch bigint,
            n_tup_ins bigint, n_tup_upd bigint, n_tup_del bigint,
            n_tup_hot_upd bigint, n_live_tup bigint, n_dead_tup bigint,
            n_mod_since_analyze bigint, last_vacuum timestamptz,
            last_autovacuum timestamptz, last_analyze timestamptz,
            last_autoanalyze timestamptz, vacuum_count bigint,
            autovacuum_count bigint, analyze_count bigint,
            autoanalyze_count bigint, total_relation_size bigint)
        $q$,v_snapshot,v_db.database_target_id,v_dblink_schema,v_conn);
        EXECUTE v_sql; GET DIAGNOSTICS v_rows=ROW_COUNT;

        v_sql := format($q$
          INSERT INTO dba_mon.index_snap
          SELECT %s, %s, *
          FROM %I.dblink(%L::text, $remote$
            SELECT indexrelid, relid, schemaname, relname, indexrelname,
                   idx_scan, last_idx_scan, idx_tup_read, idx_tup_fetch,
                   pg_relation_size(indexrelid)
            FROM pg_stat_user_indexes
          $remote$::text) AS x(
            indexrelid oid, relid oid, schemaname name, relname name,
            indexrelname name, idx_scan bigint, last_idx_scan timestamptz,
            idx_tup_read bigint, idx_tup_fetch bigint, index_size bigint)
        $q$,v_snapshot,v_db.database_target_id,v_dblink_schema,v_conn);
        EXECUTE v_sql;
        PERFORM dba_mon._component_end(v_snapshot,'objects',v_db.database_target_id,'SUCCESS',v_rows);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_failures:=v_failures+1;
      PERFORM dba_mon._component_end(v_snapshot,'objects',v_db.database_target_id,'FAILED',NULL,SQLSTATE,SQLERRM);
    END;
  END LOOP;

  UPDATE dba_mon.snapshot SET completed_at=clock_timestamp(),
         error_count=v_failures,
         status=CASE WHEN v_failures=0 THEN 'SUCCESS' ELSE 'PARTIAL' END
   WHERE snapshot_id=v_snapshot;
EXCEPTION WHEN OTHERS THEN
  IF v_snapshot IS NOT NULL THEN
    UPDATE dba_mon.snapshot SET completed_at=clock_timestamp(), status='FAILED',
      error_count=error_count+1 WHERE snapshot_id=v_snapshot;
  END IF;
  RAISE;
END $$;

CREATE OR REPLACE VIEW dba_mon.v_snapshot_health AS
SELECT s.snapshot_id, c.cluster_name, s.started_at, s.completed_at, s.status,
       s.error_count, s.warning_count,
       round(extract(epoch FROM s.completed_at-s.started_at)::numeric,3) duration_seconds,
       s.postmaster_start_time, s.stats_reset, s.pgss_stats_reset
FROM dba_mon.snapshot s JOIN dba_mon.cluster_target c USING(cluster_id);

CREATE OR REPLACE VIEW dba_mon.v_pgss_delta AS
WITH x AS (
 SELECT p.*, s.started_at,
   lag(snapshot_id) OVER w prev_snapshot_id,
   lag(started_at) OVER w prev_started_at,
   lag(calls) OVER w prev_calls,
   lag(total_exec_time) OVER w prev_exec,
   lag(rows) OVER w prev_rows,
   lag(shared_blks_read) OVER w prev_reads,
   lag(shared_blks_hit) OVER w prev_hits,
   lag(temp_blks_written) OVER w prev_temp,
   lag(wal_bytes) OVER w prev_wal
 FROM dba_mon.pgss_snap p JOIN dba_mon.snapshot s USING(snapshot_id)
 WINDOW w AS (PARTITION BY database_target_id,userid,dbid,toplevel,queryid
              ORDER BY snapshot_id)
)
SELECT *, extract(epoch FROM started_at-prev_started_at) interval_seconds,
  calls-prev_calls delta_calls, total_exec_time-prev_exec delta_exec_time_ms,
  rows-prev_rows delta_rows, shared_blks_read-prev_reads delta_shared_blks_read,
  shared_blks_hit-prev_hits delta_shared_blks_hit,
  temp_blks_written-prev_temp delta_temp_blks_written,
  wal_bytes-prev_wal delta_wal_bytes
FROM x
WHERE prev_snapshot_id IS NOT NULL AND calls>=prev_calls;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA dba_mon FROM PUBLIC;
REVOKE ALL ON ALL PROCEDURES IN SCHEMA dba_mon FROM PUBLIC;
