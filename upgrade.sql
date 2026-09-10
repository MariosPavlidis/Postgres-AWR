\set ON_ERROR_STOP on
\echo 'Upgrading postgres-awr to 1.1.0'

BEGIN;

DO $bridge$
DECLARE
  v_ext_schema name;
BEGIN
  IF to_regclass('dba_mon.schema_version') IS NULL THEN
    RAISE EXCEPTION 'No versioned postgres-awr installation found; run install.sql';
  END IF;

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

ALTER TABLE dba_mon.database_snap
  ALTER COLUMN datname DROP NOT NULL;

ALTER TABLE dba_mon.checkpointer_snap
  ALTER COLUMN num_done DROP NOT NULL;

ALTER TABLE dba_mon.snapshot
  ALTER COLUMN collector_version SET DEFAULT '1.1.0';

CREATE TABLE IF NOT EXISTS dba_mon.wait_sample (
  wait_sample_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cluster_id bigint NOT NULL REFERENCES dba_mon.cluster_target(cluster_id),
  sampled_at timestamptz NOT NULL,
  wait_event_type text NOT NULL,
  wait_event text NOT NULL,
  session_count integer NOT NULL CHECK (session_count >= 0),
  blocked_session_count integer NOT NULL CHECK (blocked_session_count >= 0)
);

CREATE INDEX IF NOT EXISTS ix_wait_sample_time
  ON dba_mon.wait_sample (cluster_id, sampled_at);

-- Load all executable objects before recording the release version. Keeping
-- these includes inside the transaction prevents a repository from claiming a
-- new version when an adjacent deployment file is stale, missing, or invalid.
\ir capture.sql
\ir waits.sql
\ir retention.sql
\ir reporting.sql

INSERT INTO dba_mon.schema_version(version, description)
VALUES ('1.1.0', 'Snapshot interval APIs and self-contained HTML reports')
ON CONFLICT (version) DO NOTHING;

COMMIT;
