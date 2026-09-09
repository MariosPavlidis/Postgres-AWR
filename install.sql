\set ON_ERROR_STOP on
\echo 'Installing postgres-awr 1.0.2'

BEGIN;

DO $$
BEGIN
  IF current_setting('server_version_num')::integer < 170000
     OR current_setting('server_version_num')::integer >= 190000 THEN
    RAISE EXCEPTION 'postgres-awr 1.0 supports PostgreSQL 17 and 18 only';
  END IF;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS dblink;

CREATE SCHEMA IF NOT EXISTS dba_mon;
REVOKE ALL ON SCHEMA dba_mon FROM PUBLIC;

-- pg_stat_statements may be installed outside public.  Expose only the
-- required metadata through a repository-owned bridge so SECURITY DEFINER
-- routines do not need an unsafe schema in their search_path.
DO $bridge$
DECLARE
  v_ext_schema name;
BEGIN
  SELECT n.nspname INTO STRICT v_ext_schema
  FROM pg_extension e
  JOIN pg_namespace n ON n.oid = e.extnamespace
  WHERE e.extname = 'pg_stat_statements';

  EXECUTE format(
    'CREATE OR REPLACE VIEW dba_mon.pgss_info_source AS '
    'SELECT stats_reset FROM %I.pg_stat_statements_info',
    v_ext_schema
  );
END
$bridge$;

CREATE TABLE IF NOT EXISTS dba_mon.schema_version (
  version text PRIMARY KEY,
  installed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  installed_by name NOT NULL DEFAULT session_user,
  description text NOT NULL
);

