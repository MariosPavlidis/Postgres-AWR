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

SELECT * FROM dba_mon.report_interval(:begin_snap::bigint,:end_snap::bigint);
SELECT * FROM dba_mon.report_quality(:begin_snap::bigint,:end_snap::bigint)
ORDER BY severity,check_name;
SELECT count(*) AS pgss_delta_rows
FROM dba_mon.report_pgss_delta(:begin_snap::bigint,:end_snap::bigint);
SELECT count(*) AS vacuum_delta_rows
FROM dba_mon.report_vacuum_delta(:begin_snap::bigint,:end_snap::bigint);
SELECT count(*) AS index_delta_rows
FROM dba_mon.report_index_delta(:begin_snap::bigint,:end_snap::bigint);
SELECT count(*) AS wait_summary_rows
FROM dba_mon.report_wait_summary(:begin_snap::bigint,:end_snap::bigint);
SELECT length(dba_mon.report_wait_chart(:begin_snap::bigint,:end_snap::bigint))
  AS wait_chart_length;

WITH h AS (
  SELECT dba_mon.generate_html_report(
    :begin_snap::bigint,:end_snap::bigint) AS html
)
SELECT 1 / CASE WHEN html IS NOT NULL
                      AND length(html)>=1000
                      AND position('<!doctype html>' in html)=1
                      AND position('Data Quality' in html)>0
                      AND position('Capture Diagnostics' in html)>0
                      AND right(html,14)='</body></html>'
                THEN 1 ELSE 0 END AS report_validation_passed
FROM h;
