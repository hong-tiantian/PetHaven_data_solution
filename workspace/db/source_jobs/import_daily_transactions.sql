-- =============================================================================
-- source_jobs/import_daily_transactions.sql
-- Purpose: Simulate central stock's 1 am IMPORT of completed till sales and
--          online collections/shipments that happened before midnight.
-- Prerequisites: 02_source_tables.sql, source_jobs/apply_local_movements.sql.
-- Inputs: p_cutoff_at (midnight) and p_processed_at (the 1 am run time).
-- Outputs: Imported src_stock.stock_movement rows and updated current balances.
-- Execution: Called by scenario steps, for example
--            CALL src_stock.import_daily_transactions('2026-09-17 00:00 Australia/Sydney',
--                                                     '2026-09-17 01:00 Australia/Sydney');
-- Transaction: All imported movements and balance applications are written in
--              the caller's transaction.
-- Rerun behaviour: Safe to rerun. Each imported row keeps the ORIGINAL event
--                  identity; an identity already present is skipped after an
--                  equality check, and a conflicting one raises an error.
-- Business rules: Spec 3.2 and 4.3 activity D; Architecture_and_Data_Model.md 11.2.
--
-- This reads the other two source databases directly because it simulates the
-- existing batch link between them. Codes are translated with central's own
-- src_stock.product_barcode and src_stock.external_location_code tables.
-- An uncollected C&C order is a reservation, not a movement, and a
-- cancellation creates no movement, so neither is imported.
-- =============================================================================

CREATE PROCEDURE src_stock.import_daily_transactions(
    p_cutoff_at     timestamptz,
    p_processed_at  timestamptz
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_problem text;
BEGIN
    CREATE TEMPORARY TABLE import_candidate ON COMMIT DROP AS
    -- Completed till sale lines before midnight.
    SELECT 'IMP-SS-' || s.sale_id || '-' || l.line_id AS movement_id,
           b.sku,
           x.location_code,
           'store_sale'::text AS movement_type,
           -l.quantity AS quantity,
           s.completed_at AS occurred_at,
           'store_sales'::text AS origin_system_code,
           'sale'::text AS origin_event_type,
           s.sale_id AS origin_event_id,
           l.line_id AS origin_line_id,
           l.barcode AS source_product_code,
           s.store_code AS source_location_code
      FROM src_store_sales.sale AS s
      JOIN src_store_sales.sale_line AS l ON l.sale_id = s.sale_id
      LEFT JOIN src_stock.product_barcode AS b ON b.barcode = l.barcode
      LEFT JOIN src_stock.external_location_code AS x
             ON x.system_code = 'store_sales' AND x.external_code = s.store_code
     WHERE s.completed_at < p_cutoff_at
       AND s.recorded_at <= p_processed_at
    UNION ALL
    -- Online collections (C&C) and shipments (home delivery) before midnight:
    -- one physical reduction per order line at the event time.
    SELECT 'IMP-OL-' || h.event_id || '-' || l.line_id,
           l.sku,
           x.location_code,
           CASE h.new_status WHEN 'collected' THEN 'online_collection' ELSE 'online_shipment' END,
           -l.quantity,
           h.occurred_at,
           'online',
           CASE h.new_status WHEN 'collected' THEN 'collection' ELSE 'shipment' END,
           h.event_id,
           l.line_id,
           l.sku,
           o.location_code
      FROM src_online.order_status_history AS h
      JOIN src_online.web_order AS o ON o.order_id = h.order_id
      JOIN src_online.web_order_line AS l ON l.order_id = h.order_id
      LEFT JOIN src_stock.external_location_code AS x
             ON x.system_code = 'online' AND x.external_code = o.location_code
     WHERE h.new_status IN ('collected', 'shipped')
       AND h.occurred_at < p_cutoff_at
       AND h.recorded_at <= p_processed_at;

    -- The existing job cannot place a sale it cannot translate.
    SELECT string_agg(DISTINCT c.origin_system_code || ' ' || c.source_product_code || ' at ' || c.source_location_code, ', ')
      INTO v_problem
      FROM import_candidate AS c
      LEFT JOIN src_stock.product AS p ON p.sku = c.sku
     WHERE p.sku IS NULL OR c.location_code IS NULL;
    IF v_problem IS NOT NULL THEN
        RAISE EXCEPTION '1 am import cannot translate: %', v_problem;
    END IF;

    -- A rerun must agree with what was imported before.
    SELECT string_agg(c.origin_event_id || ':' || c.origin_line_id, ', ')
      INTO v_problem
      FROM import_candidate AS c
      JOIN src_stock.stock_movement AS m
        ON m.origin_system_code = c.origin_system_code
       AND m.origin_event_type = c.origin_event_type
       AND m.origin_event_id = c.origin_event_id
       AND m.origin_line_id = c.origin_line_id
     WHERE (m.sku, m.location_code, m.quantity, m.occurred_at)
           IS DISTINCT FROM (c.sku, c.location_code, c.quantity, c.occurred_at);
    IF v_problem IS NOT NULL THEN
        RAISE EXCEPTION '1 am import found conflicting earlier imports for: %', v_problem;
    END IF;

    -- Applied once: an identity that is already present is skipped.
    INSERT INTO src_stock.stock_movement (
        movement_id, sku, location_code, movement_type, quantity, occurred_at, recorded_at,
        origin_system_code, origin_event_type, origin_event_id, origin_line_id)
    SELECT c.movement_id, c.sku, c.location_code, c.movement_type, c.quantity, c.occurred_at,
           p_processed_at, c.origin_system_code, c.origin_event_type, c.origin_event_id, c.origin_line_id
      FROM import_candidate AS c
    ON CONFLICT ON CONSTRAINT uq_stock_movement_origin DO NOTHING;

    DROP TABLE import_candidate;

    -- Imported reductions, and any local movements not yet processed, reach
    -- the central current balances once.
    CALL src_stock.apply_pending_movements(p_processed_at, false);
END;
$$;
COMMENT ON PROCEDURE src_stock.import_daily_transactions(timestamptz, timestamptz) IS
'1 am central import. Creates central movements for till sale lines and online collection/shipment lines that occurred before p_cutoff_at and were recorded by p_processed_at, keeping the original event identity; then applies all unapplied movements to current balances. recorded_at of an imported row is p_processed_at. Idempotent; raises an error for an untranslatable code or a conflicting earlier import.';