CREATE TABLE IF NOT EXISTS dba_mon.cluster_target (
  cluster_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cluster_name text NOT NULL UNIQUE,
  system_identifier numeric(20,0),
  enabled boolean NOT NULL DEFAULT true,
  is_local boolean NOT NULL DEFAULT true,
  service_name text,
  snapshot_interval interval NOT NULL DEFAULT interval '10 minutes',
  snapshot_retention interval NOT NULL DEFAULT interval '30 days',
  detail_retention interval NOT NULL DEFAULT interval '7 days',
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK (snapshot_interval >= interval '1 minute'),
  CHECK (snapshot_retention >= interval '1 day'),
  CHECK (is_local OR service_name IS NOT NULL)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_cluster_one_local
  ON dba_mon.cluster_target (is_local) WHERE is_local;

CREATE TABLE IF NOT EXISTS dba_mon.database_target (
  database_target_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cluster_id bigint NOT NULL REFERENCES dba_mon.cluster_target(cluster_id),
  database_name name NOT NULL,
  enabled boolean NOT NULL DEFAULT true,
  collect_pgss boolean NOT NULL DEFAULT true,
  collect_objects boolean NOT NULL DEFAULT true,
  service_name text,
  connect_timeout_seconds integer NOT NULL DEFAULT 5
    CHECK (connect_timeout_seconds BETWEEN 1 AND 60),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (cluster_id, database_name)
);

COMMENT ON COLUMN dba_mon.database_target.service_name IS
  'Optional libpq service. Passwords must be supplied through passfile/.pgpass, never this table.';

CREATE TABLE IF NOT EXISTS dba_mon.snapshot (
  snapshot_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cluster_id bigint NOT NULL REFERENCES dba_mon.cluster_target(cluster_id),
  started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at timestamptz,
  status text NOT NULL DEFAULT 'RUNNING'
    CHECK (status IN ('RUNNING','SUCCESS','PARTIAL','FAILED')),
  collector_version text NOT NULL DEFAULT '1.0.2',
  server_version_num integer NOT NULL,
  server_version text NOT NULL,
  system_identifier numeric(20,0),
  timeline_id integer,
  in_recovery boolean NOT NULL,
  postmaster_start_time timestamptz NOT NULL,
  stats_reset timestamptz,
  pgss_stats_reset timestamptz,
  block_size integer NOT NULL,
  wal_segment_size integer NOT NULL,
  error_count integer NOT NULL DEFAULT 0,
  warning_count integer NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS ix_snapshot_cluster_time
  ON dba_mon.snapshot(cluster_id, started_at DESC);

CREATE TABLE IF NOT EXISTS dba_mon.system_snap (
  snapshot_id bigint PRIMARY KEY
    REFERENCES dba_mon.snapshot(snapshot_id) ON DELETE CASCADE,
  uptime_seconds numeric NOT NULL,
  max_connections integer NOT NULL,
  total_backends integer NOT NULL,
  active_backends integer NOT NULL,
  idle_in_transaction_backends integer NOT NULL,
  waiting_backends integer NOT NULL,
  granted_locks bigint NOT NULL,
  waiting_locks bigint NOT NULL,
  database_bytes numeric NOT NULL
);

CREATE TABLE IF NOT EXISTS dba_mon.capture_component (
  snapshot_id bigint NOT NULL REFERENCES dba_mon.snapshot(snapshot_id) ON DELETE CASCADE,
  database_target_id bigint REFERENCES dba_mon.database_target(database_target_id),
  component text NOT NULL,
  started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at timestamptz,
  status text NOT NULL CHECK (status IN ('RUNNING','SUCCESS','SKIPPED','FAILED')),
  row_count bigint,
  error_sqlstate text,
  error_message text
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_capture_component
  ON dba_mon.capture_component
  (snapshot_id, component, coalesce(database_target_id, 0));

CREATE TABLE IF NOT EXISTS dba_mon.database_snap (
  snapshot_id bigint NOT NULL REFERENCES dba_mon.snapshot(snapshot_id) ON DELETE CASCADE,
  datid oid NOT NULL,
  datname name NOT NULL,
  xact_commit bigint NOT NULL,
  xact_rollback bigint NOT NULL,
  blks_read bigint NOT NULL,
  blks_hit bigint NOT NULL,
  tup_returned bigint NOT NULL,
  tup_fetched bigint NOT NULL,
  tup_inserted bigint NOT NULL,
  tup_updated bigint NOT NULL,
  tup_deleted bigint NOT NULL,
  temp_files bigint NOT NULL,
  temp_bytes bigint NOT NULL,
  deadlocks bigint NOT NULL,
  checksum_failures bigint,
  sessions bigint,
  sessions_abandoned bigint,
  sessions_fatal bigint,
  sessions_killed bigint,
  stats_reset timestamptz,
  PRIMARY KEY (snapshot_id, datid)
);

CREATE TABLE IF NOT EXISTS dba_mon.pgss_snap (
  snapshot_id bigint NOT NULL REFERENCES dba_mon.snapshot(snapshot_id) ON DELETE CASCADE,
  database_target_id bigint NOT NULL REFERENCES dba_mon.database_target(database_target_id),
  userid oid NOT NULL,
  dbid oid NOT NULL,
  toplevel boolean NOT NULL,
  queryid bigint NOT NULL,
  query text,
  plans bigint NOT NULL,
  total_plan_time double precision NOT NULL,
  calls bigint NOT NULL,
  total_exec_time double precision NOT NULL,
  rows bigint NOT NULL,
  shared_blks_hit bigint NOT NULL,
  shared_blks_read bigint NOT NULL,
  shared_blks_dirtied bigint NOT NULL,
  shared_blks_written bigint NOT NULL,
  local_blks_hit bigint NOT NULL,
  local_blks_read bigint NOT NULL,
  local_blks_dirtied bigint NOT NULL,
  local_blks_written bigint NOT NULL,
  temp_blks_read bigint NOT NULL,
  temp_blks_written bigint NOT NULL,
  shared_blk_read_time double precision NOT NULL,
  shared_blk_write_time double precision NOT NULL,
  local_blk_read_time double precision NOT NULL,
  local_blk_write_time double precision NOT NULL,
  temp_blk_read_time double precision NOT NULL,
  temp_blk_write_time double precision NOT NULL,
  wal_records bigint NOT NULL,
  wal_fpi bigint NOT NULL,
  wal_bytes numeric NOT NULL,
  PRIMARY KEY (snapshot_id, database_target_id, userid, dbid, toplevel, queryid)
);
CREATE INDEX IF NOT EXISTS ix_pgss_key_snapshot
  ON dba_mon.pgss_snap(database_target_id, userid, dbid, toplevel, queryid, snapshot_id);

CREATE TABLE IF NOT EXISTS dba_mon.io_snap (
  snapshot_id bigint NOT NULL REFERENCES dba_mon.snapshot(snapshot_id) ON DELETE CASCADE,
  backend_type text NOT NULL,
  object text NOT NULL,
  context text NOT NULL,
  reads bigint NOT NULL,
  read_bytes numeric NOT NULL,
  read_time double precision NOT NULL,
  writes bigint NOT NULL,
  write_bytes numeric NOT NULL,
  write_time double precision NOT NULL,
  writebacks bigint NOT NULL,
  writeback_time double precision NOT NULL,
  extends bigint NOT NULL,
  extend_bytes numeric NOT NULL,
  extend_time double precision NOT NULL,
  hits bigint NOT NULL,
  evictions bigint NOT NULL,
  reuses bigint NOT NULL,
  fsyncs bigint NOT NULL,
  fsync_time double precision NOT NULL,
  stats_reset timestamptz,
  PRIMARY KEY (snapshot_id, backend_type, object, context)
);

CREATE TABLE IF NOT EXISTS dba_mon.wal_snap (
  snapshot_id bigint PRIMARY KEY REFERENCES dba_mon.snapshot(snapshot_id) ON DELETE CASCADE,
  wal_records bigint NOT NULL,
  wal_fpi bigint NOT NULL,
  wal_bytes numeric NOT NULL,
  wal_buffers_full bigint NOT NULL,
  stats_reset timestamptz
);

CREATE TABLE IF NOT EXISTS dba_mon.checkpointer_snap (
  snapshot_id bigint PRIMARY KEY REFERENCES dba_mon.snapshot(snapshot_id) ON DELETE CASCADE,
  num_timed bigint NOT NULL,
  num_requested bigint NOT NULL,
  num_done bigint NOT NULL,
  restartpoints_timed bigint NOT NULL,
  restartpoints_requested bigint NOT NULL,
  restartpoints_done bigint NOT NULL,
  write_time double precision NOT NULL,
  sync_time double precision NOT NULL,
  buffers_written bigint NOT NULL,
  stats_reset timestamptz
);

CREATE TABLE IF NOT EXISTS dba_mon.bgwriter_snap (
  snapshot_id bigint PRIMARY KEY REFERENCES dba_mon.snapshot(snapshot_id) ON DELETE CASCADE,
  buffers_clean bigint NOT NULL,
  maxwritten_clean bigint NOT NULL,
  buffers_alloc bigint NOT NULL,
  stats_reset timestamptz
);

CREATE TABLE IF NOT EXISTS dba_mon.archiver_snap (
  snapshot_id bigint PRIMARY KEY REFERENCES dba_mon.snapshot(snapshot_id) ON DELETE CASCADE,
  archived_count bigint NOT NULL,
  last_archived_wal text,
  last_archived_time timestamptz,
  failed_count bigint NOT NULL,
  last_failed_wal text,
  last_failed_time timestamptz,
  stats_reset timestamptz
);

CREATE TABLE IF NOT EXISTS dba_mon.replication_snap (
  snapshot_id bigint NOT NULL REFERENCES dba_mon.snapshot(snapshot_id) ON DELETE CASCADE,
  pid integer NOT NULL,
  usesysid oid,
  usename name,
  application_name text,
  client_addr inet,
  state text,
  sent_lsn pg_lsn,
  write_lsn pg_lsn,
  flush_lsn pg_lsn,
  replay_lsn pg_lsn,
  write_lag interval,
  flush_lag interval,
  replay_lag interval,
  sync_state text,
  reply_time timestamptz,
  PRIMARY KEY (snapshot_id, pid)
);

CREATE TABLE IF NOT EXISTS dba_mon.slot_snap (
  snapshot_id bigint NOT NULL REFERENCES dba_mon.snapshot(snapshot_id) ON DELETE CASCADE,
  slot_name name NOT NULL,
  slot_type text NOT NULL,
  database name,
  active boolean NOT NULL,
  active_pid integer,
  restart_lsn pg_lsn,
  confirmed_flush_lsn pg_lsn,
  wal_status text,
  safe_wal_size bigint,
  inactive_since timestamptz,
  conflicting boolean,
  PRIMARY KEY (snapshot_id, slot_name)
);

CREATE TABLE IF NOT EXISTS dba_mon.table_snap (
  snapshot_id bigint NOT NULL REFERENCES dba_mon.snapshot(snapshot_id) ON DELETE CASCADE,
  database_target_id bigint NOT NULL REFERENCES dba_mon.database_target(database_target_id),
  relid oid NOT NULL,
  schemaname name NOT NULL,
  relname name NOT NULL,
  seq_scan bigint NOT NULL,
  seq_tup_read bigint NOT NULL,
  idx_scan bigint,
  idx_tup_fetch bigint,
  n_tup_ins bigint NOT NULL,
  n_tup_upd bigint NOT NULL,
  n_tup_del bigint NOT NULL,
  n_tup_hot_upd bigint NOT NULL,
  n_live_tup bigint NOT NULL,
  n_dead_tup bigint NOT NULL,
  n_mod_since_analyze bigint NOT NULL,
  last_vacuum timestamptz,
  last_autovacuum timestamptz,
  last_analyze timestamptz,
  last_autoanalyze timestamptz,
  vacuum_count bigint NOT NULL,
  autovacuum_count bigint NOT NULL,
  analyze_count bigint NOT NULL,
  autoanalyze_count bigint NOT NULL,
  total_relation_size bigint,
  PRIMARY KEY (snapshot_id, database_target_id, relid)
);

CREATE TABLE IF NOT EXISTS dba_mon.index_snap (
  snapshot_id bigint NOT NULL REFERENCES dba_mon.snapshot(snapshot_id) ON DELETE CASCADE,
  database_target_id bigint NOT NULL REFERENCES dba_mon.database_target(database_target_id),
  indexrelid oid NOT NULL,
  relid oid NOT NULL,
  schemaname name NOT NULL,
  relname name NOT NULL,
  indexrelname name NOT NULL,
  idx_scan bigint NOT NULL,
  last_idx_scan timestamptz,
  idx_tup_read bigint NOT NULL,
  idx_tup_fetch bigint NOT NULL,
  index_size bigint,
  PRIMARY KEY (snapshot_id, database_target_id, indexrelid)
);

INSERT INTO dba_mon.schema_version(version, description)
VALUES ('1.0.2', 'Reliable component failure recording')
ON CONFLICT (version) DO NOTHING;

COMMIT;

\ir capture.sql
\ir retention.sql
