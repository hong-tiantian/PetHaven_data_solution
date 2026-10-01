-- =============================================================================
-- seed/case_2.sql
-- Purpose: Spec Case 2: the last bag sells in store before an evening online
--          order; the accepted commitment stays at risk until it is cancelled.
-- Prerequisites: Empty isolated scenario database with the schema applied.
-- Inputs: None (synthetic data; Day 1 = 16 Sep 2026, Day 2 = 17 Sep 2026).
-- Outputs: Source records, load runs, saved report observations.
-- Execution: python /workspace/scripts/run_scenario.py case_2
-- Rerun behaviour: Not rerunnable in the same database.
-- Business rules: Spec 6 Case 2.
-- Checks: tests/expected/case_2.csv (T03).
-- =============================================================================

-- @focus PH-10231@STR-PAR
-- @include base_sources.sql

-- @step d1_0100_opening_snapshot | Day 1, 1 am: one bag at Parramatta in the reconciled midnight snapshot
CALL src_stock.bootstrap_opening_snapshot(
    'SNAP-20260916',
    '2026-09-16 00:00 Australia/Sydney',
    '2026-09-16 01:00 Australia/Sydney',
    '[{"sku": "PH-10231", "location_code": "STR-PAR", "quantity": 1},
      {"sku": "PH-10231", "location_code": "STR-CHA", "quantity": 8},
      {"sku": "PH-10231", "location_code": "DC-MOO",  "quantity": 40}]');

-- @step d1_0500_website_refresh | 5 am: website copies one bag
CALL src_online.refresh_website_stock('WEB-20260916', 'SNAP-20260916', '2026-09-16 05:00 Australia/Sydney');

-- @checkpoint cp_d1_0500 | 2026-09-16 05:00 Australia/Sydney | One bag on hand and available everywhere

-- @step d1_1400_walk_in_sale | 2 pm: a walk-in customer buys the last bag at a till
CALL src_store_sales.record_sale('S-0123-0101', '0123', 'T03', '2026-09-16 14:00 Australia/Sydney',
    '[{"line_id": "1", "barcode": "9300000102314", "quantity": 1}]');

-- @checkpoint cp_d1_1400 | 2026-09-16 14:00 Australia/Sydney | Website still shows one; integrated shows zero

-- @step d1_1800_online_order | 6 pm: the website's own calculation (1) accepts an online C&C order
CALL src_online.place_order(
    'W-2001', 'E-2001-1', '2026-09-16 18:00 Australia/Sydney', 'click_collect', 'store-parramatta',
    '[{"line_id": "1", "sku": "PH-10231", "quantity": 1}]');

-- @checkpoint cp_d1_1800 | 2026-09-16 18:00 Australia/Sydney | Accepted commitment with nothing on hand: shortfall one

-- @step d2_0100_overnight_import | Next 1 am: central imports the till sale and produces the midnight snapshot
CALL src_stock.import_daily_transactions('2026-09-17 00:00 Australia/Sydney', '2026-09-17 01:00 Australia/Sydney');
CALL src_stock.create_midnight_snapshot('SNAP-20260917', '2026-09-17 00:00 Australia/Sydney',
    'SNAP-20260916', '2026-09-17 01:00 Australia/Sydney');

-- @checkpoint cp_d2_0100 | 2026-09-17 01:00 Australia/Sydney | Central now records zero; the commitment remains

-- @step d2_0500_website_refresh | Next 5 am: website refreshes to zero on hand
CALL src_online.refresh_website_stock('WEB-20260917', 'SNAP-20260917', '2026-09-17 05:00 Australia/Sydney');

-- @checkpoint cp_d2_0500 | 2026-09-17 05:00 Australia/Sydney | A refresh alone does not resolve the accepted order

-- @step d2_0900_cancel | Next 9 am: staff cannot pick the order and cancels it for insufficient stock
CALL src_online.change_order_status('E-2001-2', 'W-2001', 'cancelled', '2026-09-17 09:00 Australia/Sydney',
    'insufficient_stock');

-- @checkpoint cp_d2_0900 | 2026-09-17 09:00 Australia/Sydney | Commitment ended by cancellation
