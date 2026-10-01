-- =============================================================================
-- etl/prepare_staging.sql
-- Purpose: Build run-scoped staging from raw: match identifiers, gather every
--          representation of each physical event, keep one canonical event per
--          origin identity, and record matching, duplicate, publication-
--          conflict and late-record findings.
-- Prerequisites: stg.validate_sources has run for the same load run.
-- Inputs: p_load_run_id; ref mappings; already published dw facts.
-- Outputs: stg.* rows for the run; audit.data_quality_issue rows.
-- Execution: Called by scripts/run_pipeline.py right after
--            stg.validate_sources, in the same transaction.
-- Transaction: Caller-owned.
-- Rerun behaviour: Intended once per run (staging keys include load_run_id).
-- Failure behaviour: Findings are recorded as issues, not raised. Errors block
--                    publication of the whole run; warnings do not.
-- Business rules: Spec 5.2 and 5.4; Architecture_and_Data_Model.md 6, 8 and 10.5.
-- =============================================================================

CREATE PROCEDURE stg.prepare_staging(p_load_run_id bigint)
LANGUAGE plpgsql
AS $$
BEGIN
    -- ---------------------------------------------------------------------
    -- 1. Shared product and location attributes come from central stock.
    -- ---------------------------------------------------------------------
    INSERT INTO stg.product (load_run_id, sku, product_name, brand, category, pack_size, pack_unit, is_active, raw_record_id)
    SELECT p_load_run_id, p.sku, p.product_name, p.brand, p.category, p.pack_size, p.pack_unit, p.is_active, p.raw_record_id
      FROM raw.stock_product AS p
     WHERE p.load_run_id = p_load_run_id;

    INSERT INTO stg.location (load_run_id, location_code, location_name, location_type, suburb, raw_record_id)
    SELECT p_load_run_id, l.location_code, l.location_name, l.location_type, l.suburb, l.raw_record_id
      FROM raw.stock_location AS l
     WHERE l.load_run_id = p_load_run_id;

    -- ---------------------------------------------------------------------
    -- 2. Unmatched identifiers. Only identifiers used by transaction or
    --    balance records are checked: a barcode that sits in the till list
    --    but was never sold does not block a load. One issue per identifier.
    -- ---------------------------------------------------------------------
    WITH used_product AS (
        SELECT 'store_sales' AS system_code, 'barcode' AS identifier_type, l.barcode AS identifier_value,
               'raw.store_sales_sale_line' AS raw_table_name, l.raw_record_id
          FROM raw.store_sales_sale_line AS l WHERE l.load_run_id = p_load_run_id
        UNION ALL
        SELECT 'online', 'sku', l.sku, 'raw.online_web_order_line', l.raw_record_id
          FROM raw.online_web_order_line AS l WHERE l.load_run_id = p_load_run_id
        UNION ALL
        SELECT 'online', 'sku', c.sku, 'raw.online_web_stock_copy', c.raw_record_id
          FROM raw.online_web_stock_copy AS c WHERE c.load_run_id = p_load_run_id
        UNION ALL
        SELECT 'stock', 'sku', m.sku, 'raw.stock_stock_movement', m.raw_record_id
          FROM raw.stock_stock_movement AS m WHERE m.load_run_id = p_load_run_id
        UNION ALL
        SELECT 'stock', 'sku', s.sku, 'raw.stock_stock_snapshot', s.raw_record_id
          FROM raw.stock_stock_snapshot AS s WHERE s.load_run_id = p_load_run_id
    ),
    used_location AS (
        SELECT 'store_sales' AS system_code, s.store_code AS location_code,
               'raw.store_sales_sale' AS raw_table_name, s.raw_record_id
          FROM raw.store_sales_sale AS s WHERE s.load_run_id = p_load_run_id
        UNION ALL
        SELECT 'online', o.location_code, 'raw.online_web_order', o.raw_record_id
          FROM raw.online_web_order AS o WHERE o.load_run_id = p_load_run_id
        UNION ALL
        SELECT 'online', c.location_code, 'raw.online_web_stock_copy', c.raw_record_id
          FROM raw.online_web_stock_copy AS c WHERE c.load_run_id = p_load_run_id
        UNION ALL
        SELECT 'stock', m.location_code, 'raw.stock_stock_movement', m.raw_record_id
          FROM raw.stock_stock_movement AS m WHERE m.load_run_id = p_load_run_id
        UNION ALL
        SELECT 'stock', s.location_code, 'raw.stock_stock_snapshot', s.raw_record_id
          FROM raw.stock_stock_snapshot AS s WHERE s.load_run_id = p_load_run_id
    )
    INSERT INTO audit.data_quality_issue
        (load_run_id, rule_code, severity, raw_table_name, raw_record_id, source_reference, sku, location_code, message)
    SELECT p_load_run_id, 'unmatched_product', 'error',
           (array_agg(u.raw_table_name ORDER BY u.raw_table_name, u.raw_record_id))[1],
           (array_agg(u.raw_record_id ORDER BY u.raw_table_name, u.raw_record_id))[1],
           u.system_code || ':' || u.identifier_type || ':' || u.identifier_value, u.identifier_value, NULL,
           format('No approved product mapping for %s %s %s (%s record(s)); flagged for correction, not assigned to a default product',
                  u.system_code, u.identifier_type, u.identifier_value, count(*))
      FROM used_product AS u
     WHERE NOT EXISTS (
            SELECT 1 FROM ref.product_identifier AS m
             WHERE m.system_code = u.system_code
               AND m.identifier_type = u.identifier_type
               AND m.identifier_value = u.identifier_value)
     GROUP BY u.system_code, u.identifier_type, u.identifier_value
    UNION ALL
    SELECT p_load_run_id, 'unmatched_location', 'error',
           (array_agg(u.raw_table_name ORDER BY u.raw_table_name, u.raw_record_id))[1],
           (array_agg(u.raw_record_id ORDER BY u.raw_table_name, u.raw_record_id))[1],
           u.system_code || ':location:' || u.location_code, NULL, u.location_code,
           format('No approved location mapping for %s location %s (%s record(s)); flagged for correction, not assigned to a default store',
                  u.system_code, u.location_code, count(*))
      FROM used_location AS u
     WHERE NOT EXISTS (
            SELECT 1 FROM ref.location_identifier AS m
             WHERE m.system_code = u.system_code AND m.location_code = u.location_code)
     GROUP BY u.system_code, u.location_code;

    -- ---------------------------------------------------------------------
    -- 3. Every raw representation of a physical event line.
    -- ---------------------------------------------------------------------

    -- 3a. Completed till sale lines, read directly from the store sales
    --     source. This is how integration sees recent in-store sales before
    --     central's overnight import.
    INSERT INTO stg.stock_event_candidate (
        load_run_id, raw_table_name, raw_record_id,
        origin_system_code, origin_event_type, origin_event_id, origin_line_id,
        is_original_representation, sku, location_code, movement_type, quantity,
        occurred_at, source_recorded_at, support_raw_table_name, support_raw_record_id)
    SELECT p_load_run_id, 'raw.store_sales_sale_line', l.raw_record_id,
           'store_sales', 'sale', l.sale_id, l.line_id,
           true, pm.sku, lm.canonical_location_code, 'store_sale', -l.quantity,
           s.completed_at, s.recorded_at, 'raw.store_sales_sale', s.raw_record_id
      FROM raw.store_sales_sale_line AS l
      JOIN raw.store_sales_sale AS s
        ON s.load_run_id = l.load_run_id AND s.sale_id = l.sale_id
      LEFT JOIN ref.product_identifier AS pm
        ON pm.system_code = 'store_sales' AND pm.identifier_type = 'barcode' AND pm.identifier_value = l.barcode
      LEFT JOIN ref.location_identifier AS lm
        ON lm.system_code = 'store_sales' AND lm.location_code = s.store_code
     WHERE l.load_run_id = p_load_run_id;

    -- 3b. Online collections/shipments: one physical reduction per order line
    --     at the collected/shipped event time. Order placement, ready and
    --     cancellation create no physical event.
    INSERT INTO stg.stock_event_candidate (
        load_run_id, raw_table_name, raw_record_id,
        origin_system_code, origin_event_type, origin_event_id, origin_line_id,
        is_original_representation, sku, location_code, movement_type, quantity,
        occurred_at, source_recorded_at, order_id, order_line_id,
        support_raw_table_name, support_raw_record_id)
    SELECT p_load_run_id, 'raw.online_web_order_line', l.raw_record_id,
           'online',
           CASE h.new_status WHEN 'collected' THEN 'collection' ELSE 'shipment' END,
           h.event_id, l.line_id,
           true, pm.sku, lm.canonical_location_code,
           CASE h.new_status WHEN 'collected' THEN 'online_collection' ELSE 'online_shipment' END,
           -l.quantity, h.occurred_at, h.recorded_at, l.order_id, l.line_id,
           'raw.online_order_status_history', h.raw_record_id
      FROM raw.online_order_status_history AS h
      JOIN raw.online_web_order AS o
        ON o.load_run_id = h.load_run_id AND o.order_id = h.order_id
      JOIN raw.online_web_order_line AS l
        ON l.load_run_id = h.load_run_id AND l.order_id = h.order_id
      LEFT JOIN ref.product_identifier AS pm
        ON pm.system_code = 'online' AND pm.identifier_type = 'sku' AND pm.identifier_value = l.sku
      LEFT JOIN ref.location_identifier AS lm
        ON lm.system_code = 'online' AND lm.location_code = o.location_code
     WHERE h.load_run_id = p_load_run_id
       AND h.new_status IN ('collected', 'shipped');

    -- 3c. Central movements: local movements are original evidence; rows the
    --     1 am job imported are additional representations of a till sale or
    --     online collection that already has its own identity.
    INSERT INTO stg.stock_event_candidate (
        load_run_id, raw_table_name, raw_record_id,
        origin_system_code, origin_event_type, origin_event_id, origin_line_id,
        is_original_representation, sku, location_code, movement_type, quantity,
        occurred_at, source_recorded_at, transfer_id, transfer_line_id,
        delivery_reference, supplier_reference, reason_code,
        reverses_origin_system_code, reverses_origin_event_type, reverses_origin_event_id, reverses_origin_line_id)
    SELECT p_load_run_id, 'raw.stock_stock_movement', m.raw_record_id,
           m.origin_system_code, m.origin_event_type, m.origin_event_id, m.origin_line_id,
           (m.origin_system_code = 'stock'), pm.sku, lm.canonical_location_code, m.movement_type, m.quantity,
           m.occurred_at, m.recorded_at, m.transfer_id, m.transfer_line_id,
           m.delivery_reference, m.supplier_reference, m.reason_code,
           r.origin_system_code, r.origin_event_type, r.origin_event_id, r.origin_line_id
      FROM raw.stock_stock_movement AS m
      LEFT JOIN raw.stock_stock_movement AS r
        ON r.load_run_id = m.load_run_id AND r.movement_id = m.reverses_movement_id
      LEFT JOIN ref.product_identifier AS pm
        ON pm.system_code = 'stock' AND pm.identifier_type = 'sku' AND pm.identifier_value = m.sku
      LEFT JOIN ref.location_identifier AS lm
        ON lm.system_code = 'stock' AND lm.location_code = m.location_code
     WHERE m.load_run_id = p_load_run_id;

    -- ---------------------------------------------------------------------
    -- 4. Representations of one identity must agree on product, location,
    --    type, signed quantity and event time (Arch 8.2). Disagreement blocks
    --    publication and names every raw representation.
    -- ---------------------------------------------------------------------
    INSERT INTO audit.data_quality_issue
        (load_run_id, rule_code, severity, source_reference, sku, location_code, message)
    SELECT p_load_run_id, 'conflicting_duplicate', 'error',
           c.origin_system_code || ':' || c.origin_event_type || ':' || c.origin_event_id || ':' || c.origin_line_id,
           min(c.sku), min(c.location_code),
           'Representations disagree: ' || string_agg(
               format('%s#%s (sku %s, location %s, type %s, quantity %s, occurred %s)',
                      c.raw_table_name, c.raw_record_id, c.sku, c.location_code, c.movement_type,
                      c.quantity, c.occurred_at),
               '; ' ORDER BY c.raw_table_name, c.raw_record_id)
      FROM stg.stock_event_candidate AS c
     WHERE c.load_run_id = p_load_run_id
       AND c.sku IS NOT NULL AND c.location_code IS NOT NULL
     GROUP BY c.origin_system_code, c.origin_event_type, c.origin_event_id, c.origin_line_id
    HAVING count(DISTINCT (c.sku, c.location_code, c.movement_type, c.quantity, c.occurred_at)) > 1;

    -- An imported central copy without its original sale or collection is an
    -- extraction completeness problem: central is not silently used instead.
    INSERT INTO audit.data_quality_issue
        (load_run_id, rule_code, severity, raw_table_name, raw_record_id, source_reference, message)
    SELECT p_load_run_id, 'imported_without_original', 'error', 'raw.stock_stock_movement', min(c.raw_record_id),
           c.origin_system_code || ':' || c.origin_event_type || ':' || c.origin_event_id || ':' || c.origin_line_id,
           'Central imported this event but its original source record was not extracted'
      FROM stg.stock_event_candidate AS c
     WHERE c.load_run_id = p_load_run_id
     GROUP BY c.origin_system_code, c.origin_event_type, c.origin_event_id, c.origin_line_id
    HAVING NOT bool_or(c.is_original_representation);

    -- ---------------------------------------------------------------------
    -- 5. One canonical event per identity, taken from the original
    --    representation, for identities that are fully matched and agree.
    -- ---------------------------------------------------------------------
    INSERT INTO stg.stock_event (
        load_run_id, origin_system_code, origin_event_type, origin_event_id, origin_line_id,
        sku, location_code, movement_type, quantity, occurred_at, source_recorded_at,
        order_id, order_line_id, transfer_id, transfer_line_id, delivery_reference, supplier_reference,
        reason_code, reverses_origin_system_code, reverses_origin_event_type, reverses_origin_event_id,
        reverses_origin_line_id)
    SELECT DISTINCT ON (c.origin_system_code, c.origin_event_type, c.origin_event_id, c.origin_line_id)
           p_load_run_id, c.origin_system_code, c.origin_event_type, c.origin_event_id, c.origin_line_id,
           c.sku, c.location_code, c.movement_type, c.quantity, c.occurred_at, c.source_recorded_at,
           c.order_id, c.order_line_id, c.transfer_id, c.transfer_line_id, c.delivery_reference,
           c.supplier_reference, c.reason_code, c.reverses_origin_system_code, c.reverses_origin_event_type,
           c.reverses_origin_event_id, c.reverses_origin_line_id
      FROM stg.stock_event_candidate AS c
     WHERE c.load_run_id = p_load_run_id
       AND c.is_original_representation
       AND NOT EXISTS (
            SELECT 1 FROM stg.stock_event_candidate AS x
             WHERE x.load_run_id = p_load_run_id
               AND x.origin_system_code = c.origin_system_code
               AND x.origin_event_type = c.origin_event_type
               AND x.origin_event_id = c.origin_event_id
               AND x.origin_line_id = c.origin_line_id
               AND (x.sku IS NULL OR x.location_code IS NULL
                    OR (x.sku, x.location_code, x.movement_type, x.quantity, x.occurred_at)
                       IS DISTINCT FROM (c.sku, c.location_code, c.movement_type, c.quantity, c.occurred_at)))
     ORDER BY c.origin_system_code, c.origin_event_type, c.origin_event_id, c.origin_line_id, c.raw_table_name;

    -- ---------------------------------------------------------------------
    -- 6. Orders, status history, opening snapshots and website copies.
    -- ---------------------------------------------------------------------
    INSERT INTO stg.order_line (
        load_run_id, order_id, line_id, sku, location_code, quantity, placed_at,
        source_recorded_at, fulfilment_type, raw_record_id, header_raw_record_id)
    SELECT p_load_run_id, l.order_id, l.line_id, pm.sku, lm.canonical_location_code, l.quantity,
           o.placed_at, o.recorded_at, o.fulfilment_type, l.raw_record_id, o.raw_record_id
      FROM raw.online_web_order_line AS l
      JOIN raw.online_web_order AS o
        ON o.load_run_id = l.load_run_id AND o.order_id = l.order_id
      JOIN ref.product_identifier AS pm
        ON pm.system_code = 'online' AND pm.identifier_type = 'sku' AND pm.identifier_value = l.sku
      JOIN ref.location_identifier AS lm
        ON lm.system_code = 'online' AND lm.location_code = o.location_code
     WHERE l.load_run_id = p_load_run_id;

    INSERT INTO stg.order_status_event (
        load_run_id, event_id, order_id, event_sequence, previous_status, new_status,
        occurred_at, source_recorded_at, reason_code, corrects_event_id, raw_record_id)
    SELECT p_load_run_id, h.event_id, h.order_id, h.event_sequence, h.previous_status, h.new_status,
           h.occurred_at, h.recorded_at, h.reason_code, h.corrects_event_id, h.raw_record_id
      FROM raw.online_order_status_history AS h
     WHERE h.load_run_id = p_load_run_id
       AND EXISTS (SELECT 1 FROM raw.online_web_order AS o
                    WHERE o.load_run_id = p_load_run_id AND o.order_id = h.order_id);

    INSERT INTO stg.stock_snapshot (
        load_run_id, snapshot_id, sku, location_code, on_hand_quantity, cutoff_at, created_at, raw_record_id)
    SELECT p_load_run_id, s.snapshot_id, pm.sku, lm.canonical_location_code, s.on_hand_quantity,
           s.cutoff_at, s.created_at, s.raw_record_id
      FROM raw.stock_stock_snapshot AS s
      JOIN ref.product_identifier AS pm
        ON pm.system_code = 'stock' AND pm.identifier_type = 'sku' AND pm.identifier_value = s.sku
      JOIN ref.location_identifier AS lm
        ON lm.system_code = 'stock' AND lm.location_code = s.location_code
     WHERE s.load_run_id = p_load_run_id;

    INSERT INTO stg.web_stock_copy (
        load_run_id, copy_id, sku, location_code, on_hand_quantity, source_snapshot_id,
        snapshot_cutoff_at, copied_at, raw_record_id)
    SELECT p_load_run_id, c.copy_id, pm.sku, lm.canonical_location_code, c.on_hand_quantity,
           c.source_snapshot_id, c.snapshot_cutoff_at, c.copied_at, c.raw_record_id
      FROM raw.online_web_stock_copy AS c
      JOIN ref.product_identifier AS pm
        ON pm.system_code = 'online' AND pm.identifier_type = 'sku' AND pm.identifier_value = c.sku
      JOIN ref.location_identifier AS lm
        ON lm.system_code = 'online' AND lm.location_code = c.location_code
     WHERE c.load_run_id = p_load_run_id;

    -- ---------------------------------------------------------------------
    -- 7. Already published facts are never overwritten. A source record that
    --    now differs from its published fact is an error, not an update.
    -- ---------------------------------------------------------------------
    INSERT INTO audit.data_quality_issue (load_run_id, rule_code, severity, source_reference, sku, location_code, message)
    SELECT p_load_run_id, 'conflicts_with_published', 'error',
           e.origin_system_code || ':' || e.origin_event_type || ':' || e.origin_event_id || ':' || e.origin_line_id,
           e.sku, e.location_code, 'Physical event differs from its published warehouse fact'
      FROM stg.stock_event AS e
      JOIN dw.fact_stock_movement AS f
        ON f.origin_system_code = e.origin_system_code AND f.origin_event_type = e.origin_event_type
       AND f.origin_event_id = e.origin_event_id AND f.origin_line_id = e.origin_line_id
      JOIN dw.dim_product AS p ON p.product_key = f.product_key
      JOIN dw.dim_location AS l ON l.location_key = f.location_key
     WHERE e.load_run_id = p_load_run_id
       AND (p.sku, l.location_code, f.movement_type, f.quantity, f.occurred_at)
           IS DISTINCT FROM (e.sku, e.location_code, e.movement_type, e.quantity, e.occurred_at)
    UNION ALL
    SELECT p_load_run_id, 'conflicts_with_published', 'error', 'online:order:' || s.order_id || ':' || s.line_id,
           s.sku, s.location_code, 'Order line differs from its published warehouse fact'
      FROM stg.order_line AS s
      JOIN dw.fact_order_line AS f ON f.order_id = s.order_id AND f.line_id = s.line_id
      JOIN dw.dim_product AS p ON p.product_key = f.product_key
      JOIN dw.dim_location AS l ON l.location_key = f.location_key
     WHERE s.load_run_id = p_load_run_id
       AND (p.sku, l.location_code, f.quantity, f.placed_at, f.fulfilment_type)
           IS DISTINCT FROM (s.sku, s.location_code, s.quantity, s.placed_at, s.fulfilment_type)
    UNION ALL
    SELECT p_load_run_id, 'conflicts_with_published', 'error', 'online:status:' || s.event_id, NULL, NULL,
           'Order status event differs from its published warehouse fact'
      FROM stg.order_status_event AS s
      JOIN dw.fact_order_status_event AS f ON f.event_id = s.event_id
     WHERE s.load_run_id = p_load_run_id
       AND (f.order_id, f.event_sequence, f.previous_status, f.new_status, f.occurred_at, f.reason_code)
           IS DISTINCT FROM (s.order_id, s.event_sequence, s.previous_status, s.new_status, s.occurred_at, s.reason_code)
    UNION ALL
    SELECT p_load_run_id, 'conflicts_with_published', 'error', 'stock:snapshot:' || s.snapshot_id,
           s.sku, s.location_code, 'Snapshot balance differs from its published warehouse fact'
      FROM stg.stock_snapshot AS s
      JOIN dw.dim_product AS p ON p.sku = s.sku
      JOIN dw.dim_location AS l ON l.location_code = s.location_code
      JOIN dw.fact_stock_snapshot AS f
        ON f.snapshot_id = s.snapshot_id AND f.product_key = p.product_key AND f.location_key = l.location_key
     WHERE s.load_run_id = p_load_run_id
       AND (f.on_hand_quantity, f.cutoff_at, f.created_at) IS DISTINCT FROM (s.on_hand_quantity, s.cutoff_at, s.created_at)
    UNION ALL
    SELECT p_load_run_id, 'conflicts_with_published', 'error', 'online:copy:' || s.copy_id,
           s.sku, s.location_code, 'Website copy balance differs from its published warehouse fact'
      FROM stg.web_stock_copy AS s
      JOIN dw.dim_product AS p ON p.sku = s.sku
      JOIN dw.dim_location AS l ON l.location_code = s.location_code
      JOIN dw.fact_web_stock_copy AS f
        ON f.copy_id = s.copy_id AND f.product_key = p.product_key AND f.location_key = l.location_key
     WHERE s.load_run_id = p_load_run_id
       AND (f.on_hand_quantity, f.source_snapshot_id, f.snapshot_cutoff_at, f.copied_at)
           IS DISTINCT FROM (s.on_hand_quantity, s.source_snapshot_id, s.snapshot_cutoff_at, s.copied_at)
    UNION ALL
    -- Dimension attributes are fixed during the scenarios (no SCD history).
    SELECT p_load_run_id, 'conflicts_with_published', 'error', 'stock:product:' || s.sku, s.sku, NULL,
           'Product attributes differ from the published product dimension'
      FROM stg.product AS s
      JOIN dw.dim_product AS d ON d.sku = s.sku
     WHERE s.load_run_id = p_load_run_id
       AND (d.product_name, d.brand, d.category, d.pack_size, d.pack_unit, d.is_active)
           IS DISTINCT FROM (s.product_name, s.brand, s.category, s.pack_size, s.pack_unit, s.is_active)
    UNION ALL
    SELECT p_load_run_id, 'conflicts_with_published', 'error', 'stock:location:' || s.location_code, NULL, s.location_code,
           'Location attributes differ from the published location dimension'
      FROM stg.location AS s
      JOIN dw.dim_location AS d ON d.location_code = s.location_code
     WHERE s.load_run_id = p_load_run_id
       AND (d.location_name, d.location_type, d.suburb) IS DISTINCT FROM (s.location_name, s.location_type, s.suburb);

    -- A reversal must point at an event that is staged now or already published.
    INSERT INTO audit.data_quality_issue (load_run_id, rule_code, severity, source_reference, message)
    SELECT p_load_run_id, 'reversal_target_missing', 'error',
           e.origin_system_code || ':' || e.origin_event_type || ':' || e.origin_event_id || ':' || e.origin_line_id,
           'Reversal refers to a movement that is neither staged nor published'
      FROM stg.stock_event AS e
     WHERE e.load_run_id = p_load_run_id
       AND e.movement_type = 'reversal'
       AND NOT EXISTS (
            SELECT 1 FROM stg.stock_event AS t
             WHERE t.load_run_id = p_load_run_id
               AND t.origin_system_code = e.reverses_origin_system_code
               AND t.origin_event_type = e.reverses_origin_event_type
               AND t.origin_event_id = e.reverses_origin_event_id
               AND t.origin_line_id = e.reverses_origin_line_id)
       AND NOT EXISTS (
            SELECT 1 FROM dw.fact_stock_movement AS f
             WHERE f.origin_system_code = e.reverses_origin_system_code
               AND f.origin_event_type = e.reverses_origin_event_type
               AND f.origin_event_id = e.reverses_origin_event_id
               AND f.origin_line_id = e.reverses_origin_line_id);

    -- ---------------------------------------------------------------------
    -- 8. Pre-cutoff late record (Arch 10.5): an event before a snapshot's
    --    cutoff that its source recorded only after the snapshot was created
    --    cannot be inside that snapshot. It is a warning so that the load can
    --    still publish; rpt.calculate_inventory marks the affected pair
    --    reconciliation_required and gives no stock quantity for it.
    -- ---------------------------------------------------------------------
    INSERT INTO audit.data_quality_issue
        (load_run_id, rule_code, severity, source_reference, sku, location_code, message)
    SELECT DISTINCT ON (e.origin_system_code, e.origin_event_type, e.origin_event_id, e.origin_line_id)
           p_load_run_id, 'pre_cutoff_late_event', 'warning',
           e.origin_system_code || ':' || e.origin_event_type || ':' || e.origin_event_id || ':' || e.origin_line_id,
           e.sku, e.location_code,
           format('Event at %s was recorded at %s, after snapshot %s (cutoff %s) was created at %s; it is not in that snapshot and must be reconciled',
                  e.occurred_at, e.source_recorded_at, s.snapshot_id, s.cutoff_at, s.created_at)
      FROM stg.stock_event AS e
      JOIN stg.stock_snapshot AS s
        ON s.load_run_id = e.load_run_id
       AND s.sku = e.sku
       AND s.location_code = e.location_code
       AND e.occurred_at < s.cutoff_at
       AND e.source_recorded_at > s.created_at
     WHERE e.load_run_id = p_load_run_id
     ORDER BY e.origin_system_code, e.origin_event_type, e.origin_event_id, e.origin_line_id, s.cutoff_at;
END;
$$;
COMMENT ON PROCEDURE stg.prepare_staging(bigint) IS
'Builds staging for one load run: matched products/locations, all representations of each physical event (till sale lines, online collection lines, central movements), one canonical event per agreeing and fully matched identity, order lines and history, snapshots and website copies. Records unmatched identifiers, conflicting duplicates, imported-without-original, conflicts with published facts, missing reversal targets (errors) and pre-cutoff late events (warnings). Runs in the caller''s transaction; records rather than raises.';
