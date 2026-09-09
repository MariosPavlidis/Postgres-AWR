# postgres-awr 1.0.3

SQL-only, centralized PostgreSQL monitoring repository for PostgreSQL 17 and 18.
It is AWR-inspired; it is not an Oracle AWR clone and does not use undocumented
PostgreSQL interfaces.

## Scope

This first release implements the repository and reliable snapshot foundation:

- dedicated `postgres_monitoring` database
- local cluster statistics
- per-snapshot PostgreSQL system metrics: uptime, connection utilization,
  active/waiting sessions, lock pressure and total database size
- `dblink` collection of database-scoped SQL, table and index statistics
- component-level status and errors
- version-aware `pg_stat_io` byte accounting (`op_bytes` on 17; byte
  counters on 18)
- restart and statistics-reset markers
- non-destructive, idempotent install
- overlap prevention with transaction advisory locks
- 30-day configurable snapshot retention
- SQL deltas that reject statements whose `calls` counter decreased

ASH sampling and full HTML reports are intentionally deferred to v1.1.

## Prerequisites

1. PostgreSQL 17 or 18.
2. `pg_stat_statements` in `shared_preload_libraries`.
3. Extension packages providing `pg_stat_statements` and `dblink`.
4. A dedicated database, recommended name `postgres_monitoring`.
5. A login role allowed to read monitoring views on each target database.
   Use predefined role `pg_monitor`; object size functions may require
   additional object privileges.
6. Authentication supplied by a libpq service plus passfile, or `.pgpass`.
   Never embed a password in `database_target.service_name`.

`cluster_target` uses PostgreSQL terminology: one initialized PostgreSQL data
directory is a cluster. A standalone server is fully supported; Patroni,
streaming replication and an HA manager are not prerequisites. On a standalone
server, replication snapshot tables are simply empty.

The `pg_stat_statements` extension must exist in the repository database and in
every monitored database for which `collect_pgss=true`:

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

The installer discovers the extension schema and creates a hardened local
bridge for `pg_stat_statements_info`; it does not add `public` to the
`SECURITY DEFINER` procedure search path.

Recommended settings:

```conf
shared_preload_libraries = 'pg_stat_statements'
compute_query_id = auto
track_io_timing = on
track_wal_io_timing = on
pg_stat_statements.track = all
pg_stat_statements.track_planning = on
```

## Install

Create roles explicitly to match your operating model:

```sql
CREATE ROLE dba_mon_owner NOLOGIN;
CREATE ROLE dba_mon_collector LOGIN;
CREATE ROLE dba_mon_reader NOLOGIN;
GRANT dba_mon_owner TO CURRENT_USER;
```

Create and connect to the repository:

```bash
createdb postgres_monitoring
psql -X -v ON_ERROR_STOP=1 -d postgres_monitoring -f install.sql
```

Register the local cluster and databases:

```sql
INSERT INTO dba_mon.cluster_target(cluster_name)
VALUES ('prod-cluster-01')
RETURNING cluster_id;

INSERT INTO dba_mon.database_target
  (cluster_id,database_name,service_name)
VALUES
  (1,'appdb','prod_appdb_monitor'),
  (1,'postgres','prod_postgres_monitor');
```

Example `pg_service.conf`:

```ini
[prod_appdb_monitor]
host=/var/run/postgresql
port=5432
dbname=appdb
user=dba_mon_collector
application_name=postgres-awr
connect_timeout=5
```

Store the password, if one is necessary, in a protected passfile:

```text
/var/run/postgresql:5432:appdb:dba_mon_collector:REDACTED
```

`dblink` connections are opened by the PostgreSQL server process. Therefore,
`pg_service.conf` and the passfile must be readable by the PostgreSQL operating
system account on the database server, not only by the administrator running
`psql`. Alternatively, define `PGSERVICEFILE` and `PGPASSFILE` in the PostgreSQL
service environment and restart PostgreSQL.

Validate every target before taking the first snapshot:

```sql
SELECT database_target_id, database_name, service_name,
       enabled, collect_pgss, collect_objects
FROM dba_mon.database_target
ORDER BY database_target_id;

-- Replace the service name with each configured target.
SELECT *
FROM dblink('service=prod_appdb_monitor connect_timeout=5',
            'SELECT current_database(), current_user, version()')
  AS t(database_name name, login_name name, server_version text);
```

## Capture and schedule

Manual capture:

```sql
CALL dba_mon.capture_snapshot();
```

`pg_cron` example in the monitoring database:

