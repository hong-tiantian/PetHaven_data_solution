-- =============================================================================
-- seed/movement_checks.sql
-- Purpose: One synthetic two-day run that exercises every physical-movement
--          and reservation rule outside the two Spec cases: collection,
--          cancellation, supplier receipt, transfer, exact-midnight event,
--          collection between midnight and 5 am, missing opening, late-arriving
--          event, equal acceptance times, multi-line check and correction.
-- Prerequisites: Empty isolated scenario database with the schema applied.
-- Inputs: None (synthetic data; Day 1 = 16 Sep 2026, Day 2 = 17 Sep 2026).
-- Outputs: Source records, load runs, saved observations and stock checks.
-- Execution: python /workspace/scripts/run_scenario.py movement_checks
-- Rerun behaviour: Not rerunnable in the same database.
-- Business rules: Spec 4-5; Architecture_and_Data_Model.md 9-11 and 14.3.
-- Checks: tests/expected/movement_checks.csv (T04-T07, T11, T13, T16, T18,
--         T19, T20, T26).
--
-- Opening balances (snapshot SNAP-20260916, cutoff Day 1 00:00):
--   PH-10231 dog food : STR-PAR 5, STR-CHA 8, STR-NEW 2, DC-MOO 40
--   PH-20455 KONG toy : STR-PAR 10, STR-CHA 0 (known zero), DC-MOO 30
--   PH-30710 cat treat: DC-MOO 50; deliberately NO row for STR-NEW (T16)
-- Two synthetic events are placed at unusual hours on purpose: a stock count
-- at exactly midnight (T11) and a collection at 00:30 (T13). They test the
-- cutoff rules and are not claims about store trading hours.
-- =============================================================================

-- @include base_sources.sql

-- @step d1_0100_opening_snapshot | Day 1, 1 am: reconciled opening snapshot and matching current balances
CALL src_stock.bootstrap_opening_snapshot(
    'SNAP-20260916',
    '2026-09-16 00:00 Australia/Sydney',
    '2026-09-16 01:00 Australia/Sydney',
    '[{"sku": "PH-10231", "location_code": "STR-PAR", "quantity": 5},
      {"sku": "PH-10231", "location_code": "STR-CHA", "quantity": 8},
      {"sku": "PH-10231", "location_code": "STR-NEW", "quantity": 2},
      {"sku": "PH-10231", "location_code": "DC-MOO",  "quantity": 40},
      {"sku": "PH-20455", "location_code": "STR-PAR", "quantity": 10},
      {"sku": "PH-20455", "location_code": "STR-CHA", "quantity": 0},
      {"sku": "PH-20455", "location_code": "DC-MOO",  "quantity": 30},
      {"sku": "PH-30710", "location_code": "DC-MOO",  "quantity": 50}]');

-- @step d1_0500_website_refresh | 5 am: website copies the opening snapshot
CALL src_online.refresh_website_stock('WEB-20260916', 'SNAP-20260916', '2026-09-16 05:00 Australia/Sydney');

-- @checkpoint m_d1_0500 | 2026-09-16 05:00 Australia/Sydney | Opening position

-- @step d1_0900_order_chatswood | 9 am: C&C order W-3201 for two bags at Chatswood (T04, T13)
CALL src_online.place_order(
    'W-3201', 'E-3201-1', '2026-09-16 09:00 Australia/Sydney', 'click_collect', 'store-chatswood',
    '[{"line_id": "1", "sku": "PH-10231", "quantity": 2}]');

-- @step d1_1000_supplier_receipt | 10 am: DC confirms a supplier delivery of 20 bags (T06)
CALL src_stock.record_supplier_receipt('PH-10231', 'DC-MOO', 20, '2026-09-16 10:00 Australia/Sydney',
    'DLV-5001', 'SUP-RC-AU', p_movement_id => 'MV-RCPT-5001');

