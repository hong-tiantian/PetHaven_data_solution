-- =============================================================================
-- tests/sql/case_1_improved.sql
-- Purpose: Scenario-specific actual values for case_1_improved (T02).
-- Prerequisites: seed/case_1_improved.sql executed in this database.
-- Outputs: Rows (check_name, actual) compared with tests/expected/case_1_improved.csv.
-- Execution: scripts/run_acceptance.py, after tests/sql/common_checks.sql.
-- Transaction: Read-only.
-- =============================================================================

-- T02: the simulated check created no accepted order for Sarah.
SELECT 'final/sarah_order_exists' AS check_name,
       EXISTS (SELECT 1 FROM src_online.web_order WHERE order_id = 'W-1002')::text AS actual;
