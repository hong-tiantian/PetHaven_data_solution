-- =============================================================================
-- seed/case_1_baseline.sql
-- Purpose: Spec Case 1, BASELINE run: the existing website accepts Sarah's
--          order, staff discovers the shortage and cancels it, then the 1 am
--          import and 5 am refresh run on Day 2.
-- Prerequisites: Empty isolated scenario database with the schema applied.
-- Inputs: None (synthetic data; Day 1 = 16 Sep 2026, Day 2 = 17 Sep 2026).
-- Outputs: Source records, load runs, saved report observations.
-- Execution: python /workspace/scripts/run_scenario.py case_1_baseline
--            (normally through scripts/run_acceptance.py).
-- Rerun behaviour: Not rerunnable in the same database.
-- Business rules: Spec 6 Case 1 and 7.3; Architecture_and_Data_Model.md 14.2.
-- Checks: tests/expected/case_1_baseline.csv (T01, T08, T09, T10, T12, T17,
--         T22, T23).
-- =============================================================================

-- @focus PH-10231@STR-PAR
-- @include case_1_common.sql

-- @step d1_1500_order_sarah | 3 pm: Sarah sees "Parramatta - In stock"; the website's own calculation (4) accepts her order
CALL src_online.place_order(
    'W-1002', 'E-1002-1', '2026-09-16 15:00 Australia/Sydney', 'click_collect', 'store-parramatta',
    '[{"line_id": "1", "sku": "PH-10231", "quantity": 1}]');

-- @checkpoint cp_d1_1500 | 2026-09-16 15:00 Australia/Sydney | Two commitments compete for one bag: shortfall one

-- @checkpoint cp_d1_1530 | 2026-09-16 15:30 Australia/Sydney | Staff finds only A's set-aside bag (no new record)

-- @step d1_1545_cancel_sarah | 3:45 pm: Sarah agrees to cancel; reason insufficient stock; her reservation is released
CALL src_online.change_order_status('E-1002-2', 'W-1002', 'cancelled', '2026-09-16 15:45 Australia/Sydney',
    'insufficient_stock');

-- @checkpoint cp_d1_1545 | 2026-09-16 15:45 Australia/Sydney | Website returns to four; integrated still zero available

-- @step d2_0100_overnight_import | Day 2, 1 am: central imports the Day 1 till sales and produces the midnight snapshot
CALL src_stock.import_daily_transactions('2026-09-17 00:00 Australia/Sydney', '2026-09-17 01:00 Australia/Sydney');
CALL src_stock.create_midnight_snapshot('SNAP-20260917', '2026-09-17 00:00 Australia/Sydney',
    'SNAP-20260916', '2026-09-17 01:00 Australia/Sydney');

-- @step d2_0100_rerun_jobs | Rerun the 1 am import and the hourly job: nothing may be applied twice (T22)
CALL src_stock.import_daily_transactions('2026-09-17 00:00 Australia/Sydney', '2026-09-17 01:00 Australia/Sydney');
CALL src_stock.apply_local_movements('2026-09-17 01:00 Australia/Sydney');

-- @checkpoint cp_d2_0100 | 2026-09-17 01:00 Australia/Sydney | Only central has processed the store sales; website still four

-- @step d2_0500_website_refresh | Day 2, 5 am: website copies one on hand and subtracts A's carried-over reservation
CALL src_online.refresh_website_stock('WEB-20260917', 'SNAP-20260917', '2026-09-17 05:00 Australia/Sydney');

-- @checkpoint cp_d2_0500 | 2026-09-17 05:00 Australia/Sydney | Website reaches zero after its refresh

-- @checkpoint cp_d2_0500_repeat | 2026-09-17 05:00 Australia/Sydney | Repeat full load with no new business actions (T09)

-- @observe cp_hist_d1_1500 | 2026-09-16 15:00 Australia/Sydney | cp_d2_0500 | Later reconstruction of 3 pm uses status history, not today's status (T17)
