-- =============================================================================
-- source_actions/stock_actions.sql
-- Purpose: Business write procedures of the central stock source: opening
--          bootstrap, supplier receipt, transfer create/dispatch/receive,
--          count adjustment and reversal.
-- Prerequisites: 02_source_tables.sql.
-- Inputs: Procedure arguments supplied by scenario files (db/seed/*.sql).
-- Outputs: src_stock rows; every physical action creates stock_movement rows.
-- Execution: Created by scripts/apply_schema.py; called by scenario steps.
-- Transaction: Each procedure runs in the caller's transaction. A multi-line
--              dispatch or receipt writes all its line movements and the new
--              transfer status together.
-- Rerun behaviour: Repeated movement or transfer IDs fail on primary keys;
--                  a transfer cannot be dispatched or received twice.
-- Business rules: Spec 4.3; Architecture_and_Data_Model.md 4.3 and 10.5.
--
-- Movements are recorded when staff CONFIRMS the physical action. The central
-- current balance (stock_on_hand) is NOT updated here: the hourly job
-- (source_jobs/apply_local_movements.sql) applies these movements later.
-- =============================================================================

CREATE SEQUENCE src_stock.movement_number;
COMMENT ON SEQUENCE src_stock.movement_number IS
'Numbers generated movement IDs (MV-000001, ...) when a scenario does not supply its own ID.';

CREATE FUNCTION src_stock.next_movement_id()
RETURNS text
LANGUAGE sql
VOLATILE
AS $$
    SELECT 'MV-' || lpad(nextval('src_stock.movement_number')::text, 6, '0');
$$;
COMMENT ON FUNCTION src_stock.next_movement_id() IS
'Returns a new central movement ID. Side effect: advances src_stock.movement_number.';

CREATE PROCEDURE src_stock.bootstrap_opening_snapshot(
    p_snapshot_id  text,
    p_cutoff_at    timestamptz,
    p_created_at   timestamptz,
    p_balances     jsonb
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Only the very first fixture balance may be loaded this way; every later
    -- snapshot must be produced by create_midnight_snapshot (Arch 11.2).
    IF EXISTS (SELECT 1 FROM src_stock.stock_snapshot) OR EXISTS (SELECT 1 FROM src_stock.stock_on_hand) THEN
        RAISE EXCEPTION 'Central stock already has balances; bootstrap is only for an empty fixture';
    END IF;

    INSERT INTO src_stock.stock_snapshot (snapshot_id, sku, location_code, on_hand_quantity, cutoff_at, created_at)
    SELECT p_snapshot_id, b.sku, b.location_code, b.quantity, p_cutoff_at, p_created_at
      FROM jsonb_to_recordset(p_balances) AS b(sku text, location_code text, quantity integer);

    -- Starting current balances match the reconciled opening snapshot.
    INSERT INTO src_stock.stock_on_hand (sku, location_code, on_hand_quantity, updated_at)
    SELECT b.sku, b.location_code, b.quantity, p_created_at
      FROM jsonb_to_recordset(p_balances) AS b(sku text, location_code text, quantity integer);
END;
$$;
COMMENT ON PROCEDURE src_stock.bootstrap_opening_snapshot(text, timestamptz, timestamptz, jsonb) IS
'Fixture setup: loads an explicit, known reconciled opening snapshot and matching starting current balances. p_balances is a JSON array of {"sku","location_code","quantity"}; include known zero balances as explicit rows. Raises an error unless central stock has no balances yet.';

CREATE PROCEDURE src_stock.record_supplier_receipt(
    p_sku                 text,
    p_location_code       text,
    p_quantity            integer,
    p_occurred_at         timestamptz,
    p_delivery_reference  text,
    p_supplier_reference  text,
    p_recorded_at         timestamptz DEFAULT NULL,
    p_movement_id         text DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_movement_id text := coalesce(p_movement_id, src_stock.next_movement_id());
BEGIN
    -- Supplier deliveries are received at the DC (Spec 1).
    IF NOT EXISTS (SELECT 1 FROM src_stock.location WHERE location_code = p_location_code AND location_type = 'dc') THEN
        RAISE EXCEPTION 'Supplier receipts are recorded at the DC, not at %', p_location_code;
    END IF;

    -- Quantity is what staff counted and confirmed, not the purchase order.
    INSERT INTO src_stock.stock_movement (
        movement_id, sku, location_code, movement_type, quantity, occurred_at, recorded_at,
        origin_system_code, origin_event_type, origin_event_id, origin_line_id,
        delivery_reference, supplier_reference)
    VALUES (
        v_movement_id, p_sku, p_location_code, 'supplier_receipt', p_quantity, p_occurred_at,
        coalesce(p_recorded_at, p_occurred_at),
        'stock', 'movement', v_movement_id, '0',
        p_delivery_reference, p_supplier_reference);
END;
$$;
COMMENT ON PROCEDURE src_stock.record_supplier_receipt(text, text, integer, timestamptz, text, text, timestamptz, text) IS
'Records a confirmed supplier delivery at the DC as a positive supplier_receipt movement with delivery and supplier references. Raises an error for a non-DC location or a non-positive quantity. Central current balance changes only at the next hourly run.';

CREATE PROCEDURE src_stock.create_transfer(
    p_transfer_id   text,
    p_origin        text,
    p_destination   text,
    p_created_at    timestamptz,
    p_lines         jsonb
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Transfer % needs at least one line', p_transfer_id;
    END IF;

    INSERT INTO src_stock.stock_transfer
        (transfer_id, origin_location_code, destination_location_code, created_at, current_status)
    VALUES (p_transfer_id, p_origin, p_destination, p_created_at, 'created');

    INSERT INTO src_stock.stock_transfer_line (transfer_id, line_id, sku, quantity)
    SELECT p_transfer_id, l.line_id, l.sku, l.quantity
      FROM jsonb_to_recordset(p_lines) AS l(line_id text, sku text, quantity integer);
    -- Creating a transfer moves no stock: no movement is written here.
END;
$$;
COMMENT ON PROCEDURE src_stock.create_transfer(text, text, text, timestamptz, jsonb) IS
'Plans a transfer between two locations. p_lines is a JSON array of {"line_id","sku","quantity"}. Writes the header (status created) and lines only; creates no physical movement.';

CREATE PROCEDURE src_stock.dispatch_transfer(
    p_transfer_id  text,
    p_occurred_at  timestamptz,
    p_recorded_at  timestamptz DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_transfer src_stock.stock_transfer%ROWTYPE;
BEGIN
    SELECT * INTO v_transfer FROM src_stock.stock_transfer WHERE transfer_id = p_transfer_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown transfer %', p_transfer_id;
    END IF;
    IF v_transfer.current_status <> 'created' THEN
        RAISE EXCEPTION 'Transfer % is % and cannot be dispatched', p_transfer_id, v_transfer.current_status;
    END IF;

    -- One reduction at the origin per line. Goods are now in transit and are
    -- not stock at either location.
    INSERT INTO src_stock.stock_movement (
        movement_id, sku, location_code, movement_type, quantity, occurred_at, recorded_at,
        origin_system_code, origin_event_type, origin_event_id, origin_line_id,
        transfer_id, transfer_line_id)
    SELECT p_transfer_id || '-DSP-' || l.line_id, l.sku, v_transfer.origin_location_code,
           'transfer_dispatch', -l.quantity, p_occurred_at, coalesce(p_recorded_at, p_occurred_at),
           'stock', 'movement', p_transfer_id || '-DSP-' || l.line_id, '0',
           p_transfer_id, l.line_id
      FROM src_stock.stock_transfer_line AS l
     WHERE l.transfer_id = p_transfer_id;

    UPDATE src_stock.stock_transfer SET current_status = 'dispatched' WHERE transfer_id = p_transfer_id;
END;
$$;
COMMENT ON PROCEDURE src_stock.dispatch_transfer(text, timestamptz, timestamptz) IS
'DC staff confirms dispatch: writes one negative transfer_dispatch movement per line at the origin (movement ID <transfer>-DSP-<line>) and sets status dispatched, in one transaction. Raises an error unless the transfer is in status created.';

CREATE PROCEDURE src_stock.receive_transfer(
    p_transfer_id  text,
    p_occurred_at  timestamptz,
    p_recorded_at  timestamptz DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_transfer     src_stock.stock_transfer%ROWTYPE;
    v_dispatched_at timestamptz;
BEGIN
    SELECT * INTO v_transfer FROM src_stock.stock_transfer WHERE transfer_id = p_transfer_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown transfer %', p_transfer_id;
    END IF;
    IF v_transfer.current_status <> 'dispatched' THEN
        RAISE EXCEPTION 'Transfer % is % and cannot be received', p_transfer_id, v_transfer.current_status;
    END IF;

    SELECT max(occurred_at) INTO v_dispatched_at
      FROM src_stock.stock_movement
     WHERE transfer_id = p_transfer_id AND movement_type = 'transfer_dispatch';
    IF p_occurred_at < v_dispatched_at THEN
        RAISE EXCEPTION 'Transfer % cannot be received at % before its dispatch at %',
            p_transfer_id, p_occurred_at, v_dispatched_at;
    END IF;

    -- Complete delivery of the expected quantity only; partial deliveries and
    -- discrepancies are outside the initial prototype (Spec 4.3).
    INSERT INTO src_stock.stock_movement (
        movement_id, sku, location_code, movement_type, quantity, occurred_at, recorded_at,
        origin_system_code, origin_event_type, origin_event_id, origin_line_id,
        transfer_id, transfer_line_id)
    SELECT p_transfer_id || '-RCV-' || l.line_id, l.sku, v_transfer.destination_location_code,
           'transfer_receipt', l.quantity, p_occurred_at, coalesce(p_recorded_at, p_occurred_at),
           'stock', 'movement', p_transfer_id || '-RCV-' || l.line_id, '0',
           p_transfer_id, l.line_id
      FROM src_stock.stock_transfer_line AS l
     WHERE l.transfer_id = p_transfer_id;

    UPDATE src_stock.stock_transfer SET current_status = 'received' WHERE transfer_id = p_transfer_id;
END;
$$;
COMMENT ON PROCEDURE src_stock.receive_transfer(text, timestamptz, timestamptz) IS
'Destination staff confirms receipt: writes one positive transfer_receipt movement per line at the destination (movement ID <transfer>-RCV-<line>) and sets status received, in one transaction. Raises an error unless the transfer was dispatched and the receipt is not earlier than the dispatch.';

CREATE PROCEDURE src_stock.record_adjustment(
    p_sku            text,
    p_location_code  text,
    p_quantity       integer,
    p_occurred_at    timestamptz,
    p_reason_code    text,
    p_recorded_at    timestamptz DEFAULT NULL,
    p_movement_id    text DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_movement_id text := coalesce(p_movement_id, src_stock.next_movement_id());
BEGIN
    -- A confirmed, signed count correction. Damaged units leave the sellable
    -- stock tracked here through a negative adjustment (Spec 4.3 activity C).
    INSERT INTO src_stock.stock_movement (
        movement_id, sku, location_code, movement_type, quantity, occurred_at, recorded_at,
        origin_system_code, origin_event_type, origin_event_id, origin_line_id, reason_code)
    VALUES (
        v_movement_id, p_sku, p_location_code, 'adjustment', p_quantity, p_occurred_at,
        coalesce(p_recorded_at, p_occurred_at), 'stock', 'movement', v_movement_id, '0', p_reason_code);
END;
$$;
COMMENT ON PROCEDURE src_stock.record_adjustment(text, text, integer, timestamptz, text, timestamptz, text) IS
'Records an authorised, signed count adjustment with a reason. p_occurred_at is when the difference took effect; p_recorded_at (default p_occurred_at) is when it was entered and may be later. Raises an error for a zero quantity or missing reason.';

CREATE PROCEDURE src_stock.record_reversal(
    p_reverses_movement_id  text,
    p_occurred_at           timestamptz,
    p_reason_code           text,
    p_recorded_at           timestamptz DEFAULT NULL,
    p_movement_id           text DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_original    src_stock.stock_movement%ROWTYPE;
    v_movement_id text := coalesce(p_movement_id, src_stock.next_movement_id());
BEGIN
    SELECT * INTO v_original FROM src_stock.stock_movement WHERE movement_id = p_reverses_movement_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Movement % does not exist', p_reverses_movement_id;
    END IF;
    IF v_original.movement_type = 'reversal' THEN
        RAISE EXCEPTION 'Movement % is itself a reversal', p_reverses_movement_id;
    END IF;
    IF EXISTS (SELECT 1 FROM src_stock.stock_movement WHERE reverses_movement_id = p_reverses_movement_id) THEN
        RAISE EXCEPTION 'Movement % has already been reversed', p_reverses_movement_id;
    END IF;

    -- The original stays in history; the reversal is a new opposite movement
    -- effective from its own time (Arch 10.5).
    INSERT INTO src_stock.stock_movement (
        movement_id, sku, location_code, movement_type, quantity, occurred_at, recorded_at,
        origin_system_code, origin_event_type, origin_event_id, origin_line_id,
        reason_code, reverses_movement_id)
    VALUES (
        v_movement_id, v_original.sku, v_original.location_code, 'reversal', -v_original.quantity,
        p_occurred_at, coalesce(p_recorded_at, p_occurred_at),
        'stock', 'movement', v_movement_id, '0', p_reason_code, p_reverses_movement_id);
END;
$$;
COMMENT ON PROCEDURE src_stock.record_reversal(text, timestamptz, text, timestamptz, text) IS
'Corrects an earlier central movement by appending an opposite reversal movement linked through reverses_movement_id. The original is never edited. Raises an error if the original does not exist, is a reversal, or was already reversed.';
