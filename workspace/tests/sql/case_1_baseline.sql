-- =============================================================================
-- tests/sql/case_1_baseline.sql
-- Purpose: Scenario-specific actual values for case_1_baseline (T08, T22, T23).
-- Prerequisites: seed/case_1_baseline.sql executed in this database.
-- Outputs: Rows (check_name, actual) compared with tests/expected/case_1_baseline.csv.
-- Execution: scripts/run_acceptance.py, after tests/sql/common_checks.sql.
-- Transaction: Read-only.
-- =============================================================================

WITH day2_load AS (
    SELECT load_run_id FROM audit.load_run WHERE run_code = 'cp_d2_0100'
),
sale_event AS (
    SELECT * FROM rpt.v_data_update_delay
     WHERE source_identity = 'store_sales:sale:S-0123-0001:1'
)
-- T08: four Parramatta sale lines are four facts, even after central imported them.
SELECT 'cp_d2_0100/store_sale_facts_for_parramatta_sales' AS check_name,
       count(*)::text AS actual
  FROM dw.fact_stock_movement AS f
  JOIN dw.dim_location AS l ON l.location_key = f.location_key
 WHERE f.movement_type = 'store_sale' AND l.location_code = 'STR-PAR'
   AND f.first_load_run_id IN (SELECT load_run_id FROM audit.load_run WHERE status = 'succeeded'
                                  AND publication_sequence <= (SELECT publication_sequence FROM audit.load_run
                                                                WHERE run_code = 'cp_d2_0100'))
UNION ALL
-- T08: the central copies were attached to existing facts as duplicates.
SELECT 'cp_d2_0100/central_import_rows_linked_as_duplicates',
       count(*)::text
  FROM audit.record_lineage AS g
  JOIN raw.stock_stock_movement AS m ON m.raw_record_id = g.raw_record_id
 WHERE g.load_run_id = (SELECT load_run_id FROM day2_load)
   AND g.raw_table_name = 'raw.stock_stock_movement'
   AND g.disposition = 'duplicate'
   AND m.origin_system_code = 'store_sales'
   AND m.location_code = 'STR-PAR'
UNION ALL
SELECT 'final/store_sale_facts_total', count(*)::text
  FROM dw.fact_stock_movement WHERE movement_type = 'store_sale'
UNION ALL
-- T22: rerunning the 1 am import and hourly job applied nothing twice.
SELECT 'final/central_store_sale_movements', count(*)::text
  FROM src_stock.stock_movement WHERE origin_system_code = 'store_sales'
UNION ALL
SELECT 'final/central_movement_applications', count(*)::text
  FROM src_stock.movement_application
UNION ALL
SELECT 'final/central_current_on_hand_PH-10231@STR-PAR', on_hand_quantity::text
  FROM src_stock.stock_on_hand WHERE sku = 'PH-10231' AND location_code = 'STR-PAR'
UNION ALL
-- T23: event timing for the first till sale.
SELECT 'event/store_sales:sale:S-0123-0001:1/occurred_at',
       to_char(occurred_at AT TIME ZONE 'Australia/Sydney', 'YYYY-MM-DD HH24:MI') FROM sale_event
UNION ALL
SELECT 'event/store_sales:sale:S-0123-0001:1/source_recorded_at',
       to_char(source_recorded_at AT TIME ZONE 'Australia/Sydney', 'YYYY-MM-DD HH24:MI') FROM sale_event
UNION ALL
SELECT 'event/store_sales:sale:S-0123-0001:1/scenario_published_at',
       to_char(scenario_published_at AT TIME ZONE 'Australia/Sydney', 'YYYY-MM-DD HH24:MI') FROM sale_event
UNION ALL
SELECT 'event/store_sales:sale:S-0123-0001:1/simulated_delay', simulated_delay::text FROM sale_event
UNION ALL
SELECT 'event/store_sales:sale:S-0123-0001:1/warehouse_loaded_at_recorded',
       (warehouse_loaded_at IS NOT NULL AND published_at IS NOT NULL)::text FROM sale_event;