```sql
SELECT cron.schedule(
  'postgres-awr-snapshot',
  '*/10 * * * *',
  $$CALL dba_mon.capture_snapshot()$$
);
SELECT cron.schedule(
  'postgres-awr-purge',
  '17 2 * * *',
  $$CALL dba_mon.purge_snapshots()$$
);
```

If `pg_cron` is not approved, invoke the same calls from a systemd timer or the
enterprise scheduler. Do not run concurrent collectors.

## Security grants

Apply after installation:

```sql
ALTER SCHEMA dba_mon OWNER TO dba_mon_owner;
GRANT USAGE ON SCHEMA dba_mon TO dba_mon_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA dba_mon TO dba_mon_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE dba_mon_owner IN SCHEMA dba_mon
  GRANT SELECT ON TABLES TO dba_mon_reader;

GRANT USAGE ON SCHEMA dba_mon TO dba_mon_collector;
GRANT EXECUTE ON PROCEDURE dba_mon.capture_snapshot(bigint)
  TO dba_mon_collector;
GRANT EXECUTE ON PROCEDURE dba_mon.purge_snapshots(bigint)
  TO dba_mon_collector;
```

The procedure is `SECURITY DEFINER`; after transferring function ownership,
keep `dba_mon_owner` as `NOLOGIN` and do not grant users `CREATE` on the
repository database or schema.

## Operations

Check the last capture:

```sql
SELECT * FROM dba_mon.v_snapshot_health
ORDER BY snapshot_id DESC LIMIT 20;

SELECT component,database_target_id,status,row_count,error_sqlstate,error_message
FROM dba_mon.capture_component
WHERE snapshot_id=(SELECT max(snapshot_id) FROM dba_mon.snapshot)
ORDER BY component,database_target_id NULLS FIRST;
```

Run the smoke test in a non-production repository:

```bash
psql -X -v ON_ERROR_STOP=1 -d postgres_monitoring -f validate.sql
```

## End-to-end validation

Run these tests before scheduling capture. Tests 1-4 are safe on production;
tests 5-7 require a non-production environment.

### 1. Verify prerequisites and configuration

```sql
SHOW shared_preload_libraries;
SHOW compute_query_id;
SHOW track_io_timing;
SHOW track_wal_io_timing;

SELECT current_setting('server_version_num')::integer AS server_version_num;

SELECT e.extname, n.nspname AS extension_schema
FROM pg_extension AS e
JOIN pg_namespace AS n ON n.oid = e.extnamespace
WHERE e.extname IN ('pg_stat_statements', 'dblink')
ORDER BY e.extname;

SELECT version, installed_at, installed_by
FROM dba_mon.schema_version
ORDER BY installed_at DESC;

SELECT * FROM dba_mon.pgss_info_source;
```

Expected results:

- server version is 17.x or 18.x;
- both extensions are returned;
- schema version `1.0.3` is returned;
- `pgss_info_source` returns exactly one row;
- `pg_stat_statements` appears in `shared_preload_libraries`.

### 2. Capture the first snapshot

```sql
CALL dba_mon.capture_snapshot();

SELECT *
FROM dba_mon.v_snapshot_health
ORDER BY snapshot_id DESC
LIMIT 1;

SELECT component, database_target_id, status, row_count,
       error_sqlstate, error_message
FROM dba_mon.capture_component
WHERE snapshot_id = (SELECT max(snapshot_id) FROM dba_mon.snapshot)
ORDER BY database_target_id NULLS FIRST, component;
```

Expected result: the snapshot is `SUCCESS`, no component remains `RUNNING`,
and every enabled component is `SUCCESS`. `replication` and `slots` may
succeed with zero rows on a standalone server.

If the snapshot is `PARTIAL`, use `error_sqlstate` and `error_message` as the
primary diagnostic. Typical causes are an invalid service name, missing
passfile access, missing `pg_stat_statements` in a target database, or
insufficient privileges for object-size functions.

### 3. Generate workload and capture the second snapshot

Run representative application workload in a monitored database. For an
isolated test database, this lightweight workload is sufficient:

```sql
CREATE TABLE IF NOT EXISTS public.awr_test
(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, payload text NOT NULL);

INSERT INTO public.awr_test(payload)
SELECT repeat(md5(g::text), 8)
FROM generate_series(1, 10000) AS g;

SELECT count(*) FROM public.awr_test WHERE payload LIKE '%abc%';
UPDATE public.awr_test SET payload = payload || 'x' WHERE id % 100 = 0;
```

Take another repository snapshot after the workload:

```sql
CALL dba_mon.capture_snapshot();
```

Confirm that two completed snapshots exist:

```sql
SELECT snapshot_id, started_at, completed_at, status, error_count
FROM dba_mon.snapshot
ORDER BY snapshot_id DESC
LIMIT 2;
```

