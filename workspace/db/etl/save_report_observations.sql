-- =============================================================================
-- etl/save_report_observations.sql
-- Purpose: Save what the reports and the simulated stock check returned at one
--          observation time from one published load run.
-- Prerequisites: 08_reporting_objects.sql; a succeeded load run.
-- Inputs: Scenario/checkpoint labels, observation time, load run.
-- Outputs: rpt.report_run with rpt.inventory_observation and
--          rpt.order_line_observation; rpt.stock_check with its lines.
-- Execution: Called by scripts/run_pipeline.py after a successful load
--            (checkpoint) or for an explicit later reconstruction (observe).
-- Transaction: Caller-owned. A report run becomes ready in the same
--              transaction that writes its rows, so only complete report runs
--              are ever visible. A failure rolls everything back; the runner
--              then records the report run as failed.
-- Rerun behaviour: One report run per (scenario, checkpoint); a repeat with the
--                  same checkpoint code fails. Recomputing with later evidence
--                  is saved under a new checkpoint code, never over an old one.
-- Business rules: Architecture_and_Data_Model.md 13.2.
-- =============================================================================

CREATE PROCEDURE rpt.save_report_observations(
    p_scenario_code         text,
    p_checkpoint_code       text,
    p_observed_at           timestamptz,
    p_load_run_id           bigint,
    p_calculation_revision  text
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_report_run_id bigint;
BEGIN
    INSERT INTO rpt.report_run (load_run_id, scenario_code, checkpoint_code, observed_at, status, calculation_revision)
    VALUES (p_load_run_id, p_scenario_code, p_checkpoint_code, p_observed_at, 'building', p_calculation_revision)
    RETURNING report_run_id INTO v_report_run_id;

    -- Integrated result and website baseline side by side for every pair
    -- known to either calculation.
    INSERT INTO rpt.inventory_observation (
        report_run_id, product_key, location_key, snapshot_key, opening_cutoff_at, opening_quantity,
        movement_quantity, on_hand_quantity, reserved_quantity, available_quantity, shortfall_quantity,
        quality_status, web_copy_key, website_copy_id, website_snapshot_cutoff_at, website_copied_at,
        website_copied_on_hand_quantity, website_fulfilment_quantity, website_reserved_quantity,
        website_available_quantity, website_quality_status, availability_difference)
    SELECT v_report_run_id,
           coalesce(i.product_key, w.product_key),
           coalesce(i.location_key, w.location_key),
           i.snapshot_key, i.opening_cutoff_at, i.opening_quantity, i.movement_quantity,
           i.on_hand_quantity, i.reserved_quantity, i.available_quantity, i.shortfall_quantity,
           coalesce(i.quality_status, 'missing_opening'),
           w.web_copy_key, w.copy_id, w.snapshot_cutoff_at, w.copied_at, w.copied_on_hand_quantity,
           CASE WHEN w.website_quality_status = 'valid' THEN w.fulfilment_quantity END,
           CASE WHEN w.website_quality_status = 'valid' THEN w.reserved_quantity END,
           CASE WHEN w.website_quality_status = 'valid' THEN w.website_available_quantity END,
           coalesce(w.website_quality_status, 'missing_copy'),
           -- Positive: the website overstates; negative: it understates.
           CASE WHEN w.website_quality_status = 'valid'
                THEN w.website_available_quantity - i.available_quantity END
      FROM rpt.calculate_inventory(p_observed_at, p_load_run_id) AS i
      FULL JOIN rpt.calculate_website_inventory(p_observed_at, p_load_run_id) AS w
        ON w.product_key = i.product_key AND w.location_key = i.location_key;

    -- Every accepted C&C line known at the observation, including cancelled
    -- and collected ones. Only active lines receive an allocation.
    INSERT INTO rpt.order_line_observation (
        report_run_id, order_line_key, order_status_key, effective_status, requested_quantity,
        allocated_quantity, line_shortfall_quantity, is_at_risk, cancellation_reason, cancelled_at)
    SELECT v_report_run_id,
           l.order_line_key,
           st.order_status_key,
           st.effective_status,
           l.quantity,
           a.allocated_quantity,
           a.line_shortfall_quantity,
           CASE WHEN st.effective_status IN ('awaiting_pick', 'ready') THEN a.line_shortfall_quantity > 0 END,
           CASE WHEN st.effective_status = 'cancelled' THEN st.reason_code END,
           CASE WHEN st.effective_status = 'cancelled' THEN st.status_occurred_at END
      FROM dw.fact_order_line AS l
      JOIN rpt.effective_order_status(p_observed_at, p_load_run_id) AS st ON st.order_id = l.order_id
      LEFT JOIN rpt.allocate_order_stock(p_observed_at, p_load_run_id) AS a ON a.order_line_key = l.order_line_key
     WHERE l.fulfilment_type = 'click_collect'
       AND l.first_load_run_id IN (SELECT visible_load_run_id FROM rpt.visible_load_runs(p_load_run_id));

    UPDATE rpt.report_run SET status = 'ready' WHERE report_run_id = v_report_run_id;
END;
$$;
COMMENT ON PROCEDURE rpt.save_report_observations(text, text, timestamptz, bigint, text) IS
'Saves one ready report run: integrated and website quantities for every product/location and every accepted C&C order line at p_observed_at, as known by succeeded load p_load_run_id. Raises an error (writing nothing) for an unsuccessful load, an observation after the load checkpoint, or a repeated checkpoint code.';

CREATE PROCEDURE rpt.record_stock_check(
    p_scenario_code  text,
    p_check_code     text,
    p_observed_at    timestamptz,
    p_load_run_id    bigint,
    p_location_code  text,
    p_request        jsonb,
    p_system_code    text DEFAULT 'online'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_check_id bigint;
BEGIN
    CREATE TEMPORARY TABLE check_result ON COMMIT DROP AS
    SELECT * FROM rpt.check_availability(p_observed_at, p_load_run_id, p_location_code, p_request, p_system_code);

    INSERT INTO rpt.stock_check (
        scenario_code, check_code, load_run_id, observed_at, system_code, location_code,
        canonical_location_code, request, overall_result, load_status)
    SELECT p_scenario_code, p_check_code, p_load_run_id, p_observed_at, p_system_code, p_location_code,
           min(r.canonical_location_code), p_request, min(r.overall_result), min(r.load_status)
      FROM check_result AS r
    RETURNING check_id INTO v_check_id;

    INSERT INTO rpt.stock_check_line (check_id, sku, requested_quantity, available_quantity, line_result, line_quality_status)
    SELECT v_check_id, r.sku, r.requested_quantity, r.available_quantity, r.line_result, r.line_quality_status
      FROM check_result AS r;

    DROP TABLE check_result;
END;
$$;
COMMENT ON PROCEDURE rpt.record_stock_check(text, text, timestamptz, bigint, text, jsonb, text) IS
'Runs rpt.check_availability and saves its answer as evidence in rpt.stock_check and rpt.stock_check_line. Creates no order and no reservation. Raises the same input errors as rpt.check_availability.';
