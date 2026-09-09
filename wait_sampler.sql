\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

SELECT pg_try_advisory_lock(hashtextextended('dba_mon.wait_sampler_runner',0)) AS acquired
\gset

\if :acquired
CALL dba_mon.capture_wait_sample();
\watch 10 5
SELECT pg_advisory_unlock(hashtextextended('dba_mon.wait_sampler_runner',0));
\else
\echo 'wait sampler already running; skipped this minute'
\endif
