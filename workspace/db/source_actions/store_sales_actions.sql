-- =============================================================================
-- source_actions/store_sales_actions.sql
-- Purpose: Business write procedure of the store sales source: a till
--          completes a sale.
-- Prerequisites: 02_source_tables.sql.
-- Inputs: Procedure arguments supplied by scenario files (db/seed/*.sql).
-- Outputs: src_store_sales.sale and sale_line rows.
-- Execution: Created by scripts/apply_schema.py; called by scenario steps,
--            for example CALL src_store_sales.record_sale(...).
-- Transaction: Runs in the caller's transaction, so the header and its lines
--              are saved together or not at all.
-- Rerun behaviour: A second call with the same sale_id fails on the primary
--                  key; a completed sale is never edited.
-- Business rules: Spec 4.1; Architecture_and_Data_Model.md 4.1.
-- =============================================================================

CREATE PROCEDURE src_store_sales.record_sale(
    p_sale_id       text,
    p_store_code    text,
    p_till_id       text,
    p_completed_at  timestamptz,
    p_lines         jsonb,
    p_recorded_at   timestamptz DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_unknown_barcode text;
BEGIN
    -- A completed sale has at least one line; a header alone is not a sale.
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Sale % needs at least one line', p_sale_id;
    END IF;

    -- The till prices a scanned barcode from its own product list.
    SELECT l.barcode INTO v_unknown_barcode
      FROM jsonb_to_recordset(p_lines) AS l(line_id text, barcode text, quantity integer)
      LEFT JOIN src_store_sales.product AS p ON p.barcode = l.barcode
     WHERE p.barcode IS NULL
     LIMIT 1;
    IF v_unknown_barcode IS NOT NULL THEN
        RAISE EXCEPTION 'Barcode % is not in the till product list', v_unknown_barcode;
    END IF;

    -- Connected tills save the sale immediately (Spec 3.2).
    INSERT INTO src_store_sales.sale (sale_id, store_code, till_id, completed_at, recorded_at)
    VALUES (p_sale_id, p_store_code, p_till_id, p_completed_at, coalesce(p_recorded_at, p_completed_at));

    INSERT INTO src_store_sales.sale_line (sale_id, line_id, barcode, quantity, unit_price)
    SELECT p_sale_id, l.line_id, l.barcode, l.quantity, p.unit_price
      FROM jsonb_to_recordset(p_lines) AS l(line_id text, barcode text, quantity integer)
      JOIN src_store_sales.product AS p ON p.barcode = l.barcode;
END;
$$;
COMMENT ON PROCEDURE src_store_sales.record_sale(text, text, text, timestamptz, jsonb, timestamptz) IS
'Records one completed till sale. p_lines is a JSON array of {"line_id","barcode","quantity"}; unit prices come from the till product list. Saves header and lines in the caller''s transaction. Raises an error for an empty sale, an unknown till barcode or a duplicate sale ID. Does not touch central stock or the website.';
