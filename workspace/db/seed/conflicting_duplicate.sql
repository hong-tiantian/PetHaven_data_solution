-- =============================================================================
-- seed/conflicting_duplicate.sql
-- Purpose: T15. The central overnight copy of a till sale disagrees with the
--          original sale. Publication must be blocked, both raw
--          representations named, and the published fact left unchanged.
-- Prerequisites: Empty isolated scenario database with the schema applied.
-- Inputs: None (synthetic data; Day 1 = 16 Sep 2026, Day 2 = 17 Sep 2026).
-- Outputs: A succeeded run, then a rejected run with a conflict issue.
-- Execution: python /workspace/scripts/run_scenario.py conflicting_duplicate
-- Rerun behaviour: Not rerunnable in the same database.
-- Business rules: Spec 5.2; Architecture_and_Data_Model.md 8.2.
-- Checks: tests/expected/conflicting_duplicate.csv (T15).
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

-- @checkpoint c_d1_1100 | 2026-09-16 11:00 Australia/Sydney | Direct sale published as one movement of -1

-- @step d2_0100_overnight_import | Day 2, 1 am: central imports the sale and produces the snapshot
CALL src_stock.import_daily_transactions('2026-09-17 00:00 Australia/Sydney', '2026-09-17 01:00 Australia/Sydney');
CALL src_stock.create_midnight_snapshot('SNAP-20260917', '2026-09-17 00:00 Australia/Sydney',
    'SNAP-20260916', '2026-09-17 01:00 Australia/Sydney');

-- @step d2_0130_fault_injection | FAULT INJECTION (test only): simulate a faulty central import that recorded two bags instead of one
UPDATE src_stock.stock_movement
   SET quantity = -2
 WHERE origin_system_code = 'store_sales' AND origin_event_id = 'S-0123-0001' AND origin_line_id = '1';

-- @checkpoint c_d2_0200 | 2026-09-17 02:00 Australia/Sydney | Representations disagree: publication blocked
