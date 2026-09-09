# postgres-awr 1.1.0

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

Version 1.1 adds arbitrary-interval SQL APIs and self-contained HTML reports.
ASH-style sampling remains deferred to a later release.

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

## Mandatory target configuration

Installation creates repository objects but does not automatically select
application databases. Before database-level statistics can be collected, add:

1. exactly one local `cluster_target` row for this PostgreSQL instance; and
2. one enabled `database_target` row for every database to monitor.

Without `database_target` rows, cluster-wide components still succeed, but
`pgss_snap`, `table_snap`, `index_snap`, and `v_pgss_delta` remain empty.

### 1. Register the local PostgreSQL instance

```sql
INSERT INTO dba_mon.cluster_target(cluster_name)
VALUES ('prod-cluster-01')
ON CONFLICT (cluster_name) DO NOTHING
RETURNING cluster_id;
```

Confirm the cluster identifier:

```sql
SELECT cluster_id, cluster_name, enabled, is_local
FROM dba_mon.cluster_target;
```

`cluster_target` means one PostgreSQL data directory/instance. It does not
require Patroni, replication, or any other HA technology.

### 2. List databases that can be monitored

```sql
SELECT datname
FROM pg_database
WHERE datallowconn
  AND NOT datistemplate
ORDER BY datname;
```

Do not register template databases. Register only databases whose workload and
objects are required in reports.

### 3. Enable `pg_stat_statements` in each target database

Connect to each selected database and run:

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SELECT count(*) AS tracked_statements FROM pg_stat_statements;
```

Creating the extension is database-scoped even though its statistics are held
in shared memory at the PostgreSQL-instance level.

### 4. Register one database target

For a database in the same PostgreSQL instance, leave `service_name` as `NULL`.
This is the normal configuration for local database targets. The collector will
connect using `dbname=<database_name> connect_timeout=<seconds>` and PostgreSQL's
default local connection settings:

```sql
INSERT INTO dba_mon.database_target
  (cluster_id, database_name, service_name, collect_pgss, collect_objects)
SELECT cluster_id, 'appdb', NULL, true, true
FROM dba_mon.cluster_target
WHERE enabled AND is_local
ON CONFLICT (cluster_id, database_name) DO UPDATE
SET enabled = true,
    collect_pgss = EXCLUDED.collect_pgss,
    collect_objects = EXCLUDED.collect_objects;
```

Replace `appdb` with the real application database name. Repeat the statement
for every database to monitor.

The resulting connection is equivalent to `dbname=appdb connect_timeout=5`.
Do not create a service entry merely because the target is another database;
PostgreSQL requires `dblink` for cross-database access even when both databases
are local to the same instance. Configure `service_name` only when the target is
remote or when local/default authentication cannot establish the connection.

### 5. Service-based target when required

Define a service on the PostgreSQL database server:

```ini
[prod_appdb_monitor]
host=/var/run/postgresql
port=5432
dbname=appdb
user=dba_mon_collector
application_name=postgres-awr
connect_timeout=5
```

On Windows, replace the Unix socket with the server address, for example
`host=127.0.0.1`. Add authentication through a protected passfile; do not put a
password in `database_target.service_name`.

Register or update the target:

```sql
INSERT INTO dba_mon.database_target
  (cluster_id, database_name, service_name, collect_pgss, collect_objects)
SELECT cluster_id, 'appdb', 'prod_appdb_monitor', true, true
FROM dba_mon.cluster_target
WHERE enabled AND is_local
ON CONFLICT (cluster_id, database_name) DO UPDATE
SET service_name = EXCLUDED.service_name,
    enabled = true,
    collect_pgss = EXCLUDED.collect_pgss,
    collect_objects = EXCLUDED.collect_objects;
```

### 6. Verify target registration

```sql
SELECT database_target_id, cluster_id, database_name, service_name,
       enabled, collect_pgss, collect_objects
FROM dba_mon.database_target
ORDER BY database_target_id;
```

At least one enabled row with `collect_pgss = true` is required for SQL deltas.

`pg_stat_statements` stores instance-wide statistics and identifies the source
database with `dbid`. The collector filters every target to the OID of the
database reached by that target, so application SQL is not duplicated across
database targets.

If the repository database itself is registered so its tables and indexes can
be monitored, normally disable SQL capture for it. This prevents snapshot and
repository-management statements from appearing in workload reports:

```sql
UPDATE dba_mon.database_target
SET collect_pgss = false,
    collect_objects = true
