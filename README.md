# postgres-awr 1.0.1

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
- reset-safe consecutive SQL deltas

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

## Data-quality rules

- A snapshot is `SUCCESS` only when all enabled components succeed.
- A component failure makes the snapshot `PARTIAL`; successful components stay
  available.
- SQL delta rows exist only when both endpoints contain the statement and its
  counters did not decrease.
- A PostgreSQL restart or statistics reset must split report intervals. Report
  code must compare snapshot reset markers before calculating cumulative deltas.
- The repository captures all `pg_stat_statements` rows. Top-N belongs in the
  report layer, eliminating endpoint-selection bias.

## Known v1 boundaries

- One local cluster per repository is enforced.
- Remote cluster-wide capture is not implemented.
- Cross-database collection is sequential and bounded by connection timeout.
- Function, subscription, SLRU and configuration-history snapshots are planned
  for v1.1.
- ASH-style sampling and HTML reporting are planned for v1.1.
