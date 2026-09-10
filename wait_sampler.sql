\set ON_ERROR_STOP on

-- Linux cron starts this file once per minute. The procedure takes thirty
-- samples internally at two-second intervals throughout the minute.
CALL dba_mon.capture_wait_samples(30,2::numeric);
