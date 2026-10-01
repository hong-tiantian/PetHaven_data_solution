-- =============================================================================
-- seed/failed_publication.sql
-- Purpose: T21. Publication fails after facts were written. No partial
--          warehouse load or ready report may be visible; raw evidence stays;
--          the next load publishes normally.
-- Prerequisites: Empty isolated scenario database with the schema applied.
-- Inputs: None (synthetic data; Day 1 = 16 Sep 2026).
-- Outputs: A failed run, then a succeeded run.
-- Execution: python /workspace/scripts/run_scenario.py failed_publication
-- Rerun behaviour: Not rerunnable in the same database.
-- Business rules: Architecture_and_Data_Model.md 12.2.
-- Checks: tests/expected/failed_publication.csv (T21).
--
-- The fourth field of a @checkpoint holds load options as JSON. "fault":
-- "fail_after_facts" is a test hook passed to dw.load_warehouse.
-- =============================================================================

-- @include base_sources.sql

-- @step d1_0100_opening_snapshot | Opening snapshot
CALL src_stock.bootstrap_opening_snapshot(
    'SNAP-20260916',
    '2026-09-16 00:00 Australia/Sydney',
    '2026-09-16 01:00 Australia/Sydney',
    '[{"sku": "PH-10231", "location_code": "STR-PAR", "quantity": 5}]');

-- @step d1_1015_till_sale | 10:15 am: one bag sold at Parramatta
CALL src_store_sales.record_sale('S-0123-0001', '0123', 'T01', '2026-09-16 10:15 Australia/Sydney',
    '[{"line_id": "1", "barcode": "9300000102314", "quantity": 1}]');

-- @checkpoint f_d1_1100 | 2026-09-16 11:00 Australia/Sydney | Injected failure during publication | {"fault": "fail_after_facts"}

-- @check chk_par_rc_1100 | 2026-09-16 11:00 Australia/Sydney | store-parramatta | [{"sku": "PH-10231", "quantity": 1}] | A failed load gives no stock answer

-- @checkpoint f_d1_1200 | 2026-09-16 12:00 Australia/Sydney | Next load publishes normally
