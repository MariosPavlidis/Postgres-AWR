\set ON_ERROR_STOP on

\echo ''
\echo '------------------------------------------------------------'
\echo '  postgres-awr  |  upgrade to 1.5.0'
\echo '------------------------------------------------------------'
\echo ''

BEGIN;

-- Suppress "already exists, skipping" notices from IF NOT EXISTS DDL.
SET LOCAL client_min_messages = WARNING;

\echo '  [1/4]  verifying installation'
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

\echo '  [2/4]  applying schema changes'
ALTER TABLE dba_mon.snapshot
  ALTER COLUMN collector_version SET DEFAULT '1.5.0';

ALTER TABLE dba_mon.wait_sample
  ADD COLUMN IF NOT EXISTS application_name text NOT NULL DEFAULT '';

CREATE TABLE IF NOT EXISTS dba_mon.long_txn_snap (
  snapshot_id      bigint NOT NULL REFERENCES dba_mon.snapshot(snapshot_id) ON DELETE CASCADE,
  pid              integer NOT NULL,
  usename          name,
  application_name text,
  client_addr      inet,
  xact_start       timestamptz NOT NULL,
  xact_age_seconds numeric NOT NULL,
  query_start      timestamptz,
  state            text,
  wait_event_type  text,
  wait_event       text,
  query_text       text,
  PRIMARY KEY (snapshot_id, pid)
);

CREATE TABLE IF NOT EXISTS dba_mon.conn_profile_snap (
  snapshot_id      bigint  NOT NULL REFERENCES dba_mon.snapshot(snapshot_id) ON DELETE CASCADE,
  application_name text    NOT NULL,
  usename          name    NOT NULL,
  state            text    NOT NULL,
  session_count    integer NOT NULL CHECK (session_count >= 0),
  PRIMARY KEY (snapshot_id, application_name, usename, state)
);

CREATE TABLE IF NOT EXISTS dba_mon.blocked_session_snap (
  snapshot_id            bigint  NOT NULL REFERENCES dba_mon.snapshot(snapshot_id) ON DELETE CASCADE,
  waiter_pid             integer NOT NULL,
  waiter_usename         name,
  waiter_app             text,
  waiter_wait_event_type text,
  waiter_wait_event      text,
  waiter_query           text,
  blocked_seconds        numeric NOT NULL,
  blocker_pid            integer,
  blocker_usename        name,
  blocker_app            text,
  blocker_state          text,
  blocker_query          text,
  PRIMARY KEY (snapshot_id, waiter_pid)
);

CREATE TABLE IF NOT EXISTS dba_mon.autovacuum_snap (
  snapshot_id      bigint  NOT NULL REFERENCES dba_mon.snapshot(snapshot_id) ON DELETE CASCADE,
  pid              integer NOT NULL,
  query            text,
  duration_seconds numeric NOT NULL,
  PRIMARY KEY (snapshot_id, pid)
);

-- Load all executable objects before recording the release version. Keeping
-- these includes inside the transaction prevents a repository from claiming a
-- new version when an adjacent deployment file is stale, missing, or invalid.
\echo '  [3/4]  loading executable objects'
\ir capture.sql
\ir waits.sql
\ir retention.sql
\ir reporting.sql

\echo '  [4/4]  recording version'
INSERT INTO dba_mon.schema_version(version, description)
VALUES ('1.5.0', 'Add session monitoring: long txn, conn profile, blocked sessions, autovacuum, wait sampler app_name, sidenav')
ON CONFLICT (version) DO NOTHING;

COMMIT;

\echo ''
\echo '  postgres-awr is now at version 1.5.0'
\echo ''
