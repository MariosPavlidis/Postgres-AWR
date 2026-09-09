\set ON_ERROR_STOP on

-- Linux cron starts this file once per minute. The procedure takes six
-- samples internally at 0, 10, 20, 30, 40 and 50 seconds.
CALL dba_mon.capture_wait_samples(6,10);
