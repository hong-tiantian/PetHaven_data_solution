-- =============================================================================
-- etl/validate_sources.sql
-- Purpose: Validate one run's raw extracts BEFORE staging: completeness,
--          approved product mappings, header/line completeness, order history
--          coherence and snapshot/copy metadata.
-- Prerequisites: raw.extract_sources committed for the run.
-- Inputs: p_load_run_id.
-- Outputs: audit.data_quality_issue rows; new approved barcode/SKU mappings in
--          ref.product_identifier taken from the validated central extract.
-- Execution: Called by scripts/run_pipeline.py before stg.prepare_staging, in
--            the same transaction.
-- Transaction: Caller-owned. Issues and mappings commit together with staging.
-- Rerun behaviour: Intended once per run; issues are recorded per run.
-- Failure behaviour: Findings are recorded as issues, not raised; any issue
--                    with severity error blocks publication of the whole run.
-- Business rules: Architecture_and_Data_Model.md 5.2, 6 and 12.1.
-- =============================================================================

CREATE PROCEDURE stg.validate_sources(p_load_run_id bigint)
LANGUAGE plpgsql
AS $$
DECLARE
    v_basis text := 'central product extract, load run ' || p_load_run_id;
BEGIN
    -- ---------------------------------------------------------------------
    -- 1. Completeness: every required table extracted, counts reconcile.
    -- ---------------------------------------------------------------------
    INSERT INTO audit.data_quality_issue (load_run_id, rule_code, severity, source_reference, message)
    SELECT p_load_run_id, 'incomplete_extract', 'error',
           t.system_code || '.' || t.source_table,
           CASE WHEN e.load_run_id IS NULL
                THEN 'Required source table was not extracted in this run'
                ELSE format('Extract status %s; source rows %s; raw rows %s',
                            e.status, e.source_row_count, e.raw_row_count)
           END
      FROM raw.source_tables() AS t
      LEFT JOIN audit.source_extract AS e
        ON e.load_run_id = p_load_run_id
       AND e.system_code = t.system_code
       AND e.table_name = t.source_table
     WHERE e.load_run_id IS NULL
        OR e.status <> 'succeeded'
        OR e.source_row_count IS DISTINCT FROM e.raw_row_count;

    -- ---------------------------------------------------------------------
    -- 2. Product mappings from the validated central product extract.
    --    An existing mapping is never silently redirected to another SKU.
    -- ---------------------------------------------------------------------
    INSERT INTO audit.data_quality_issue
        (load_run_id, rule_code, severity, raw_table_name, raw_record_id, source_reference, sku, message)
    SELECT p_load_run_id, 'mapping_conflict', 'error', 'raw.stock_product_barcode', b.raw_record_id,
           'store_sales:barcode:' || b.barcode, b.sku,
           format('Barcode %s is approved for SKU %s but central now links it to %s', b.barcode, m.sku, b.sku)
      FROM raw.stock_product_barcode AS b
      JOIN ref.product_identifier AS m
        ON m.system_code = 'store_sales' AND m.identifier_type = 'barcode' AND m.identifier_value = b.barcode
     WHERE b.load_run_id = p_load_run_id
       AND m.sku <> b.sku;

    INSERT INTO ref.product_identifier (system_code, identifier_type, identifier_value, sku, approved_at, mapping_basis)
    SELECT 'store_sales', 'barcode', b.barcode, b.sku, clock_timestamp(), v_basis
      FROM raw.stock_product_barcode AS b
     WHERE b.load_run_id = p_load_run_id
    ON CONFLICT DO NOTHING;

    -- SKU self-mappings are explicit for the online and central sources.
    INSERT INTO ref.product_identifier (system_code, identifier_type, identifier_value, sku, approved_at, mapping_basis)
    SELECT s.system_code, 'sku', p.sku, p.sku, clock_timestamp(), v_basis
      FROM raw.stock_product AS p
     CROSS JOIN (VALUES ('online'), ('stock')) AS s(system_code)
     WHERE p.load_run_id = p_load_run_id
    ON CONFLICT DO NOTHING;

    -- ---------------------------------------------------------------------
    -- 3. Location mappings must point at a central location in this extract.
    -- ---------------------------------------------------------------------
    INSERT INTO audit.data_quality_issue (load_run_id, rule_code, severity, source_reference, location_code, message)
    SELECT p_load_run_id, 'mapping_target_unknown', 'error',
           li.system_code || ':location:' || li.location_code, li.canonical_location_code,
           format('Approved mapping %s/%s points at %s, which is not a central location',
                  li.system_code, li.location_code, li.canonical_location_code)
      FROM ref.location_identifier AS li
     WHERE NOT EXISTS (
            SELECT 1 FROM raw.stock_location AS l
             WHERE l.load_run_id = p_load_run_id AND l.location_code = li.canonical_location_code);

    -- ---------------------------------------------------------------------
    -- 4. Header and line completeness.
    -- ---------------------------------------------------------------------
    INSERT INTO audit.data_quality_issue
        (load_run_id, rule_code, severity, raw_table_name, raw_record_id, source_reference, message)
    SELECT p_load_run_id, 'orphan_sale_line', 'error', 'raw.store_sales_sale_line', l.raw_record_id,
           'store_sales:sale:' || l.sale_id || ':' || l.line_id, 'Sale line has no sale header in this extract'
      FROM raw.store_sales_sale_line AS l
     WHERE l.load_run_id = p_load_run_id
       AND NOT EXISTS (SELECT 1 FROM raw.store_sales_sale AS s
                        WHERE s.load_run_id = p_load_run_id AND s.sale_id = l.sale_id)
    UNION ALL
    SELECT p_load_run_id, 'sale_without_lines', 'error', 'raw.store_sales_sale', s.raw_record_id,
           'store_sales:sale:' || s.sale_id, 'Completed sale has no lines in this extract'
      FROM raw.store_sales_sale AS s
     WHERE s.load_run_id = p_load_run_id
       AND NOT EXISTS (SELECT 1 FROM raw.store_sales_sale_line AS l
                        WHERE l.load_run_id = p_load_run_id AND l.sale_id = s.sale_id)
    UNION ALL
    SELECT p_load_run_id, 'orphan_order_line', 'error', 'raw.online_web_order_line', l.raw_record_id,
           'online:order:' || l.order_id || ':' || l.line_id, 'Order line has no order header in this extract'
      FROM raw.online_web_order_line AS l
     WHERE l.load_run_id = p_load_run_id
       AND NOT EXISTS (SELECT 1 FROM raw.online_web_order AS o
                        WHERE o.load_run_id = p_load_run_id AND o.order_id = l.order_id)
    UNION ALL
    SELECT p_load_run_id, 'order_without_lines', 'error', 'raw.online_web_order', o.raw_record_id,
           'online:order:' || o.order_id, 'Accepted order has no lines in this extract'
      FROM raw.online_web_order AS o
     WHERE o.load_run_id = p_load_run_id
       AND NOT EXISTS (SELECT 1 FROM raw.online_web_order_line AS l
                        WHERE l.load_run_id = p_load_run_id AND l.order_id = o.order_id)
    UNION ALL
    SELECT p_load_run_id, 'order_without_history', 'error', 'raw.online_web_order', o.raw_record_id,
           'online:order:' || o.order_id, 'Accepted order has no status history in this extract'
      FROM raw.online_web_order AS o
     WHERE o.load_run_id = p_load_run_id
       AND NOT EXISTS (SELECT 1 FROM raw.online_order_status_history AS h
                        WHERE h.load_run_id = p_load_run_id AND h.order_id = o.order_id)
    UNION ALL
    SELECT p_load_run_id, 'orphan_status_event', 'error', 'raw.online_order_status_history', h.raw_record_id,
           'online:status:' || h.event_id, 'Status event has no order header in this extract'
      FROM raw.online_order_status_history AS h
     WHERE h.load_run_id = p_load_run_id
       AND NOT EXISTS (SELECT 1 FROM raw.online_web_order AS o
                        WHERE o.load_run_id = p_load_run_id AND o.order_id = h.order_id)
    UNION ALL
    SELECT p_load_run_id, 'missing_transfer_line', 'error', 'raw.stock_stock_movement', m.raw_record_id,
           'stock:movement:' || m.movement_id || ':0', 'Transfer movement refers to a transfer line missing from this extract'
      FROM raw.stock_stock_movement AS m
     WHERE m.load_run_id = p_load_run_id
       AND m.transfer_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM raw.stock_stock_transfer_line AS t
                        WHERE t.load_run_id = p_load_run_id
                          AND t.transfer_id = m.transfer_id AND t.line_id = m.transfer_line_id);

    -- ---------------------------------------------------------------------
    -- 5. Order history coherence: sequences start at 1 without gaps, each
    --    event names the status it replaced, transitions are allowed, times
    --    do not go backwards, and the current row agrees with the history.
    -- ---------------------------------------------------------------------
    WITH history AS (
        SELECT h.*,
               o.fulfilment_type,
               row_number() OVER w AS expected_sequence,
               lag(h.new_status) OVER w AS prior_new_status,
               lag(h.occurred_at) OVER w AS prior_occurred_at
          FROM raw.online_order_status_history AS h
          JOIN raw.online_web_order AS o
            ON o.load_run_id = h.load_run_id AND o.order_id = h.order_id
         WHERE h.load_run_id = p_load_run_id
        WINDOW w AS (PARTITION BY h.order_id ORDER BY h.event_sequence)
    ),
    finding AS (
        SELECT h.raw_record_id, h.event_id,
               CASE
                   WHEN h.corrects_event_id IS NOT NULL THEN 'unsupported_correction'
                   WHEN h.event_sequence <> h.expected_sequence THEN 'status_sequence_gap'
                   WHEN h.previous_status IS DISTINCT FROM h.prior_new_status THEN 'status_previous_mismatch'
                   WHEN NOT (
                        (h.prior_new_status IS NULL AND h.new_status = 'awaiting_pick')
                        OR (h.prior_new_status = 'awaiting_pick' AND h.new_status IN ('ready', 'cancelled'))
                        OR (h.prior_new_status = 'ready' AND h.new_status = 'cancelled')
                        OR (h.prior_new_status = 'ready' AND h.new_status = 'collected' AND h.fulfilment_type = 'click_collect')
                        OR (h.prior_new_status = 'ready' AND h.new_status = 'shipped' AND h.fulfilment_type = 'home_delivery')
                   ) THEN 'invalid_status_transition'
                   WHEN h.occurred_at < h.prior_occurred_at THEN 'status_time_regression'
               END AS rule_code
          FROM history AS h
    )
    INSERT INTO audit.data_quality_issue
        (load_run_id, rule_code, severity, raw_table_name, raw_record_id, source_reference, message)
    SELECT p_load_run_id, f.rule_code, 'error', 'raw.online_order_status_history', f.raw_record_id,
           'online:status:' || f.event_id, 'Order status history is not coherent: ' || f.rule_code
      FROM finding AS f
     WHERE f.rule_code IS NOT NULL;

    WITH last_event AS (
        SELECT DISTINCT ON (h.order_id) h.order_id, h.new_status
          FROM raw.online_order_status_history AS h
         WHERE h.load_run_id = p_load_run_id
         ORDER BY h.order_id, h.event_sequence DESC
    ),
    first_event AS (
        SELECT h.order_id, h.occurred_at
          FROM raw.online_order_status_history AS h
         WHERE h.load_run_id = p_load_run_id AND h.event_sequence = 1
    )
    INSERT INTO audit.data_quality_issue
        (load_run_id, rule_code, severity, raw_table_name, raw_record_id, source_reference, message)
    SELECT p_load_run_id, 'current_status_mismatch', 'error', 'raw.online_web_order', o.raw_record_id,
           'online:order:' || o.order_id,
           format('Current status %s differs from the last history status %s', o.current_status, le.new_status)
      FROM raw.online_web_order AS o
      JOIN last_event AS le ON le.order_id = o.order_id
     WHERE o.load_run_id = p_load_run_id AND o.current_status IS DISTINCT FROM le.new_status
    UNION ALL
    SELECT p_load_run_id, 'placement_time_mismatch', 'error', 'raw.online_web_order', o.raw_record_id,
           'online:order:' || o.order_id, 'Order placed_at differs from its acceptance event time'
      FROM raw.online_web_order AS o
      JOIN first_event AS fe ON fe.order_id = o.order_id
     WHERE o.load_run_id = p_load_run_id AND o.placed_at IS DISTINCT FROM fe.occurred_at
    UNION ALL
    -- C&C must use a pickup store; home delivery must use the DC.
    SELECT p_load_run_id, 'fulfilment_location_mismatch', 'error', 'raw.online_web_order', o.raw_record_id,
           'online:order:' || o.order_id,
           format('%s order uses %s location %s', o.fulfilment_type, f.location_type, o.location_code)
      FROM raw.online_web_order AS o
      JOIN raw.online_fulfilment_location AS f
        ON f.load_run_id = o.load_run_id AND f.location_code = o.location_code
     WHERE o.load_run_id = p_load_run_id
       AND ((o.fulfilment_type = 'click_collect' AND f.location_type <> 'store')
         OR (o.fulfilment_type = 'home_delivery' AND f.location_type <> 'dc'));

    -- ---------------------------------------------------------------------
    -- 6. Snapshot and website-copy metadata must be consistent per ID.
    -- ---------------------------------------------------------------------
    INSERT INTO audit.data_quality_issue (load_run_id, rule_code, severity, source_reference, message)
    SELECT p_load_run_id, 'snapshot_metadata_inconsistent', 'error', 'stock:snapshot:' || s.snapshot_id,
           'Rows of one snapshot have different cutoff or creation times'
      FROM raw.stock_stock_snapshot AS s
     WHERE s.load_run_id = p_load_run_id
     GROUP BY s.snapshot_id
    HAVING count(DISTINCT s.cutoff_at) > 1 OR count(DISTINCT s.created_at) > 1
    UNION ALL
    SELECT p_load_run_id, 'copy_metadata_inconsistent', 'error', 'online:copy:' || c.copy_id,
           'Rows of one website refresh have different snapshot, cutoff or copy times'
      FROM raw.online_web_stock_copy AS c
     WHERE c.load_run_id = p_load_run_id
     GROUP BY c.copy_id
    HAVING count(DISTINCT c.source_snapshot_id) > 1
        OR count(DISTINCT c.snapshot_cutoff_at) > 1
        OR count(DISTINCT c.copied_at) > 1;
END;
$$;
COMMENT ON PROCEDURE stg.validate_sources(bigint) IS
'Validates one run''s raw extracts and records findings in audit.data_quality_issue: incomplete extracts, conflicting or unknown mapping targets, missing headers/lines, incoherent order history, current-status mismatches and inconsistent snapshot/copy metadata. Adds approved barcode and SKU mappings from the central product extract (never redirects an existing one). Runs in the caller''s transaction; records rather than raises.';
