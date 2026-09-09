\set ON_ERROR_STOP on

SELECT version FROM dba_mon.schema_version ORDER BY installed_at DESC LIMIT 1;
SELECT extname FROM pg_extension WHERE extname IN ('dblink','pg_stat_statements');
SELECT cluster_id,cluster_name,enabled,is_local FROM dba_mon.cluster_target;
SELECT database_target_id,database_name,enabled,collect_pgss,collect_objects
FROM dba_mon.database_target ORDER BY database_name;
SELECT to_regprocedure('dba_mon.generate_html_report(bigint,bigint)')
  AS html_report_function;

CALL dba_mon.capture_snapshot();

SELECT * FROM dba_mon.v_snapshot_health ORDER BY snapshot_id DESC LIMIT 1;
SELECT component,database_target_id,status,row_count,error_sqlstate,error_message
FROM dba_mon.capture_component
WHERE snapshot_id=(SELECT max(snapshot_id) FROM dba_mon.snapshot)
ORDER BY component,database_target_id NULLS FIRST;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM dba_mon.capture_component
    WHERE snapshot_id=(SELECT max(snapshot_id) FROM dba_mon.snapshot)
      AND status='RUNNING'
  ) THEN RAISE EXCEPTION 'validation failed: unfinished components'; END IF;
END $$;
