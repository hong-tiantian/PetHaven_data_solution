-- =============================================================================
-- tests/sql/movement_checks.sql
-- Purpose: Scenario-specific actual values for movement_checks (T05, T07, T26).
-- Prerequisites: seed/movement_checks.sql executed in this database.
-- Outputs: Rows (check_name, actual) compared with tests/expected/movement_checks.csv.
-- Execution: scripts/run_acceptance.py, after tests/sql/common_checks.sql.
-- Transaction: Read-only.
-- =============================================================================

-- T05: placement and cancellation are both kept in history.
SELECT 'final/W-3001_status_events' AS check_name, count(*)::text AS actual
  FROM dw.fact_order_status_event WHERE order_id = 'W-3001'
UNION ALL
-- T26: the rejected correction added nothing to the source history.
SELECT 'final/W-3001_status_events_after_rejected_correction', count(*)::text
  FROM src_online.order_status_history WHERE order_id = 'W-3001'
UNION ALL
-- T07: one dispatch and one receipt fact; the transfer line itself adds none.
SELECT 'final/transfer_movement_facts_TR-7001', count(*)::text
  FROM dw.fact_stock_movement WHERE transfer_id = 'TR-7001'
UNION ALL
-- T26: the original adjustment remains and the reversal points at it.
SELECT 'final/adjustment_facts_PH-20455@DC-MOO', count(*)::text
  FROM dw.fact_stock_movement AS f
  JOIN dw.dim_product AS p ON p.product_key = f.product_key
  JOIN dw.dim_location AS l ON l.location_key = f.location_key
 WHERE f.movement_type = 'adjustment' AND p.sku = 'PH-20455' AND l.location_code = 'DC-MOO'
UNION ALL
SELECT 'final/reversal_references_adjustment',
       EXISTS (
           SELECT 1
             FROM dw.fact_stock_movement AS r
             JOIN dw.fact_stock_movement AS o ON o.movement_key = r.reverses_movement_key
            WHERE r.origin_event_id = 'MV-REV-0001'
              AND o.origin_event_id = 'MV-ADJ-0001'
              AND r.quantity = -o.quantity)::text;
