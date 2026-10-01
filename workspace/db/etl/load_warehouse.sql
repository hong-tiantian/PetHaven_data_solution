-- =============================================================================
-- etl/load_warehouse.sql
-- Purpose: Publish validated records from one load run to the warehouse.
-- Prerequisites: The selected run has complete extracts and no validation
--                errors (stg.validate_sources and stg.prepare_staging done).
-- Inputs: Run-scoped staging records and approved identifier mappings.
-- Outputs: Warehouse dimensions, facts, lineage and successful publication
--          state (audit.load_run status succeeded).
-- Execution: Called by scripts/run_pipeline.py with a bound load_run_id:
--            CALL dw.load_warehouse(<load_run_id>);
-- Transaction: The runner owns one transaction for all publication writes.
--              Facts, lineage and the succeeded status commit together, so no
--              session can see a succeeded run without all of its facts.
-- Rerun behaviour: Equal business identities are retained once (ON CONFLICT
--                  DO NOTHING after validation proved equality); conflicting
--                  values were already rejected by staging. Existing facts are
--                  never overwritten and first_load_run_id never changes.
-- Failure behaviour: Any error rolls back every publication write; raw
--                    evidence (committed earlier) is retained and the runner
--                    marks the run failed in a new transaction.
-- Business rules: Architecture_and_Data_Model.md sections 7, 8 and 12.
-- =============================================================================

