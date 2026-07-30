\set ON_ERROR_STOP on

CREATE OR REPLACE PROCEDURE dba_mon.purge_snapshots(p_cluster_id bigint DEFAULT NULL)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,dba_mon AS $$
DECLARE v_deleted bigint;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtextextended('dba_mon.purge_snapshots',0)) THEN
    RAISE EXCEPTION 'another purge is running' USING ERRCODE='55P03';
  END IF;
  WITH gone AS (
    DELETE FROM dba_mon.snapshot s
    USING dba_mon.cluster_target c
    WHERE s.cluster_id=c.cluster_id
      AND (p_cluster_id IS NULL OR c.cluster_id=p_cluster_id)
      AND s.started_at < clock_timestamp()-c.snapshot_retention
    RETURNING 1
  ) SELECT count(*) INTO v_deleted FROM gone;
  RAISE NOTICE 'purged % snapshots',v_deleted;
END $$;

REVOKE ALL ON PROCEDURE dba_mon.purge_snapshots(bigint) FROM PUBLIC;

