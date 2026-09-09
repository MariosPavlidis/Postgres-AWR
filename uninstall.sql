\set ON_ERROR_STOP on
\echo 'This permanently removes the repository and all monitoring history.'
\if :{?confirm_uninstall}
\else
  \set confirm_uninstall 'NO'
\endif

SELECT upper(:'confirm_uninstall')='YES' AS confirmed \gset
\if :confirmed
  DROP SCHEMA dba_mon CASCADE;
  \echo 'dba_mon removed'
\else
  \echo 'Cancelled. Run: psql -v confirm_uninstall=YES -f uninstall.sql'
\endif

