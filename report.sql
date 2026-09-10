\set ON_ERROR_STOP on

\if :{?begin_snap}
\else
  \echo 'ERROR: supply -v begin_snap=<snapshot_id>'
  \quit 3
\endif
\if :{?end_snap}
\else
  \echo 'ERROR: supply -v end_snap=<snapshot_id>'
  \quit 3
\endif
\if :{?output_file}
\else
  \echo 'ERROR: supply -v output_file=<path>'
  \quit 3
\endif

\pset format unaligned
\pset tuples_only on
\pset footer off
\o :output_file
SELECT dba_mon.generate_html_report(:begin_snap::bigint, :end_snap::bigint);
\o
\echo 'HTML report written to' :output_file
