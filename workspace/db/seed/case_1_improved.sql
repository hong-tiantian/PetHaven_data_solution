-- =============================================================================
-- seed/case_1_improved.sql
-- Purpose: Spec Case 1, IMPROVED run: the same morning as the baseline, but
--          Sarah's proposed order is checked against the integrated
--          availability first. The check reports insufficient stock and no
--          order is created.
-- Prerequisites: Empty isolated scenario database with the schema applied.
-- Inputs: None (synthetic data; Day 1 = 16 Sep 2026).
-- Outputs: Source records, load runs, saved observations and the saved
--          simulated stock check.
-- Execution: python /workspace/scripts/run_scenario.py case_1_improved
-- Rerun behaviour: Not rerunnable in the same database.
-- Business rules: Spec 7.1 and 7.3; Architecture_and_Data_Model.md 14.2.
-- Checks: tests/expected/case_1_improved.csv (T02).
--
--   -- @check <code> | <time> | <pickup code> | <JSON request> | <text>
--   runs rpt.check_availability with the most recent load and saves the
--   answer in rpt.stock_check. It never creates an order.
-- =============================================================================

-- @focus PH-10231@STR-PAR
-- @include case_1_common.sql

-- @checkpoint cp_d1_1500 | 2026-09-16 15:00 Australia/Sydney | Integrated data is loaded before Sarah's request is answered

-- @check chk_sarah_1500 | 2026-09-16 15:00 Australia/Sydney | store-parramatta | [{"sku": "PH-10231", "quantity": 1}] | Sarah asks for one bag at Parramatta: simulated check says insufficient
