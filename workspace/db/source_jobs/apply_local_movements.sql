-- =============================================================================
-- source_jobs/apply_local_movements.sql
-- Purpose: Simulate central stock's HOURLY processing: apply locally recorded
--          movements to the central current balances (stock_on_hand).
-- Prerequisites: 02_source_tables.sql.
-- Inputs: p_processed_at - the simulated time of this hourly run.
-- Outputs: Updated src_stock.stock_on_hand and new movement_application rows.
-- Execution: Created by scripts/apply_schema.py; called by scenario steps, for
--            example CALL src_stock.apply_local_movements('2026-09-16 11:00 Australia/Sydney').
-- Transaction: Balance updates and application records are written in the
--              caller's transaction, so they succeed or fail together.
-- Rerun behaviour: Safe to rerun. A movement already in movement_application
--                  is never applied again (primary key and NOT EXISTS filter).
-- Business rules: Spec 3.2; Architecture_and_Data_Model.md 11.1.
--
-- This is part of the EXISTING business, not the new integration. Store sales
-- and online collections are not applied here; they reach central only at the
-- 1 am import. That is why central's current balance can mix fresh receipts
-- with day-old sales information.
-- =============================================================================

CREATE PROCEDURE src_stock.apply_pending_movements(
    p_processed_at  timestamptz,
    p_local_only    boolean
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Serialise balance processing so two jobs cannot apply the same movement.
    PERFORM pg_advisory_xact_lock(hashtext('src_stock.apply_pending_movements'));

    CREATE TEMPORARY TABLE pending_movement ON COMMIT DROP AS
    SELECT m.movement_id, m.sku, m.location_code, m.quantity
      FROM src_stock.stock_movement AS m
     WHERE m.recorded_at <= p_processed_at
       AND (NOT p_local_only OR m.origin_system_code = 'stock')
       AND NOT EXISTS (
            SELECT 1 FROM src_stock.movement_application AS a WHERE a.movement_id = m.movement_id);

    INSERT INTO src_stock.stock_on_hand (sku, location_code, on_hand_quantity, updated_at)
    SELECT p.sku, p.location_code, sum(p.quantity), p_processed_at
      FROM pending_movement AS p
     GROUP BY p.sku, p.location_code
    ON CONFLICT (sku, location_code) DO UPDATE
       SET on_hand_quantity = src_stock.stock_on_hand.on_hand_quantity + EXCLUDED.on_hand_quantity,
           updated_at = EXCLUDED.updated_at;

    INSERT INTO src_stock.movement_application (movement_id, applied_at)
    SELECT p.movement_id, p_processed_at FROM pending_movement AS p;

    DROP TABLE pending_movement;
END;
$$;
COMMENT ON PROCEDURE src_stock.apply_pending_movements(timestamptz, boolean) IS
'Applies every movement recorded by p_processed_at and not yet applied to src_stock.stock_on_hand, and records each application. p_local_only restricts it to locally created central movements (hourly run). Runs in the caller''s transaction; idempotent.';

CREATE PROCEDURE src_stock.apply_local_movements(p_processed_at timestamptz)
LANGUAGE plpgsql
AS $$
BEGIN
    CALL src_stock.apply_pending_movements(p_processed_at, true);
END;
$$;
COMMENT ON PROCEDURE src_stock.apply_local_movements(timestamptz) IS
'Hourly central processing: applies locally recorded receipts, transfer movements, adjustments and reversals to current balances. Idempotent; runs in the caller''s transaction.';
