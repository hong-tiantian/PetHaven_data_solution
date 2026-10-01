-- =============================================================================
-- seed/source_completeness.sql
-- Purpose: T24. One required source table is omitted from an extraction.
--          The manifest check must block publication; a complete extraction
--          then succeeds.
-- Prerequisites: Empty isolated scenario database with the schema applied.
-- Inputs: None (synthetic data; Day 1 = 16 Sep 2026).
-- Outputs: A rejected run with an incomplete_extract issue, then a succeeded run.
-- Execution: python /workspace/scripts/run_scenario.py source_completeness
-- Rerun behaviour: Not rerunnable in the same database.
-- Business rules: Architecture_and_Data_Model.md 12.1 and 12.2.
-- Checks: tests/expected/source_completeness.csv (T24).
--
-- "skip_tables" is a test hook passed to raw.extract_sources.
-- =============================================================================

-- @include base_sources.sql

-- @step d1_0100_opening_snapshot | Opening snapshot
CALL src_stock.bootstrap_opening_snapshot(
    'SNAP-20260916',
    '2026-09-16 00:00 Australia/Sydney',
    '2026-09-16 01:00 Australia/Sydney',
    '[{"sku": "PH-10231", "location_code": "STR-PAR", "quantity": 5}]');

-- @step d1_0500_website_refresh | 5 am: website copies the snapshot
CALL src_online.refresh_website_stock('WEB-20260916', 'SNAP-20260916', '2026-09-16 05:00 Australia/Sydney');

-- @step d1_0930_order | 9:30 am: C&C order for one bag at Parramatta
CALL src_online.place_order(
    'W-1001', 'E-1001-1', '2026-09-16 09:30 Australia/Sydney', 'click_collect', 'store-parramatta',
    '[{"line_id": "1", "sku": "PH-10231", "quantity": 1}]');

-- @checkpoint s_d1_1000 | 2026-09-16 10:00 Australia/Sydney | Order lines were not extracted: publication blocked | {"skip_tables": ["online.web_order_line"]}

-- @check chk_par_rc_1000 | 2026-09-16 10:00 Australia/Sydney | store-parramatta | [{"sku": "PH-10231", "quantity": 1}] | An incomplete load gives no stock answer

-- @checkpoint s_d1_1100 | 2026-09-16 11:00 Australia/Sydney | Complete extraction succeeds
