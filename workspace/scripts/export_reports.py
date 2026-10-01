"""Export the reporting outputs of executed scenarios to CSV files.

Purpose
    Save the three required reports, the simulated stock checks and the
    validation issues of each scenario database as scenario-named CSV files,
    for the written report and as evidence that survives a later rebuild.

Prerequisites
    The scenarios were executed (scripts/run_acceptance.py or run_scenario.py).

Usage (inside the lab's python container)
    python /workspace/scripts/export_reports.py                  # all scenarios
    python /workspace/scripts/export_reports.py --scenario case_1_baseline

Outputs
    workspace/reports/<scenario>/<output>.csv, overwritten on every export.

Transaction
    Read-only.
"""

from __future__ import annotations

import argparse
import csv
import sys

import pethaven_db as db
from run_acceptance import SCENARIOS

REPORTS_DIR = db.WORKSPACE / "reports"

# File name -> query. Every query reads saved results; nothing is recalculated.
OUTPUTS = {
    "1_availability_comparison": """
        SELECT checkpoint_code, observed_at, load_run_code, sku, product_name, location_code,
               website_available_quantity, calculated_on_hand_quantity, reserved_quantity,
               available_quantity, shortfall_quantity, availability_difference, difference_direction,
               opening_cutoff_at, website_snapshot_cutoff_at, website_copied_at,
               quality_status, website_quality_status
          FROM rpt.v_availability_comparison
         ORDER BY observed_at, checkpoint_code, sku, location_code""",
    "2_order_risk_and_cancellation": """
        SELECT checkpoint_code, observed_at, order_id, line_id, placed_at, sku, pickup_location_code,
               effective_status, requested_quantity, allocated_quantity, line_shortfall_quantity,
               is_at_risk, cancellation_reason, cancelled_at, is_stock_related_cancellation
          FROM rpt.v_order_risk_and_cancellation
         ORDER BY observed_at, checkpoint_code, placed_at, order_id, line_id""",
    "3a_data_update_delay": """
        SELECT event_kind, source_identity, event_detail, sku, location_code, occurred_at,
               source_recorded_at, first_load_run_code, scenario_published_at, simulated_delay,
               simulated_delay_label, extract_started_at, warehouse_loaded_at, published_at,
               actual_load_runtime
          FROM rpt.v_data_update_delay
         ORDER BY occurred_at, source_identity""",
    "3b_website_stock_age": """
        SELECT checkpoint_code, observed_at, website_copy_id, website_snapshot_cutoff_at,
               website_copied_at, website_basis_age, website_copy_age, website_copy_lag
          FROM rpt.v_website_stock_age
         ORDER BY observed_at, checkpoint_code""",
    "simulated_stock_checks": """
        SELECT c.check_code, c.observed_at, c.location_code, c.canonical_location_code,
               lr.run_code AS load_run_code, c.load_status, c.overall_result,
               l.sku, l.requested_quantity, l.available_quantity, l.line_result, l.line_quality_status
          FROM rpt.stock_check AS c
          JOIN rpt.stock_check_line AS l ON l.check_id = c.check_id
          JOIN audit.load_run AS lr ON lr.load_run_id = c.load_run_id
         ORDER BY c.observed_at, c.check_code, l.sku""",
    "load_runs_and_issues": """
        SELECT lr.run_code, lr.source_as_of_at, lr.status, lr.summary_error,
               i.rule_code, i.severity, i.source_reference, i.message
          FROM audit.load_run AS lr
          LEFT JOIN audit.data_quality_issue AS i ON i.load_run_id = lr.load_run_id
         ORDER BY lr.load_run_id, i.issue_id""",
}


def export(scenario: str) -> None:
    """Write every output of one scenario database to CSV."""
    target = REPORTS_DIR / scenario
    target.mkdir(parents=True, exist_ok=True)
    conn = db.connect(db.test_database_name(scenario))
    try:
        for name, query in OUTPUTS.items():
            with conn.cursor() as cur:
                cur.execute(query)
                header = [column.name for column in cur.description]
                rows = cur.fetchall()
            with open(target / f"{name}.csv", "w", newline="", encoding="utf-8") as handle:
                writer = csv.writer(handle)
                writer.writerow(header)
                writer.writerows(rows)
            print(f"  {scenario}/{name}.csv ({len(rows)} rows)")
        conn.rollback()
    finally:
        conn.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--scenario", action="append", choices=SCENARIOS)
    args = parser.parse_args()
    for scenario in args.scenario or SCENARIOS:
        export(scenario)
    return 0


if __name__ == "__main__":
    sys.exit(main())