-- @step d1_1000_order_parramatta_toys | 10 am: C&C order W-3001 for three KONG toys at Parramatta (T05)
CALL src_online.place_order(
    'W-3001', 'E-3001-1', '2026-09-16 10:00 Australia/Sydney', 'click_collect', 'store-parramatta',
    '[{"line_id": "1", "sku": "PH-20455", "quantity": 3}]');

-- @checkpoint m_d1_1000 | 2026-09-16 10:00 Australia/Sydney | Receipt is visible to integration before central's hourly run

-- @step d1_1030_newtown_sale | 10:30 am: one bag sold at a Newtown till; website still believes two (T19)
CALL src_store_sales.record_sale('S-0167-0001', '0167', 'T01', '2026-09-16 10:30 Australia/Sydney',
    '[{"line_id": "1", "barcode": "9300000102314", "quantity": 1}]');

-- @step d1_1100_cancel_toys | 11 am: customer cancels W-3001 (change of mind) (T05)
CALL src_online.change_order_status('E-3001-2', 'W-3001', 'cancelled', '2026-09-16 11:00 Australia/Sydney',
    'customer_request');

-- @step d1_1100_hourly_processing | 11 am: central hourly run applies the receipt to its current balance (T06)
CALL src_stock.apply_local_movements('2026-09-16 11:00 Australia/Sydney');

-- @step d1_1100_equal_time_orders | 11 am: two Newtown orders accepted at the same instant; W-3105 is inserted before W-3099 (T19)
CALL src_online.place_order(
    'W-3105', 'E-3105-1', '2026-09-16 11:00 Australia/Sydney', 'click_collect', 'store-newtown',
    '[{"line_id": "1", "sku": "PH-10231", "quantity": 1}]');
CALL src_online.place_order(
    'W-3099', 'E-3099-1', '2026-09-16 11:00 Australia/Sydney', 'click_collect', 'store-newtown',
    '[{"line_id": "1", "sku": "PH-10231", "quantity": 1}]');

-- @checkpoint m_d1_1100 | 2026-09-16 11:00 Australia/Sydney | Cancellation released; equal-time orders compete for one bag

-- @step d1_1200_create_transfer | Noon: stock controller creates transfer TR-7001 of 10 bags DC -> Parramatta (T07)
CALL src_stock.create_transfer('TR-7001', 'DC-MOO', 'STR-PAR', '2026-09-16 12:00 Australia/Sydney',
    '[{"line_id": "1", "sku": "PH-10231", "quantity": 10}]');

-- @checkpoint m_d1_1200 | 2026-09-16 12:00 Australia/Sydney | Creating a transfer moves no stock

-- @step d1_1215_greenies_transfer_dispatch | 12:15 pm: transfer TR-7002 of 6 cat treats DC -> Newtown created and dispatched (T16)
CALL src_stock.create_transfer('TR-7002', 'DC-MOO', 'STR-NEW', '2026-09-16 12:10 Australia/Sydney',
    '[{"line_id": "1", "sku": "PH-30710", "quantity": 6}]');
CALL src_stock.dispatch_transfer('TR-7002', '2026-09-16 12:15 Australia/Sydney');

-- @step d1_1230_chatswood_ready | 12:30 pm: Chatswood staff sets W-3201 aside (T04)
CALL src_online.change_order_status('E-3201-2', 'W-3201', 'ready', '2026-09-16 12:30 Australia/Sydney');

-- @step d1_1300_dispatch_transfer | 1 pm: DC confirms dispatch of TR-7001 (T07)
CALL src_stock.dispatch_transfer('TR-7001', '2026-09-16 13:00 Australia/Sydney');

-- @step d1_1300_damage_adjustment | 1 pm: two damaged KONG toys removed at the DC (T26)
CALL src_stock.record_adjustment('PH-20455', 'DC-MOO', -2, '2026-09-16 13:00 Australia/Sydney', 'damaged',
    p_movement_id => 'MV-ADJ-0001');

-- @checkpoint m_d1_1300 | 2026-09-16 13:00 Australia/Sydney | Goods in transit belong to neither location