### 4. Validate captured data and SQL deltas

```sql
SELECT s.snapshot_id,
       (SELECT count(DISTINCT p.database_target_id)
          FROM dba_mon.pgss_snap AS p
         WHERE p.snapshot_id = s.snapshot_id) AS pgss_targets,
       (SELECT count(DISTINCT t.database_target_id)
          FROM dba_mon.table_snap AS t
         WHERE t.snapshot_id = s.snapshot_id) AS table_targets,
       (SELECT count(DISTINCT i.database_target_id)
          FROM dba_mon.index_snap AS i
         WHERE i.snapshot_id = s.snapshot_id) AS index_targets
FROM dba_mon.snapshot AS s
WHERE s.snapshot_id IN (
  SELECT snapshot_id FROM dba_mon.snapshot
  ORDER BY snapshot_id DESC LIMIT 2
)
ORDER BY s.snapshot_id;

SELECT database_target_id, queryid, left(query, 120) AS query,
       delta_calls, round(delta_exec_time_ms::numeric, 3) AS exec_ms,
       delta_shared_blks_read, delta_temp_blks_written, delta_wal_bytes
FROM dba_mon.v_pgss_delta
WHERE snapshot_id = (SELECT max(snapshot_id) FROM dba_mon.snapshot)
  AND delta_calls > 0
ORDER BY delta_exec_time_ms DESC
LIMIT 20;

SELECT s.snapshot_id, s.started_at, m.*
FROM dba_mon.snapshot AS s
JOIN dba_mon.system_snap AS m USING (snapshot_id)
ORDER BY s.snapshot_id DESC
LIMIT 2;
```

Expected result: workload statements appear with positive deltas and both
snapshots contain system, database and enabled database-target data.

### 5. Test partial-failure handling (non-production)

Temporarily configure a bad service name for one target, capture, inspect the
`PARTIAL` result, and restore the original value:

```sql
BEGIN;
UPDATE dba_mon.database_target
SET service_name = 'postgres_awr_deliberately_invalid'
WHERE database_target_id = :database_target_id;
CALL dba_mon.capture_snapshot();
ROLLBACK;
```

Because the transaction is rolled back, use a committed update if you need to
retain and inspect the failure snapshot. Do this only in a test repository.

### 6. Test reset and restart boundaries (non-production)

Capture immediately before and after `pg_stat_statements_reset()`,
`pg_stat_reset()`, or a PostgreSQL restart. Verify that `pgss_stats_reset`,
`stats_reset`, or `postmaster_start_time` changes. Do not interpret an interval
that crosses one of these boundaries as valid cumulative activity.

```sql
SELECT snapshot_id, started_at, postmaster_start_time,
       stats_reset, pgss_stats_reset
FROM dba_mon.snapshot
ORDER BY snapshot_id DESC
LIMIT 10;
```

Version 1.0.3 records these markers but `v_pgss_delta` does not yet enforce all
of them. Consumers must exclude reset/restart-crossing intervals.

### 7. Test retention (non-production)

Do not shorten retention on a production repository merely to test deletion.
In a disposable repository, lower `snapshot_retention`, age a test snapshot,
run the purge, and confirm cascading deletion from child tables:

```sql
CALL dba_mon.purge_snapshots();

SELECT min(started_at) AS oldest_snapshot,
       max(started_at) AS newest_snapshot,
       count(*) AS snapshot_count
FROM dba_mon.snapshot;
```

### Acceptance gate

The installation is ready for scheduling only when:

- two consecutive captures finish as `SUCCESS`;
- no component is left `RUNNING`;
- every enabled database target completes its enabled components successfully;
- representative statements produce positive SQL deltas;
- system metrics are present for both snapshots;
- collector and reader roles work without superuser membership;
- snapshot duration is comfortably below the configured interval.

## Data-quality rules

- A snapshot is `SUCCESS` only when all enabled components succeed.
- A component failure makes the snapshot `PARTIAL`; successful components stay
  available.
- SQL delta rows exist only when both endpoints contain the statement and its
  counters did not decrease.
- A PostgreSQL restart or statistics reset must split report intervals. Version
  1.0.3 records these markers, but consumers must compare them before using
  cumulative deltas.
- The repository captures all `pg_stat_statements` rows. Top-N belongs in the
  report layer, eliminating endpoint-selection bias.

## Known v1 boundaries

- One local cluster per repository is enforced.
- Remote cluster-wide capture is not implemented.
- Cross-database collection is sequential and bounded by connection timeout.
- Function, subscription, SLRU and configuration-history snapshots are planned
  for v1.1.
- ASH-style sampling and HTML reporting are planned for v1.1.