CREATE PROCEDURE dw.load_warehouse(p_load_run_id bigint, p_fault text DEFAULT NULL)
LANGUAGE plpgsql
AS $$
DECLARE
    v_now     timestamptz := clock_timestamp();
    v_errors  bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM audit.load_run WHERE load_run_id = p_load_run_id AND status = 'running') THEN
        RAISE EXCEPTION 'Load run % is not running', p_load_run_id;
    END IF;
    SELECT count(*) INTO v_errors
      FROM audit.data_quality_issue WHERE load_run_id = p_load_run_id AND severity = 'error';
    IF v_errors > 0 THEN
        RAISE EXCEPTION 'Load run % has % validation error(s) and cannot be published', p_load_run_id, v_errors;
    END IF;

    -- ------------------------------------------------------------ dimensions
    INSERT INTO dw.dim_product (sku, product_name, brand, category, pack_size, pack_unit, is_active, first_load_run_id)
    SELECT s.sku, s.product_name, s.brand, s.category, s.pack_size, s.pack_unit, s.is_active, p_load_run_id
      FROM stg.product AS s
     WHERE s.load_run_id = p_load_run_id
    ON CONFLICT ON CONSTRAINT uq_dim_product_sku DO NOTHING;

    INSERT INTO dw.dim_location (location_code, location_name, location_type, suburb, first_load_run_id)
    SELECT s.location_code, s.location_name, s.location_type, s.suburb, p_load_run_id
      FROM stg.location AS s
     WHERE s.load_run_id = p_load_run_id
    ON CONFLICT ON CONSTRAINT uq_dim_location_code DO NOTHING;

    -- ------------------------------------------------- physical stock events
    -- Originals first, then reversals, so a reversal can resolve the key of
    -- the movement it reverses.
    INSERT INTO dw.fact_stock_movement (
        origin_system_code, origin_event_type, origin_event_id, origin_line_id,
        product_key, location_key, event_date_key, movement_type, quantity, occurred_at, source_recorded_at,
        order_id, order_line_id, transfer_id, transfer_line_id, delivery_reference, supplier_reference,
        reason_code, reverses_movement_key, first_load_run_id, warehouse_loaded_at)
    SELECT e.origin_system_code, e.origin_event_type, e.origin_event_id, e.origin_line_id,
           p.product_key, l.location_key, dw.sydney_date_key(e.occurred_at), e.movement_type, e.quantity,
           e.occurred_at, e.source_recorded_at, e.order_id, e.order_line_id, e.transfer_id, e.transfer_line_id,
           e.delivery_reference, e.supplier_reference, e.reason_code, NULL, p_load_run_id, v_now
      FROM stg.stock_event AS e
      JOIN dw.dim_product AS p ON p.sku = e.sku
      JOIN dw.dim_location AS l ON l.location_code = e.location_code
     WHERE e.load_run_id = p_load_run_id
       AND e.movement_type <> 'reversal'
    ON CONFLICT ON CONSTRAINT uq_fact_stock_movement_origin DO NOTHING;

    INSERT INTO dw.fact_stock_movement (
        origin_system_code, origin_event_type, origin_event_id, origin_line_id,
        product_key, location_key, event_date_key, movement_type, quantity, occurred_at, source_recorded_at,
        order_id, order_line_id, transfer_id, transfer_line_id, delivery_reference, supplier_reference,
        reason_code, reverses_movement_key, first_load_run_id, warehouse_loaded_at)
    SELECT e.origin_system_code, e.origin_event_type, e.origin_event_id, e.origin_line_id,
           p.product_key, l.location_key, dw.sydney_date_key(e.occurred_at), e.movement_type, e.quantity,
           e.occurred_at, e.source_recorded_at, e.order_id, e.order_line_id, e.transfer_id, e.transfer_line_id,
           e.delivery_reference, e.supplier_reference, e.reason_code, t.movement_key, p_load_run_id, v_now
      FROM stg.stock_event AS e
      JOIN dw.dim_product AS p ON p.sku = e.sku
      JOIN dw.dim_location AS l ON l.location_code = e.location_code
      JOIN dw.fact_stock_movement AS t
        ON t.origin_system_code = e.reverses_origin_system_code
       AND t.origin_event_type = e.reverses_origin_event_type
       AND t.origin_event_id = e.reverses_origin_event_id
       AND t.origin_line_id = e.reverses_origin_line_id
     WHERE e.load_run_id = p_load_run_id
       AND e.movement_type = 'reversal'
    ON CONFLICT ON CONSTRAINT uq_fact_stock_movement_origin DO NOTHING;

    -- --------------------------------------------------------- online orders
    INSERT INTO dw.fact_order_line (
        order_id, line_id, product_key, location_key, placed_date_key, quantity, placed_at,
        source_recorded_at, fulfilment_type, first_load_run_id, warehouse_loaded_at)
    SELECT s.order_id, s.line_id, p.product_key, l.location_key, dw.sydney_date_key(s.placed_at), s.quantity,
           s.placed_at, s.source_recorded_at, s.fulfilment_type, p_load_run_id, v_now
      FROM stg.order_line AS s
      JOIN dw.dim_product AS p ON p.sku = s.sku
      JOIN dw.dim_location AS l ON l.location_code = s.location_code
     WHERE s.load_run_id = p_load_run_id
    ON CONFLICT ON CONSTRAINT uq_fact_order_line DO NOTHING;

    -- Status events are stored once per order, not repeated per line.
    INSERT INTO dw.fact_order_status_event (
        event_id, order_id, event_sequence, event_date_key, previous_status, new_status, reason_code,
        corrects_event_id, occurred_at, source_recorded_at, first_load_run_id, warehouse_loaded_at)
    SELECT s.event_id, s.order_id, s.event_sequence, dw.sydney_date_key(s.occurred_at), s.previous_status,
           s.new_status, s.reason_code, s.corrects_event_id, s.occurred_at, s.source_recorded_at,
           p_load_run_id, v_now
      FROM stg.order_status_event AS s
     WHERE s.load_run_id = p_load_run_id
    ON CONFLICT ON CONSTRAINT uq_fact_order_status_event_id DO NOTHING;

    -- ------------------------------------------- opening snapshots and copies
    INSERT INTO dw.fact_stock_snapshot (
        snapshot_id, product_key, location_key, cutoff_date_key, on_hand_quantity, cutoff_at, created_at,
        first_load_run_id, warehouse_loaded_at)
    SELECT s.snapshot_id, p.product_key, l.location_key, dw.sydney_date_key(s.cutoff_at), s.on_hand_quantity,
           s.cutoff_at, s.created_at, p_load_run_id, v_now
      FROM stg.stock_snapshot AS s
      JOIN dw.dim_product AS p ON p.sku = s.sku
      JOIN dw.dim_location AS l ON l.location_code = s.location_code
     WHERE s.load_run_id = p_load_run_id
    ON CONFLICT ON CONSTRAINT uq_fact_stock_snapshot DO NOTHING;

    INSERT INTO dw.fact_web_stock_copy (
        copy_id, product_key, location_key, copy_date_key, on_hand_quantity, source_snapshot_id,
        snapshot_cutoff_at, copied_at, first_load_run_id, warehouse_loaded_at)
    SELECT s.copy_id, p.product_key, l.location_key, dw.sydney_date_key(s.copied_at), s.on_hand_quantity,
           s.source_snapshot_id, s.snapshot_cutoff_at, s.copied_at, p_load_run_id, v_now
      FROM stg.web_stock_copy AS s
      JOIN dw.dim_product AS p ON p.sku = s.sku
      JOIN dw.dim_location AS l ON l.location_code = s.location_code
     WHERE s.load_run_id = p_load_run_id
    ON CONFLICT ON CONSTRAINT uq_fact_web_stock_copy DO NOTHING;

    -- --------------------------------------------------------------- lineage
    -- 'loaded' marks the raw row whose run created the target; 'duplicate'
    -- marks every other representation (for example the central import of a
    -- till sale, or a repeat extraction); 'supporting' marks headers/events.
    INSERT INTO audit.record_lineage (load_run_id, raw_table_name, raw_record_id, target_table_name, target_key, disposition)
    SELECT p_load_run_id, c.raw_table_name, c.raw_record_id, 'dw.fact_stock_movement', f.movement_key,
           CASE WHEN f.first_load_run_id = p_load_run_id AND c.is_original_representation
                THEN 'loaded' ELSE 'duplicate' END
      FROM stg.stock_event_candidate AS c
      JOIN dw.fact_stock_movement AS f
        ON f.origin_system_code = c.origin_system_code AND f.origin_event_type = c.origin_event_type
       AND f.origin_event_id = c.origin_event_id AND f.origin_line_id = c.origin_line_id
     WHERE c.load_run_id = p_load_run_id
    UNION ALL
    SELECT p_load_run_id, c.support_raw_table_name, c.support_raw_record_id, 'dw.fact_stock_movement',
           f.movement_key, 'supporting'
      FROM stg.stock_event_candidate AS c
      JOIN dw.fact_stock_movement AS f
        ON f.origin_system_code = c.origin_system_code AND f.origin_event_type = c.origin_event_type
       AND f.origin_event_id = c.origin_event_id AND f.origin_line_id = c.origin_line_id
     WHERE c.load_run_id = p_load_run_id
       AND c.support_raw_table_name IS NOT NULL
    UNION ALL
    SELECT p_load_run_id, 'raw.online_web_order_line', s.raw_record_id, 'dw.fact_order_line', f.order_line_key,
           CASE WHEN f.first_load_run_id = p_load_run_id THEN 'loaded' ELSE 'duplicate' END
      FROM stg.order_line AS s
      JOIN dw.fact_order_line AS f ON f.order_id = s.order_id AND f.line_id = s.line_id
     WHERE s.load_run_id = p_load_run_id
    UNION ALL
    SELECT p_load_run_id, 'raw.online_web_order', s.header_raw_record_id, 'dw.fact_order_line', f.order_line_key,
           'supporting'
      FROM stg.order_line AS s
      JOIN dw.fact_order_line AS f ON f.order_id = s.order_id AND f.line_id = s.line_id
     WHERE s.load_run_id = p_load_run_id
    UNION ALL
    SELECT p_load_run_id, 'raw.online_order_status_history', s.raw_record_id, 'dw.fact_order_status_event',
           f.order_status_key,
           CASE WHEN f.first_load_run_id = p_load_run_id THEN 'loaded' ELSE 'duplicate' END
      FROM stg.order_status_event AS s
      JOIN dw.fact_order_status_event AS f ON f.event_id = s.event_id
     WHERE s.load_run_id = p_load_run_id
    UNION ALL
    SELECT p_load_run_id, 'raw.stock_stock_snapshot', s.raw_record_id, 'dw.fact_stock_snapshot', f.snapshot_key,
           CASE WHEN f.first_load_run_id = p_load_run_id THEN 'loaded' ELSE 'duplicate' END
      FROM stg.stock_snapshot AS s
      JOIN dw.dim_product AS p ON p.sku = s.sku
      JOIN dw.dim_location AS l ON l.location_code = s.location_code
      JOIN dw.fact_stock_snapshot AS f
        ON f.snapshot_id = s.snapshot_id AND f.product_key = p.product_key AND f.location_key = l.location_key
     WHERE s.load_run_id = p_load_run_id
    UNION ALL
    SELECT p_load_run_id, 'raw.online_web_stock_copy', s.raw_record_id, 'dw.fact_web_stock_copy', f.web_copy_key,
           CASE WHEN f.first_load_run_id = p_load_run_id THEN 'loaded' ELSE 'duplicate' END
      FROM stg.web_stock_copy AS s
      JOIN dw.dim_product AS p ON p.sku = s.sku
      JOIN dw.dim_location AS l ON l.location_code = s.location_code
      JOIN dw.fact_web_stock_copy AS f
        ON f.copy_id = s.copy_id AND f.product_key = p.product_key AND f.location_key = l.location_key
     WHERE s.load_run_id = p_load_run_id
    UNION ALL
    SELECT p_load_run_id, 'raw.stock_product', s.raw_record_id, 'dw.dim_product', d.product_key,
           CASE WHEN d.first_load_run_id = p_load_run_id THEN 'loaded' ELSE 'duplicate' END
      FROM stg.product AS s
      JOIN dw.dim_product AS d ON d.sku = s.sku
     WHERE s.load_run_id = p_load_run_id
    UNION ALL
    SELECT p_load_run_id, 'raw.stock_location', s.raw_record_id, 'dw.dim_location', d.location_key,
           CASE WHEN d.first_load_run_id = p_load_run_id THEN 'loaded' ELSE 'duplicate' END
      FROM stg.location AS s
      JOIN dw.dim_location AS d ON d.location_code = s.location_code
     WHERE s.load_run_id = p_load_run_id;

    -- Test hook for T21 (failed publication): fail after the facts were
    -- written, to prove that the whole publication is rolled back.
    IF p_fault = 'fail_after_facts' THEN
        RAISE EXCEPTION 'Injected publication failure for load run % (test T21)', p_load_run_id;
    ELSIF p_fault IS NOT NULL THEN
        RAISE EXCEPTION 'Unknown fault option %', p_fault;
    END IF;

    -- --------------------------------------------------------- publication
    UPDATE audit.load_run
       SET status = 'succeeded',
           finished_at = clock_timestamp(),
           published_at = clock_timestamp(),
           publication_sequence = nextval('audit.publication_sequence'),
           scenario_published_at = source_as_of_at,
           summary_error = (
               SELECT CASE WHEN count(*) > 0 THEN count(*) || ' warning(s)' END
                 FROM audit.data_quality_issue
                WHERE load_run_id = p_load_run_id AND severity = 'warning')
     WHERE load_run_id = p_load_run_id;
END;
$$;
COMMENT ON PROCEDURE dw.load_warehouse(bigint, text) IS
'Publishes one validated load run: inserts new dimension rows and facts (existing business identities are kept unchanged), records lineage for every contributing raw row, and marks the run succeeded with a publication timestamp and sequence. Raises an error, publishing nothing, if the run is not running or has validation errors. p_fault = fail_after_facts is a test hook (T21) that raises after the facts are written.';