WHERE database_name = 'postgres_monitoring';
```

### 7. Test the target connection before capture

For a target without a service:

```sql
SELECT *
FROM dblink(
  'dbname=appdb connect_timeout=5',
  'SELECT current_database(), current_user, count(*) FROM pg_stat_statements'
) AS t(database_name name, login_name name, tracked_statements bigint);
```

For a service-based target:

```sql
SELECT *
FROM dblink(
  'service=prod_appdb_monitor connect_timeout=5',
  'SELECT current_database(), current_user, count(*) FROM pg_stat_statements'
) AS t(database_name name, login_name name, tracked_statements bigint);
```

This must return one row. Resolve authentication, service-file, extension, or
privilege errors before scheduling snapshots.

### Multiple database example

Each database requires its own service because a libpq service selects one
database:

```sql
INSERT INTO dba_mon.database_target
  (cluster_id,database_name,service_name)
SELECT cluster_id, v.database_name, v.service_name
FROM dba_mon.cluster_target
CROSS JOIN (VALUES
  ('appdb'::name,   'prod_appdb_monitor'::text),
  ('orders'::name,  'prod_orders_monitor'::text),
  ('reporting'::name,'prod_reporting_monitor'::text)
) AS v(database_name, service_name)
WHERE enabled AND is_local
ON CONFLICT (cluster_id, database_name) DO UPDATE
SET service_name = EXCLUDED.service_name,
    enabled = true;
```

The older hard-coded form below is equivalent but requires you to know the
actual `cluster_id`:

```sql

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
  '0 1 * * *',
  $$CALL dba_mon.purge_snapshots()$$
);
```

If `pg_cron` is not approved, invoke the same calls from a systemd timer or the
enterprise scheduler. Do not run concurrent collectors.

For Linux `crontab`, install all three jobs under the PostgreSQL operating-system
account. Replace `/opt/Postgres-AWR` and `/usr/bin/psql` with the actual paths:

```cron
# Main snapshot every 10 minutes
*/10 * * * * /usr/bin/psql -X -v ON_ERROR_STOP=1 -d postgres_monitoring -c "CALL dba_mon.capture_snapshot();" >> /var/log/postgresql/postgres-awr-capture.log 2>&1

# Start the wait-sampling minute runner once per minute
* * * * * /usr/bin/psql -X -v ON_ERROR_STOP=1 -d postgres_monitoring -f /opt/Postgres-AWR/wait_sampler.sql >> /var/log/postgresql/postgres-awr-waits.log 2>&1

# Snapshot and detailed-sample retention purge every night at 01:00
0 1 * * * /usr/bin/psql -X -v ON_ERROR_STOP=1 -d postgres_monitoring -c "CALL dba_mon.purge_snapshots();" >> /var/log/postgresql/postgres-awr-purge.log 2>&1
```

Linux cron does not schedule below one minute. `wait_sampler.sql` therefore
calls `capture_wait_samples(6,10)`, which captures internally at 0, 10, 20, 30,
40 and 50 seconds. An advisory lock prevents overlapping minute runners. Each
sample groups active backends only by `wait_event_type` and `wait_event`;
active backends without a wait event are recorded as `CPU / CPU`. Detailed
samples use `detail_retention` and are purged by `purge_snapshots()`.

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
GRANT EXECUTE ON PROCEDURE dba_mon.capture_wait_sample()
  TO dba_mon_collector;
GRANT EXECUTE ON PROCEDURE dba_mon.capture_wait_samples(integer,numeric)
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

## HTML interval reports

Version 1.1 generates a self-contained HTML report between any two snapshots
from the same cluster. Use successful endpoints that do not cross a PostgreSQL
restart or statistics reset.

List candidate endpoints:

```sql
SELECT snapshot_id,started_at,completed_at,status,error_count
FROM dba_mon.snapshot
ORDER BY snapshot_id DESC
LIMIT 20;
```

Inspect the interval and quality checks before export:

```sql
SELECT * FROM dba_mon.report_interval(100,110);
SELECT * FROM dba_mon.report_quality(100,110)
ORDER BY severity,check_name;
```

Generate the report on the client running `psql`:

```bash
psql -X -v ON_ERROR_STOP=1 \
  -d postgres_monitoring \
  -v begin_snap=100 \
  -v end_snap=110 \
  -v output_file=postgres_awr_100_110.html \
  -f report.sql
