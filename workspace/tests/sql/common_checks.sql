-- =============================================================================
-- tests/sql/common_checks.sql
-- Purpose: Read ACTUAL values that the acceptance runner compares with the
--          fixed expected values in tests/expected/<scenario>.csv.
-- Prerequisites: A scenario has been executed in this isolated database.
-- Inputs: Saved observations, load runs, raw extracts, stock checks and the
--         scenario step log.
-- Outputs: Rows (check_name, actual) as text. NULL means "no value".
-- Execution: scripts/run_acceptance.py runs this file for every scenario,
--            then tests/sql/<scenario>.sql for scenario-specific checks.
-- Transaction: Read-only.
-- Rerun behaviour: Read-only; safe to rerun.
--
-- These queries only READ what the prototype saved; they never recompute a
-- quantity. Expected values are written independently from the Spec, so a
-- calculation error cannot make its own test pass. Only check names that
-- appear in the expected file are compared; other rows are ignored.
-- Times are shown in Sydney time as YYYY-MM-DD HH24:MI.
-- =============================================================================

WITH observation AS (
    SELECT rr.checkpoint_code, p.sku, l.location_code, o.*
      FROM rpt.report_run AS rr
      JOIN rpt.inventory_observation AS o ON o.report_run_id = rr.report_run_id
      JOIN dw.dim_product AS p ON p.product_key = o.product_key
      JOIN dw.dim_location AS l ON l.location_key = o.location_key
     WHERE rr.status = 'ready'
),
inventory_metric AS (
    SELECT o.checkpoint_code || '/' || o.sku || '@' || o.location_code || '/' || m.metric AS check_name,
           m.actual
      FROM observation AS o
     CROSS JOIN LATERAL (VALUES
        ('website_available',      o.website_available_quantity::text),
        ('website_quality_status', o.website_quality_status),
        ('on_hand',                o.on_hand_quantity::text),
        ('reserved',               o.reserved_quantity::text),
        ('available',              o.available_quantity::text),
        ('shortfall',              o.shortfall_quantity::text),
        ('difference',             o.availability_difference::text),
        ('quality_status',         o.quality_status),
        ('opening_quantity',       o.opening_quantity::text),
        ('opening_cutoff_at',      to_char(o.opening_cutoff_at AT TIME ZONE 'Australia/Sydney', 'YYYY-MM-DD HH24:MI')),
        ('movement_quantity',      o.movement_quantity::text)
     ) AS m(metric, actual)
),
-- What central's current balance showed at each load: taken from the raw
-- extract of src_stock.stock_on_hand made by that load.
central_recorded AS (
    SELECT lr.run_code || '/' || s.sku || '@' || s.location_code || '/central_recorded_on_hand' AS check_name,
           s.on_hand_quantity::text AS actual
      FROM raw.stock_stock_on_hand AS s
      JOIN audit.load_run AS lr ON lr.load_run_id = s.load_run_id
),
order_line_metric AS (
    SELECT rr.checkpoint_code || '/' || f.order_id || '-' || f.line_id || '/' || m.metric AS check_name,
           m.actual
      FROM rpt.report_run AS rr
      JOIN rpt.order_line_observation AS o ON o.report_run_id = rr.report_run_id
      JOIN dw.fact_order_line AS f ON f.order_line_key = o.order_line_key
     CROSS JOIN LATERAL (VALUES
        ('effective_status',    o.effective_status),
        ('allocated',           o.allocated_quantity::text),
        ('line_shortfall',      o.line_shortfall_quantity::text),
        ('cancellation_reason', o.cancellation_reason),
        ('cancelled_at',        to_char(o.cancelled_at AT TIME ZONE 'Australia/Sydney', 'YYYY-MM-DD HH24:MI'))
     ) AS m(metric, actual)
     WHERE rr.status = 'ready'
),
load_metric AS (
    SELECT lr.run_code || '/' || m.metric AS check_name, m.actual
      FROM audit.load_run AS lr
     CROSS JOIN LATERAL (VALUES
        ('load_status', lr.status),
        ('published_at_is_null', (lr.published_at IS NULL)::text),
        ('facts_first_loaded_by_run', (
            (SELECT count(*) FROM dw.fact_stock_movement WHERE first_load_run_id = lr.load_run_id)
          + (SELECT count(*) FROM dw.fact_order_line WHERE first_load_run_id = lr.load_run_id)
          + (SELECT count(*) FROM dw.fact_order_status_event WHERE first_load_run_id = lr.load_run_id)
          + (SELECT count(*) FROM dw.fact_stock_snapshot WHERE first_load_run_id = lr.load_run_id)
          + (SELECT count(*) FROM dw.fact_web_stock_copy WHERE first_load_run_id = lr.load_run_id))::text),
        ('raw_sale_lines_extracted', (SELECT count(*) FROM raw.store_sales_sale_line WHERE load_run_id = lr.load_run_id)::text),
        ('extract_manifest_rows', (SELECT count(*) FROM audit.source_extract WHERE load_run_id = lr.load_run_id)::text),
        ('ready_report_runs', (SELECT count(*) FROM rpt.report_run AS r
                                WHERE r.load_run_id = lr.load_run_id AND r.status = 'ready')::text)
     ) AS m(metric, actual)
),
issue_metric AS (
    SELECT lr.run_code || '/issue_count/' || i.rule_code AS check_name, count(*)::text AS actual
      FROM audit.data_quality_issue AS i
      JOIN audit.load_run AS lr ON lr.load_run_id = i.load_run_id
     GROUP BY lr.run_code, i.rule_code
),
check_metric AS (
    SELECT c.check_code || '/overall_result' AS check_name, c.overall_result AS actual
      FROM rpt.stock_check AS c
    UNION ALL
    SELECT c.check_code || '/' || l.sku || '/' || m.metric, m.actual
      FROM rpt.stock_check AS c
      JOIN rpt.stock_check_line AS l ON l.check_id = c.check_id
     CROSS JOIN LATERAL (VALUES
        ('requested_quantity', l.requested_quantity::text),
        ('available_quantity', l.available_quantity::text),
        ('line_result',        l.line_result)
     ) AS m(metric, actual)
),
website_age_metric AS (
    SELECT a.checkpoint_code || '/' || m.metric AS check_name, m.actual
      FROM rpt.v_website_stock_age AS a
     CROSS JOIN LATERAL (VALUES
        ('website_snapshot_cutoff_at', to_char(a.website_snapshot_cutoff_at AT TIME ZONE 'Australia/Sydney', 'YYYY-MM-DD HH24:MI')),
        ('website_copied_at',          to_char(a.website_copied_at AT TIME ZONE 'Australia/Sydney', 'YYYY-MM-DD HH24:MI')),
        ('website_basis_age',          a.website_basis_age::text),
        ('website_copy_age',           a.website_copy_age::text),
        ('website_copy_lag',           a.website_copy_lag::text)
     ) AS m(metric, actual)
),
step_metric AS (
    SELECT 'step/' || s.step_code || '/status' AS check_name, s.status AS actual
      FROM audit.scenario_step AS s
)
SELECT check_name, actual FROM inventory_metric
UNION ALL SELECT check_name, actual FROM central_recorded
UNION ALL SELECT check_name, actual FROM order_line_metric
UNION ALL SELECT check_name, actual FROM load_metric
UNION ALL SELECT check_name, actual FROM issue_metric
UNION ALL SELECT check_name, actual FROM check_metric
UNION ALL SELECT check_name, actual FROM website_age_metric
UNION ALL SELECT check_name, actual FROM step_metric
UNION ALL SELECT 'final/web_order_count', count(*)::text FROM src_online.web_order;