-- @step d1_1400_late_count_correction | 2 pm: a count correction effective at 10 am is entered late (-5 cat treats at the DC) (T18)
CALL src_stock.record_adjustment('PH-30710', 'DC-MOO', -5, '2026-09-16 10:00 Australia/Sydney', 'count_correction',
    p_recorded_at => '2026-09-16 14:00 Australia/Sydney', p_movement_id => 'MV-ADJ-0002');

-- @step d1_1400_greenies_transfer_receipt | 2 pm: Newtown receives TR-7002 (T16)
CALL src_stock.receive_transfer('TR-7002', '2026-09-16 14:00 Australia/Sydney');

-- @checkpoint m_d1_1400 | 2026-09-16 14:00 Australia/Sydney | Newtown cat treats have movements but no opening balance

-- @check chk_new_greenies_1400 | 2026-09-16 14:00 Australia/Sydney | store-newtown | [{"sku": "PH-30710", "quantity": 1}] | Missing opening balance gives an unknown answer (T16)

-- @observe m_recon_d1_1200 | 2026-09-16 12:00 Australia/Sydney | m_d1_1400 | Reconstruct noon with the late count correction (T18)

-- @step d1_1500_reverse_adjustment | 3 pm: recount finds the two KONG toys; the damage adjustment is reversed (T26)
CALL src_stock.record_reversal('MV-ADJ-0001', '2026-09-16 15:00 Australia/Sydney', 'recount_found_units',
    p_movement_id => 'MV-REV-0001');

-- @step d1_1600_receive_transfer | 4 pm: Parramatta counts and confirms receipt of TR-7001 (T07)
CALL src_stock.receive_transfer('TR-7001', '2026-09-16 16:00 Australia/Sydney');

-- @checkpoint m_d1_1600 | 2026-09-16 16:00 Australia/Sydney | Transfer received; reversal restores the DC toys

-- @check chk_cha_multi_1600 | 2026-09-16 16:00 Australia/Sydney | store-chatswood | [{"sku": "PH-10231", "quantity": 1}, {"sku": "PH-20455", "quantity": 1}] | One line available, one not: whole request insufficient (T20)

-- @expect_error reopen_cancelled_order | 4:30 pm: attempt to reopen cancelled order W-3001 is rejected (T26)
CALL src_online.change_order_status('E-3001-3', 'W-3001', 'awaiting_pick', '2026-09-16 16:30 Australia/Sydney');

-- @step d2_0000_midnight_count | Day 2, exactly 00:00: one KONG toy removed at Parramatta after a stock count (T11)
CALL src_stock.record_adjustment('PH-20455', 'STR-PAR', -1, '2026-09-17 00:00 Australia/Sydney', 'count_correction',
    p_movement_id => 'MV-ADJ-0003');

-- @step d2_0030_collection | 00:30: customer collects W-3201 at Chatswood (T04, T13)
CALL src_online.change_order_status('E-3201-3', 'W-3201', 'collected', '2026-09-17 00:30 Australia/Sydney');

-- @step d2_0100_overnight_import | 1 am: central imports Day 1 sales and collections and produces the midnight snapshot
CALL src_stock.import_daily_transactions('2026-09-17 00:00 Australia/Sydney', '2026-09-17 01:00 Australia/Sydney');
CALL src_stock.create_midnight_snapshot('SNAP-20260917', '2026-09-17 00:00 Australia/Sydney',
    'SNAP-20260916', '2026-09-17 01:00 Australia/Sydney');

-- @checkpoint m_d2_0100 | 2026-09-17 01:00 Australia/Sydney | New opening; midnight event and 00:30 collection fall after it

-- @step d2_0500_website_refresh | 5 am: website copies the Day 2 snapshot
CALL src_online.refresh_website_stock('WEB-20260917', 'SNAP-20260917', '2026-09-17 05:00 Australia/Sydney');

-- @checkpoint m_d2_0500 | 2026-09-17 05:00 Australia/Sydney | Website deducts the 00:30 collection from its new copy
