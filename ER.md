# Repository ER model

```mermaid
erDiagram
  CLUSTER_TARGET ||--o{ DATABASE_TARGET : contains
  CLUSTER_TARGET ||--o{ SNAPSHOT : produces
  SNAPSHOT ||--o{ CAPTURE_COMPONENT : audits
  DATABASE_TARGET ||--o{ CAPTURE_COMPONENT : scopes
  SNAPSHOT ||--o{ DATABASE_SNAP : contains
  SNAPSHOT ||--o{ PGSS_SNAP : contains
  DATABASE_TARGET ||--o{ PGSS_SNAP : scopes
  SNAPSHOT ||--o{ IO_SNAP : contains
  SNAPSHOT ||--o| WAL_SNAP : contains
  SNAPSHOT ||--o| CHECKPOINTER_SNAP : contains
  SNAPSHOT ||--o| BGWRITER_SNAP : contains
  SNAPSHOT ||--o| ARCHIVER_SNAP : contains
  SNAPSHOT ||--o{ REPLICATION_SNAP : contains
  SNAPSHOT ||--o{ SLOT_SNAP : contains
  SNAPSHOT ||--o{ TABLE_SNAP : contains
  DATABASE_TARGET ||--o{ TABLE_SNAP : scopes
  SNAPSHOT ||--o{ INDEX_SNAP : contains
  DATABASE_TARGET ||--o{ INDEX_SNAP : scopes
```

`snapshot` is the lifecycle parent. All metric rows are deleted through its
`ON DELETE CASCADE` relationships. `capture_component` is the data-quality
ledger: it identifies missing or failed metric families independently of the
snapshot payload.

The complete logical key for a statement is:

```text
database_target_id + userid + dbid + toplevel + queryid
```

`snapshot_id` is added to that key in `pgss_snap`. This prevents top-level and
nested statements from colliding when `pg_stat_statements.track = all`.