```

`output_file` is written by `psql`, not by the PostgreSQL server. Use a trusted
local filename and run the command from the release directory. The report has
embedded CSS, no JavaScript, and no external network dependencies.

Run the SQL/API validation separately:

```bash
psql -X -v ON_ERROR_STOP=1 \
  -d postgres_monitoring \
  -v begin_snap=100 \
  -v end_snap=110 \
  -f validate_report.sql
```

Available report APIs:

- `report_interval(begin_id,end_id)`
- `report_quality(begin_id,end_id)`
- `report_pgss_delta(begin_id,end_id)`
- `report_database_delta(begin_id,end_id)`
- `report_wal_delta(begin_id,end_id)`
- `report_checkpointer_delta(begin_id,end_id)`
- `report_bgwriter_delta(begin_id,end_id)`
- `report_archiver_delta(begin_id,end_id)`
- `report_io_delta(begin_id,end_id)`
- `report_table_delta(begin_id,end_id)`
- `report_vacuum_delta(begin_id,end_id)`
- `report_index_delta(begin_id,end_id)`
- `report_wait_summary(begin_id,end_id)`
- `report_wait_chart(begin_id,end_id)`
- `generate_html_report(begin_id,end_id)`

Grant report execution to the read-only role after installation or upgrade:

```sql
GRANT EXECUTE ON FUNCTION dba_mon.report_interval(bigint,bigint) TO dba_mon_reader;
GRANT EXECUTE ON FUNCTION dba_mon.report_quality(bigint,bigint) TO dba_mon_reader;
GRANT EXECUTE ON FUNCTION dba_mon.report_pgss_delta(bigint,bigint) TO dba_mon_reader;
GRANT EXECUTE ON FUNCTION dba_mon.report_database_delta(bigint,bigint) TO dba_mon_reader;
GRANT EXECUTE ON FUNCTION dba_mon.report_wal_delta(bigint,bigint) TO dba_mon_reader;
GRANT EXECUTE ON FUNCTION dba_mon.report_checkpointer_delta(bigint,bigint) TO dba_mon_reader;
GRANT EXECUTE ON FUNCTION dba_mon.report_bgwriter_delta(bigint,bigint) TO dba_mon_reader;
GRANT EXECUTE ON FUNCTION dba_mon.report_archiver_delta(bigint,bigint) TO dba_mon_reader;
GRANT EXECUTE ON FUNCTION dba_mon.report_io_delta(bigint,bigint) TO dba_mon_reader;
GRANT EXECUTE ON FUNCTION dba_mon.report_table_delta(bigint,bigint) TO dba_mon_reader;
GRANT EXECUTE ON FUNCTION dba_mon.report_vacuum_delta(bigint,bigint) TO dba_mon_reader;
GRANT EXECUTE ON FUNCTION dba_mon.report_index_delta(bigint,bigint) TO dba_mon_reader;
GRANT EXECUTE ON FUNCTION dba_mon.report_wait_summary(bigint,bigint) TO dba_mon_reader;
GRANT EXECUTE ON FUNCTION dba_mon.report_wait_chart(bigint,bigint) TO dba_mon_reader;
GRANT EXECUTE ON FUNCTION dba_mon.generate_html_report(bigint,bigint) TO dba_mon_reader;
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
- schema version `1.1.0` is returned;
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

The legacy consecutive `v_pgss_delta` view does not enforce every marker, but
the v1.1 interval report functions reject cross-reset and cross-restart deltas.

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
- A PostgreSQL restart or statistics reset splits report intervals. Version
  1.1 report functions enforce these markers before returning cumulative deltas.
- The repository captures all `pg_stat_statements` rows. Top-N belongs in the
  report layer, eliminating endpoint-selection bias.

## Known v1 boundaries

- One local cluster per repository is enforced.
- Remote cluster-wide capture is not implemented.
- Cross-database collection is sequential and bounded by connection timeout.
- Function, subscription, SLRU and configuration-history snapshots are planned
  for a later release.
- ASH-style sampling is planned for a later release.
