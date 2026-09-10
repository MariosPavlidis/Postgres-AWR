\set ON_ERROR_STOP on

CREATE OR REPLACE PROCEDURE dba_mon.capture_wait_sample()
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, dba_mon
AS $$
DECLARE
  v_cluster_id bigint;
  v_sampled_at timestamptz := clock_timestamp();
  v_rows integer;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtextextended('dba_mon.capture_wait_sample',0)) THEN
    RETURN;
  END IF;

  SELECT cluster_id INTO STRICT v_cluster_id
  FROM dba_mon.cluster_target
  WHERE enabled AND is_local;

  INSERT INTO dba_mon.wait_sample (
    cluster_id,sampled_at,wait_event_type,wait_event,
    session_count,blocked_session_count
  )
  SELECT
    v_cluster_id,v_sampled_at,
    CASE WHEN a.state='idle in transaction' THEN 'Idle in transaction'
         ELSE coalesce(a.wait_event_type,'CPU') END,
    CASE WHEN a.state='idle in transaction' THEN 'Idle in transaction'
         ELSE coalesce(a.wait_event,'CPU') END,
    count(*)::integer,
    count(*) FILTER (WHERE cardinality(pg_blocking_pids(a.pid)) > 0)::integer
  FROM pg_stat_activity AS a
  WHERE a.pid <> pg_backend_pid()
    AND a.backend_type = 'client backend'
    AND a.state IN ('active','idle in transaction')
  GROUP BY CASE WHEN a.state='idle in transaction' THEN 'Idle in transaction'
                ELSE coalesce(a.wait_event_type,'CPU') END,
           CASE WHEN a.state='idle in transaction' THEN 'Idle in transaction'
                ELSE coalesce(a.wait_event,'CPU') END;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows=0 THEN
    INSERT INTO dba_mon.wait_sample (
      cluster_id,sampled_at,wait_event_type,wait_event,
      session_count,blocked_session_count
    ) VALUES (v_cluster_id,v_sampled_at,'Idle','No active sessions',0,0);
  END IF;
END;
$$;

REVOKE ALL ON PROCEDURE dba_mon.capture_wait_sample() FROM PUBLIC;

CREATE OR REPLACE PROCEDURE dba_mon.capture_wait_samples(
  p_sample_count integer DEFAULT 6,
  p_interval_seconds numeric DEFAULT 10
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, dba_mon
AS $$
DECLARE
  v_sample integer;
BEGIN
  IF p_sample_count NOT BETWEEN 1 AND 60 THEN
    RAISE EXCEPTION 'sample count must be between 1 and 60'
      USING ERRCODE='22023';
  END IF;
  IF p_interval_seconds < 1 OR p_interval_seconds > 60 THEN
    RAISE EXCEPTION 'sample interval must be between 1 and 60 seconds'
      USING ERRCODE='22023';
  END IF;
  IF NOT pg_try_advisory_xact_lock(hashtextextended('dba_mon.capture_wait_samples',0)) THEN
    RETURN;
  END IF;

  FOR v_sample IN 1..p_sample_count LOOP
    CALL dba_mon.capture_wait_sample();
    IF v_sample < p_sample_count THEN
      PERFORM pg_sleep(p_interval_seconds::double precision);
    END IF;
  END LOOP;
END;
$$;

REVOKE ALL ON PROCEDURE dba_mon.capture_wait_samples(integer,numeric) FROM PUBLIC;
