-- =============================================================================
-- source_jobs/create_midnight_snapshot.sql
-- Purpose: Simulate central stock producing the fixed, reconciled snapshot
--          for a midnight cutoff (part of the 1 am processing).
-- Prerequisites: 02_source_tables.sql; the previous snapshot exists.
-- Inputs: p_snapshot_id, p_cutoff_at (midnight), p_previous_snapshot_id,
--         p_created_at (the 1 am processing time).
-- Outputs: New immutable src_stock.stock_snapshot rows.
-- Execution: Called by scenario steps right after the 1 am import.
-- Transaction: All snapshot rows are written in the caller's transaction.
-- Rerun behaviour: Not repeatable for the same snapshot ID (immutable history);
--                  a second call raises an error.
-- Business rules: Spec 3.2 and 4.3 activity D; Architecture_and_Data_Model.md 11.2.
--
-- The snapshot is built as: previous reconciled snapshot + every central
-- movement with previous cutoff <= occurred_at < this cutoff that central had
-- recorded by p_created_at. It is NOT a copy of stock_on_hand: the current
-- balance may already contain movements after midnight.
-- =============================================================================

CREATE PROCEDURE src_stock.create_midnight_snapshot(
    p_snapshot_id           text,
    p_cutoff_at             timestamptz,
    p_previous_snapshot_id  text,
    p_created_at            timestamptz
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_previous_cutoff timestamptz;
    v_missing         text;
BEGIN
    IF EXISTS (SELECT 1 FROM src_stock.stock_snapshot WHERE snapshot_id = p_snapshot_id) THEN
        RAISE EXCEPTION 'Snapshot % already exists; snapshots are immutable', p_snapshot_id;
    END IF;

    SELECT max(cutoff_at) INTO v_previous_cutoff
      FROM src_stock.stock_snapshot WHERE snapshot_id = p_previous_snapshot_id;
    IF v_previous_cutoff IS NULL THEN
        RAISE EXCEPTION 'Previous snapshot % does not exist', p_previous_snapshot_id;
    END IF;
    IF v_previous_cutoff >= p_cutoff_at THEN
        RAISE EXCEPTION 'Previous snapshot cutoff % is not before %', v_previous_cutoff, p_cutoff_at;
    END IF;

    -- Consistency check: every till sale line and online collection/shipment
    -- in the interval that was already recorded must have reached central.
    -- Events recorded after p_created_at genuinely cannot be included; the
    -- integration layer reports them as reconciliation issues.
    SELECT string_agg(e.identity, ', ') INTO v_missing
      FROM (
        SELECT 'store_sales:sale:' || s.sale_id || ':' || l.line_id AS identity,
               'store_sales' AS sys, 'sale' AS typ, s.sale_id AS eid, l.line_id AS lid
          FROM src_store_sales.sale AS s
          JOIN src_store_sales.sale_line AS l ON l.sale_id = s.sale_id
         WHERE s.completed_at >= v_previous_cutoff AND s.completed_at < p_cutoff_at
           AND s.recorded_at <= p_created_at
        UNION ALL
        SELECT 'online:' || CASE h.new_status WHEN 'collected' THEN 'collection' ELSE 'shipment' END
                   || ':' || h.event_id || ':' || l.line_id,
               'online', CASE h.new_status WHEN 'collected' THEN 'collection' ELSE 'shipment' END,
               h.event_id, l.line_id
          FROM src_online.order_status_history AS h
          JOIN src_online.web_order_line AS l ON l.order_id = h.order_id
         WHERE h.new_status IN ('collected', 'shipped')
           AND h.occurred_at >= v_previous_cutoff AND h.occurred_at < p_cutoff_at
           AND h.recorded_at <= p_created_at
      ) AS e
     WHERE NOT EXISTS (
        SELECT 1 FROM src_stock.stock_movement AS m
         WHERE m.origin_system_code = e.sys AND m.origin_event_type = e.typ
           AND m.origin_event_id = e.eid AND m.origin_line_id = e.lid);
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'Snapshot % would miss events not yet imported: %', p_snapshot_id, v_missing;
    END IF;

    INSERT INTO src_stock.stock_snapshot (snapshot_id, sku, location_code, on_hand_quantity, cutoff_at, created_at)
    WITH previous AS (
        SELECT sku, location_code, on_hand_quantity
          FROM src_stock.stock_snapshot
         WHERE snapshot_id = p_previous_snapshot_id
    ),
    -- Strictly before the cutoff: an event exactly at midnight belongs to the
    -- following day.
    interval_movement AS (
        SELECT sku, location_code, sum(quantity) AS quantity
          FROM src_stock.stock_movement
         WHERE occurred_at >= v_previous_cutoff
           AND occurred_at < p_cutoff_at
           AND recorded_at <= p_created_at
         GROUP BY sku, location_code
    )
    SELECT p_snapshot_id,
           coalesce(p.sku, m.sku),
           coalesce(p.location_code, m.location_code),
           coalesce(p.on_hand_quantity, 0) + coalesce(m.quantity, 0),
           p_cutoff_at,
           p_created_at
      FROM previous AS p
      FULL JOIN interval_movement AS m USING (sku, location_code);
END;
$$;
COMMENT ON PROCEDURE src_stock.create_midnight_snapshot(text, timestamptz, text, timestamptz) IS
'Creates immutable snapshot p_snapshot_id at p_cutoff_at from the previous reconciled snapshot plus movements in [previous cutoff, p_cutoff_at) recorded by p_created_at. A product/location first seen through a movement starts from zero only because it had no stock before; pairs with no evidence are not invented. Raises an error if the snapshot exists, the previous one is missing, or already-recorded sales/collections in the interval were not imported.';
