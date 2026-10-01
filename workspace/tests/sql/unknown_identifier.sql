-- =============================================================================
-- tests/sql/unknown_identifier.sql
-- Purpose: Scenario-specific actual values for unknown_identifier (T14).
-- Prerequisites: seed/unknown_identifier.sql executed in this database.
-- Outputs: Rows (check_name, actual) compared with tests/expected/unknown_identifier.csv.
-- Execution: scripts/run_acceptance.py, after tests/sql/common_checks.sql.
-- Transaction: Read-only.
-- =============================================================================

SELECT 'final/sale_S-0123-0901_mapped_sku' AS check_name, p.sku AS actual
  FROM dw.fact_stock_movement AS f
  JOIN dw.dim_product AS p ON p.product_key = f.product_key
 WHERE f.origin_system_code = 'store_sales' AND f.origin_event_id = 'S-0123-0901'
UNION ALL
SELECT 'final/mapping_change_rows', count(*)::text FROM audit.mapping_change;
