-- =============================================================================
-- source_jobs/refresh_website_stock.sql
-- Purpose: Simulate the 5 am website refresh that copies central's fixed
--          midnight snapshot into the online orders database.
-- Prerequisites: 02_source_tables.sql; the snapshot exists.
-- Inputs: p_copy_id (new refresh ID), p_snapshot_id, p_copied_at (5 am).
-- Outputs: New immutable src_online.web_stock_copy rows.
-- Execution: Called by scenario steps, for example
--            CALL src_online.refresh_website_stock('WEB-20260916', 'SNAP-20260916',
--                                                  '2026-09-16 05:00 Australia/Sydney');
-- Transaction: All copy rows are written in the caller's transaction.
-- Rerun behaviour: A repeated copy ID raises an error (copies are immutable).
-- Business rules: Spec 3.2 and 5.3; Architecture_and_Data_Model.md 11.3.
--
-- After the copy the website recalculates from the new opening balance: it
-- still subtracts every active reservation (including orders from earlier
-- days) and every online collection after the new cutoff. That calculation is
-- src_online.website_available_quantity; nothing else is stored here.
-- =============================================================================

CREATE PROCEDURE src_online.refresh_website_stock(
    p_copy_id      text,
    p_snapshot_id  text,
    p_copied_at    timestamptz
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_created_at timestamptz;
BEGIN
    SELECT max(created_at) INTO v_created_at
      FROM src_stock.stock_snapshot WHERE snapshot_id = p_snapshot_id;
    IF v_created_at IS NULL THEN
        RAISE EXCEPTION 'Snapshot % does not exist', p_snapshot_id;
    END IF;
    IF v_created_at > p_copied_at THEN
        RAISE EXCEPTION 'Snapshot % was created at %, after the copy time %', p_snapshot_id, v_created_at, p_copied_at;
    END IF;

    -- Only locations the website sells from (stores and the DC) are copied,
    -- translated to online location codes.
    INSERT INTO src_online.web_stock_copy
        (copy_id, sku, location_code, on_hand_quantity, source_snapshot_id, snapshot_cutoff_at, copied_at)
    SELECT p_copy_id, s.sku, x.external_code, s.on_hand_quantity, s.snapshot_id, s.cutoff_at, p_copied_at
      FROM src_stock.stock_snapshot AS s
      JOIN src_stock.external_location_code AS x
        ON x.system_code = 'online' AND x.location_code = s.location_code
     WHERE s.snapshot_id = p_snapshot_id;
END;
$$;
COMMENT ON PROCEDURE src_online.refresh_website_stock(text, text, timestamptz) IS
'5 am refresh: copies every row of central snapshot p_snapshot_id for locations with an online code into a new web_stock_copy refresh p_copy_id, keeping the snapshot cutoff and recording p_copied_at. Raises an error for a missing snapshot, a snapshot created after the copy time, or a repeated copy ID.';
