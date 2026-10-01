-- =============================================================================
-- seed/case_1_common.sql
-- Purpose: The part of Spec Case 1 that the baseline and improved runs share:
--          opening stock, the 5 am website copy, Customer A's reservation and
--          the four Parramatta till sales before 2 pm.
-- Prerequisites: Empty isolated scenario database with the schema applied.
-- Inputs: None (synthetic Case 1 data; Day 1 = Wed 16 Sep 2026, Sydney time,
--         before daylight saving starts on 4 Oct 2026).
-- Outputs: Source records and checkpoint loads/observations up to 2 pm.
-- Execution: Included by case_1_baseline.sql and case_1_improved.sql; run
--            through scripts/run_scenario.py, which executes each @step in its
--            own transaction and performs @checkpoint loads in order.
-- Rerun behaviour: Not rerunnable in the same database; scenarios always start
--                  from a fresh isolated database.
-- Business rules: Spec 6 Case 1; Architecture_and_Data_Model.md 14.2.
--
-- Directive lines (read by scripts/run_scenario.py):
--   -- @step <code> | <description>            SQL below it runs as one transaction
--   -- @checkpoint <code> | <time> | <text>    load all sources as of <time>, then
--                                             save report observations at <time>
-- =============================================================================

-- @include base_sources.sql

-- @step d1_0100_opening_snapshot | Day 1, 1 am: central produces the reconciled midnight snapshot (five bags at Parramatta)
CALL src_stock.bootstrap_opening_snapshot(
    'SNAP-20260916',
    '2026-09-16 00:00 Australia/Sydney',
    '2026-09-16 01:00 Australia/Sydney',
    '[{"sku": "PH-10231", "location_code": "STR-PAR", "quantity": 5},
      {"sku": "PH-10231", "location_code": "STR-CHA", "quantity": 8},
      {"sku": "PH-10231", "location_code": "DC-MOO",  "quantity": 40},
      {"sku": "PH-20455", "location_code": "STR-PAR", "quantity": 6},
      {"sku": "PH-20455", "location_code": "STR-CHA", "quantity": 4},
      {"sku": "PH-30710", "location_code": "STR-PAR", "quantity": 12}]');

-- @checkpoint cp_d1_0100 | 2026-09-16 01:00 Australia/Sydney | Midnight snapshot exists; the website has no copy yet

-- @step d1_0500_website_refresh | Day 1, 5 am: website copies the midnight snapshot
CALL src_online.refresh_website_stock('WEB-20260916', 'SNAP-20260916', '2026-09-16 05:00 Australia/Sydney');

-- @checkpoint cp_d1_0500 | 2026-09-16 05:00 Australia/Sydney | Website copy and integrated result agree: five available

-- @step d1_0930_order_a | 9:30 am: Customer A places a Click & Collect order for one bag at Parramatta
CALL src_online.place_order(
    'W-1001', 'E-1001-1', '2026-09-16 09:30 Australia/Sydney', 'click_collect', 'store-parramatta',
    '[{"line_id": "1", "sku": "PH-10231", "quantity": 1}]');

-- @checkpoint cp_d1_0930 | 2026-09-16 09:30 Australia/Sydney | A's reservation: website and integrated both show four

-- @step d1_0950_order_a_ready | 9:50 am: staff sets A's bag aside behind the counter (still on hand, still reserved)
CALL src_online.change_order_status('E-1001-2', 'W-1001', 'ready', '2026-09-16 09:50 Australia/Sydney');

-- @step d1_1015_till_sale_1 | 10:15 am: walk-in customer buys one bag at a Parramatta till
CALL src_store_sales.record_sale('S-0123-0001', '0123', 'T01', '2026-09-16 10:15 Australia/Sydney',
    '[{"line_id": "1", "barcode": "9300000102314", "quantity": 1}]');

-- @step d1_1105_background_sale | 11:05 am: background sale of one KONG toy at Chatswood
CALL src_store_sales.record_sale('S-0145-0001', '0145', 'T02', '2026-09-16 11:05 Australia/Sydney',
    '[{"line_id": "1", "barcode": "9300000204551", "quantity": 1}]');

-- @step d1_1140_till_sale_2 | 11:40 am: second bag sold; the till scans the alternative barcode
CALL src_store_sales.record_sale('S-0123-0002', '0123', 'T02', '2026-09-16 11:40 Australia/Sydney',
    '[{"line_id": "1", "barcode": "0930000102310", "quantity": 1}]');

-- @step d1_1230_till_sale_3 | 12:30 pm: third bag sold at a Parramatta till
CALL src_store_sales.record_sale('S-0123-0003', '0123', 'T01', '2026-09-16 12:30 Australia/Sydney',
    '[{"line_id": "1", "barcode": "9300000102314", "quantity": 1}]');

-- @step d1_1350_till_sale_4 | 1:50 pm: fourth bag sold; only A's set-aside bag remains
CALL src_store_sales.record_sale('S-0123-0004', '0123', 'T01', '2026-09-16 13:50 Australia/Sydney',
    '[{"line_id": "1", "barcode": "9300000102314", "quantity": 1}]');

-- @checkpoint cp_d1_1400 | 2026-09-16 14:00 Australia/Sydney | Website still says four; integrated: one on hand minus one reserved = zero
