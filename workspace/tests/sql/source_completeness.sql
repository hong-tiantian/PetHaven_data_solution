-- =============================================================================
-- tests/sql/source_completeness.sql
-- Purpose: Scenario-specific actual values for source_completeness (T24).
-- Prerequisites: seed/source_completeness.sql executed in this database.
-- Outputs: Rows (check_name, actual) compared with tests/expected/source_completeness.csv.
-- Execution: scripts/run_acceptance.py, after tests/sql/common_checks.sql.
-- Transaction: Read-only.
-- =============================================================================

SELECT 's_d1_1000/missing_extract_table' AS check_name,
       string_agg(i.source_reference, ';' ORDER BY i.source_reference) AS actual
  FROM audit.data_quality_issue AS i
  JOIN audit.load_run AS lr ON lr.load_run_id = i.load_run_id
 WHERE lr.run_code = 's_d1_1000' AND i.rule_code = 'incomplete_extract';
