-- =============================================================================
-- seed/pre_cutoff_late_record.sql
-- Purpose: T25. A count correction effective on Day 1 at 10 pm is entered on
--          Day 2 at 2 am, after the midnight snapshot was produced. It is not
--          in that snapshot, and subtracting it after the cutoff would also be
--          wrong. Integration must flag reconciliation and give no quantity.
-- Prerequisites: Empty isolated scenario database with the schema applied.
-- Inputs: None (synthetic data; Day 1 = 16 Sep 2026, Day 2 = 17 Sep 2026).
-- Outputs: A succeeded run carrying a pre_cutoff_late_event warning.
-- Execution: python /workspace/scripts/run_scenario.py pre_cutoff_late_record
-- Rerun behaviour: Not rerunnable in the same database.
-- Business rules: Architecture_and_Data_Model.md 10.5.
-- Checks: tests/expected/pre_cutoff_late_record.csv (T25).
-- =============================================================================

-- @include base_sources.sql

-- @step d1_0100_opening_snapshot | Opening snapshot at Parramatta and Chatswood
CALL src_stock.bootstrap_opening_snapshot(
    'SNAP-20260916',
    '2026-09-16 00:00 Australia/Sydney',
    '2026-09-16 01:00 Australia/Sydney',
    '[{"sku": "PH-10231", "location_code": "STR-PAR", "quantity": 5},
      {"sku": "PH-10231", "location_code": "STR-CHA", "quantity": 8}]');

-- @step d2_0100_overnight_processing | Day 2, 1 am: import (nothing to import) and midnight snapshot
CALL src_stock.import_daily_transactions('2026-09-17 00:00 Australia/Sydney', '2026-09-17 01:00 Australia/Sydney');
CALL src_stock.create_midnight_snapshot('SNAP-20260917', '2026-09-17 00:00 Australia/Sydney',
    'SNAP-20260916', '2026-09-17 01:00 Australia/Sydney');

-- @step d2_0200_late_correction | Day 2, 2 am: a count correction effective Day 1 10 pm is entered (-2 at Parramatta)
CALL src_stock.record_adjustment('PH-10231', 'STR-PAR', -2, '2026-09-16 22:00 Australia/Sydney', 'count_correction',
    p_recorded_at => '2026-09-17 02:00 Australia/Sydney', p_movement_id => 'MV-ADJ-0901');
CALL src_stock.apply_local_movements('2026-09-17 02:00 Australia/Sydney');

-- @checkpoint l_d2_0300 | 2026-09-17 03:00 Australia/Sydney | Parramatta needs reconciliation; Chatswood is unaffected

-- @check chk_par_rc_0300 | 2026-09-17 03:00 Australia/Sydney | store-parramatta | [{"sku": "PH-10231", "quantity": 1}] | No sufficient/insufficient answer while reconciliation is required
