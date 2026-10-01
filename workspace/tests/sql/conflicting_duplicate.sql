-- =============================================================================
-- tests/sql/conflicting_duplicate.sql
-- Purpose: Scenario-specific actual values for conflicting_duplicate (T15).
-- Prerequisites: seed/conflicting_duplicate.sql executed in this database.
-- Outputs: Rows (check_name, actual) compared with tests/expected/conflicting_duplicate.csv.
-- Execution: scripts/run_acceptance.py, after tests/sql/common_checks.sql.
-- Transaction: Read-only.
-- =============================================================================

-- The raw tables named in the conflict issue, sorted and joined with ';'.
SELECT 'c_d2_0200/conflict_raw_tables' AS check_name,
       (SELECT string_agg(DISTINCT t[1], ';' ORDER BY t[1])
          FROM regexp_matches(i.message, '(raw\.[a-z_]+)#', 'g') AS t) AS actual
  FROM audit.data_quality_issue AS i
  JOIN audit.load_run AS lr ON lr.load_run_id = i.load_run_id
 WHERE lr.run_code = 'c_d2_0200' AND i.rule_code = 'conflicting_duplicate'
UNION ALL
-- The published fact keeps its original quantity.
SELECT 'final/fact_quantity_store_sales:sale:S-0123-0001:1', quantity::text
  FROM dw.fact_stock_movement
 WHERE origin_system_code = 'store_sales' AND origin_event_type = 'sale'
   AND origin_event_id = 'S-0123-0001' AND origin_line_id = '1';
