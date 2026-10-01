-- =============================================================================
-- source_actions/online_actions.sql
-- Purpose: Business logic of the existing online store: its own (outdated)
--          availability calculation, order acceptance and status changes.
-- Prerequisites: 02_source_tables.sql.
-- Inputs: Procedure arguments supplied by scenario files (db/seed/*.sql).
-- Outputs: src_online.web_order, web_order_line and order_status_history rows.
-- Execution: Created by scripts/apply_schema.py; called by scenario steps.
-- Transaction: Each procedure runs in the caller's transaction, so the current
--              order row and its history event are written together.
-- Rerun behaviour: A repeated order or event ID fails on its primary key.
-- Business rules: Spec 4.2 and 5.3; Architecture_and_Data_Model.md 4.2.
--
-- This file models the EXISTING website, including its weakness: it only
-- knows its 5 am copy of the midnight snapshot plus its own online activity.
-- It does not see till sales, receipts, transfers or adjustments made after
-- that snapshot's cutoff. This is how the baseline scenario accepts Sarah's
-- order although the last bag is already promised to Customer A.
-- =============================================================================

CREATE FUNCTION src_online.website_available_quantity(
    p_sku            text,
    p_location_code  text,
    p_at             timestamptz
)
RETURNS bigint
LANGUAGE sql
STABLE
AS $$
    WITH latest_refresh AS (
        -- The website uses its most recent refresh only.
        SELECT c.copy_id, c.snapshot_cutoff_at
          FROM src_online.web_stock_copy AS c
         WHERE c.copied_at <= p_at
         ORDER BY c.copied_at DESC, c.copy_id DESC
         LIMIT 1
    ),
    copied AS (
        SELECT c.on_hand_quantity
          FROM src_online.web_stock_copy AS c
          JOIN latest_refresh AS r ON r.copy_id = c.copy_id
         WHERE c.sku = p_sku AND c.location_code = p_location_code
    ),
    -- Status of every order at p_at, from its own history.
    order_state AS (
        SELECT DISTINCT ON (h.order_id) h.order_id, h.new_status
          FROM src_online.order_status_history AS h
         WHERE h.occurred_at <= p_at
         ORDER BY h.order_id, h.occurred_at DESC, h.event_sequence DESC
    ),
    reserved AS (
        SELECT coalesce(sum(l.quantity), 0) AS quantity
          FROM src_online.web_order AS o
          JOIN src_online.web_order_line AS l ON l.order_id = o.order_id
          JOIN order_state AS s ON s.order_id = o.order_id
         WHERE o.location_code = p_location_code
           AND l.sku = p_sku
           AND s.new_status IN ('awaiting_pick', 'ready')
    ),
    -- Its own physical fulfilments since the copied cutoff, including any
    -- between midnight and the 5 am copy.
    fulfilled AS (
        SELECT coalesce(sum(l.quantity), 0) AS quantity
          FROM src_online.order_status_history AS h
          JOIN src_online.web_order AS o ON o.order_id = h.order_id
          JOIN src_online.web_order_line AS l ON l.order_id = h.order_id
         WHERE h.new_status IN ('collected', 'shipped')
           AND o.location_code = p_location_code
           AND l.sku = p_sku
           AND h.occurred_at >= (SELECT snapshot_cutoff_at FROM latest_refresh)
           AND h.occurred_at <= p_at
    )
    -- With no copied balance the product page shows "Out of stock".
    SELECT greatest(coalesce((SELECT on_hand_quantity FROM copied), 0)
                    - (SELECT quantity FROM fulfilled)
                    - (SELECT quantity FROM reserved), 0)::bigint;
$$;
COMMENT ON FUNCTION src_online.website_available_quantity(text, text, timestamptz) IS
'The existing website''s own availability for one SKU at one online location code at p_at (Spec 5.3): copied midnight balance minus its online collections/shipments since that cutoff minus its active reservations, floored at zero. Treats a missing copy as zero (out of stock). No side effects.';

CREATE PROCEDURE src_online.place_order(
    p_order_id         text,
    p_event_id         text,
    p_placed_at        timestamptz,
    p_fulfilment_type  text,
    p_location_code    text,
    p_lines            jsonb,
    p_recorded_at      timestamptz DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_location_type text;
    v_line          record;
    v_available     bigint;
BEGIN
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Order % needs at least one line', p_order_id;
    END IF;

    SELECT f.location_type INTO v_location_type
      FROM src_online.fulfilment_location AS f
     WHERE f.location_code = p_location_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown fulfilment location %', p_location_code;
    END IF;
    -- C&C is collected from a store; home delivery is sent from the DC.
    IF (p_fulfilment_type = 'click_collect' AND v_location_type <> 'store')
       OR (p_fulfilment_type = 'home_delivery' AND v_location_type <> 'dc') THEN
        RAISE EXCEPTION 'Fulfilment type % cannot use % location %',
            p_fulfilment_type, v_location_type, p_location_code;
    END IF;

    -- The website accepts the order only if ITS OWN calculation shows enough
    -- stock for every line (Spec 4.2 steps 2-3). Its calculation can be wrong.
    FOR v_line IN
        SELECT l.line_id, l.sku, l.quantity
          FROM jsonb_to_recordset(p_lines) AS l(line_id text, sku text, quantity integer)
    LOOP
        v_available := src_online.website_available_quantity(v_line.sku, p_location_code, p_placed_at);
        IF v_available < v_line.quantity THEN
            RAISE EXCEPTION 'Website availability check rejected order %: SKU % at % shows % available, % requested',
                p_order_id, v_line.sku, p_location_code, v_available, v_line.quantity;
        END IF;
    END LOOP;

    INSERT INTO src_online.web_order
        (order_id, placed_at, recorded_at, fulfilment_type, location_code, current_status, updated_at)
    VALUES
        (p_order_id, p_placed_at, coalesce(p_recorded_at, p_placed_at), p_fulfilment_type,
         p_location_code, 'awaiting_pick', coalesce(p_recorded_at, p_placed_at));

    INSERT INTO src_online.web_order_line (order_id, line_id, sku, quantity)
    SELECT p_order_id, l.line_id, l.sku, l.quantity
      FROM jsonb_to_recordset(p_lines) AS l(line_id text, sku text, quantity integer);

    -- Acceptance is the first history event; the reservation starts now,
    -- before any goods are physically set aside.
    INSERT INTO src_online.order_status_history
        (event_id, order_id, event_sequence, previous_status, new_status, occurred_at, recorded_at)
    VALUES
        (p_event_id, p_order_id, 1, NULL, 'awaiting_pick', p_placed_at, coalesce(p_recorded_at, p_placed_at));
END;
$$;
COMMENT ON PROCEDURE src_online.place_order(text, text, timestamptz, text, text, jsonb, timestamptz) IS
'Accepts one online order if the website''s own availability calculation covers every line. p_lines is a JSON array of {"line_id","sku","quantity"}. Writes the order (status awaiting_pick), its lines and the first history event in the caller''s transaction. Raises an error, writing nothing, when the website calculation is insufficient, the location does not suit the fulfilment type, or the order has no lines. Creates no physical movement.';

CREATE PROCEDURE src_online.change_order_status(
    p_event_id     text,
    p_order_id     text,
    p_new_status   text,
    p_occurred_at  timestamptz,
    p_reason_code  text DEFAULT NULL,
    p_recorded_at  timestamptz DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_order          src_online.web_order%ROWTYPE;
    v_last_sequence  integer;
    v_last_occurred  timestamptz;
BEGIN
    -- Lock the order so the current row and the history stay consistent.
    SELECT * INTO v_order FROM src_online.web_order WHERE order_id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown order %', p_order_id;
    END IF;

    -- collected, shipped and cancelled are terminal. Reopening or rewriting a
    -- completed order would be a history correction, which this prototype
    -- does not implement; reject it visibly (Arch 10.5).
    IF v_order.current_status IN ('collected', 'shipped', 'cancelled') THEN
        RAISE EXCEPTION 'Order % is % (terminal); order-status corrections are not implemented in this prototype',
            p_order_id, v_order.current_status;
    END IF;

    IF NOT (
        (v_order.current_status = 'awaiting_pick' AND p_new_status IN ('ready', 'cancelled'))
        OR (v_order.current_status = 'ready' AND p_new_status = 'cancelled')
        OR (v_order.current_status = 'ready' AND p_new_status = 'collected' AND v_order.fulfilment_type = 'click_collect')
        OR (v_order.current_status = 'ready' AND p_new_status = 'shipped' AND v_order.fulfilment_type = 'home_delivery')
    ) THEN
        RAISE EXCEPTION 'Transition % -> % is not allowed for % order %',
            v_order.current_status, p_new_status, v_order.fulfilment_type, p_order_id;
    END IF;

    IF p_new_status = 'cancelled' AND p_reason_code IS NULL THEN
        RAISE EXCEPTION 'Cancelling order % requires a reason code', p_order_id;
    END IF;

    SELECT max(event_sequence), max(occurred_at) INTO v_last_sequence, v_last_occurred
      FROM src_online.order_status_history WHERE order_id = p_order_id;
    -- Business times must not go backwards within one order's history.
    IF p_occurred_at < v_last_occurred THEN
        RAISE EXCEPTION 'Event % for order % occurs at %, before the previous event at %',
            p_event_id, p_order_id, p_occurred_at, v_last_occurred;
    END IF;

    INSERT INTO src_online.order_status_history
        (event_id, order_id, event_sequence, previous_status, new_status, occurred_at, recorded_at, reason_code)
    VALUES
        (p_event_id, p_order_id, v_last_sequence + 1, v_order.current_status, p_new_status,
         p_occurred_at, coalesce(p_recorded_at, p_occurred_at), p_reason_code);

    UPDATE src_online.web_order
       SET current_status = p_new_status,
           updated_at = coalesce(p_recorded_at, p_occurred_at)
     WHERE order_id = p_order_id;
END;
$$;
COMMENT ON PROCEDURE src_online.change_order_status(text, text, text, timestamptz, text, timestamptz) IS
'Staff marks an order ready, collected (C&C), shipped (home delivery) or cancelled (with a reason). Appends a history event and updates the current status in the caller''s transaction. Raises an error for an invalid transition, a missing cancellation reason, an earlier business time, or any change to a terminal order (corrections are rejected visibly). Physical stock effects of a collection are recorded by central only at its 1 am import.';
