"""Run the integration pipeline for one checkpoint and save report results.

Purpose
    Orchestrate one load run in the transaction order required by
    Architecture_and_Data_Model.md section 12.2, and save report observations
    or a simulated stock check. All business logic is in the SQL routines;
    this module only decides which routine runs in which transaction.

Load sequence (one load run)
    1. audit.start_load_run                              -> commit
    2. raw.extract_sources   (REPEATABLE READ snapshot)  -> commit (raw evidence)
    3. stg.validate_sources + stg.prepare_staging        -> commit (issues, staging)
    4. any error issue?  yes -> audit.reject_load_run    -> commit
                          no  -> dw.load_warehouse        -> commit (publication)
    5. extraction/publication exception -> rollback, then audit.fail_load_run

Usage (inside the lab's python container), against an existing scenario
database, for manual exploration:
    python /workspace/scripts/run_pipeline.py --scenario case_1_baseline \
        --run-code manual_1600 --as-of "2026-09-16 16:00 Australia/Sydney" --observe
"""

from __future__ import annotations

import argparse
import json
import sys

import pethaven_db as db


def run_load(conn, scenario_code: str, run_code: str, as_of: str, options: dict | None = None):
    """Run one complete load. Returns (load_run_id, status, message).

    options:
        skip_tables: list of "system.table" names to omit (test hook, T24)
        fault:       "fail_after_facts" to fail publication (test hook, T21)
    """
    options = options or {}
    cur = conn.cursor()

    cur.execute("SELECT audit.start_load_run(%s, %s, %s::timestamptz, %s)",
                (scenario_code, run_code, as_of, db.CODE_REVISION))
    load_run_id = cur.fetchone()[0]
    conn.commit()

    def fail(message: str):
        conn.rollback()
        cur.execute("CALL audit.fail_load_run(%s, %s)", (load_run_id, message))
        conn.commit()
        return load_run_id, "failed", message

    # One consistent read of all sources (single lab database).
    try:
        cur.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        cur.execute("CALL raw.extract_sources(%s, %s::text[])",
                    (load_run_id, list(options.get("skip_tables", []))))
        conn.commit()
    except Exception as exc:  # extraction error: nothing partial is kept
        return fail(f"extraction failed: {exc}".strip())

    try:
        cur.execute("CALL stg.validate_sources(%s)", (load_run_id,))
        cur.execute("CALL stg.prepare_staging(%s)", (load_run_id,))
        conn.commit()
    except Exception as exc:
        return fail(f"validation failed: {exc}".strip())

    cur.execute("SELECT count(*) FROM audit.data_quality_issue WHERE load_run_id = %s AND severity = 'error'",
                (load_run_id,))
    errors = cur.fetchone()[0]
    if errors:
        cur.execute("CALL audit.reject_load_run(%s)", (load_run_id,))
        conn.commit()
        return load_run_id, "rejected", f"{errors} validation error(s)"

    try:
        cur.execute("CALL dw.load_warehouse(%s, %s)", (load_run_id, options.get("fault")))
        conn.commit()
    except Exception as exc:  # publication rolled back as a whole
        return fail(f"publication failed: {exc}".strip())

    return load_run_id, "succeeded", ""


def save_observation(conn, scenario_code: str, checkpoint_code: str, observed_at: str, load_run_id: int):
    """Save a ready report run. Returns (status, message); records a failed report run on error."""
    cur = conn.cursor()
    try:
        cur.execute("CALL rpt.save_report_observations(%s, %s, %s::timestamptz, %s, %s)",
                    (scenario_code, checkpoint_code, observed_at, load_run_id, db.CALCULATION_REVISION))
        conn.commit()
        return "ready", ""
    except Exception as exc:
        conn.rollback()
        cur.execute(
            "INSERT INTO rpt.report_run (load_run_id, scenario_code, checkpoint_code, observed_at, status, calculation_revision) "
            "VALUES (%s, %s, %s, %s::timestamptz, 'failed', %s)",
            (load_run_id, scenario_code, checkpoint_code, observed_at, db.CALCULATION_REVISION))
        conn.commit()
        return "failed", str(exc).strip()


def record_check(conn, scenario_code: str, check_code: str, observed_at: str, load_run_id: int,
                 location_code: str, request: list):
    """Run and save one simulated stock check. Returns the overall result."""
    cur = conn.cursor()
    cur.execute("CALL rpt.record_stock_check(%s, %s, %s::timestamptz, %s, %s, %s::jsonb)",
                (scenario_code, check_code, observed_at, load_run_id, location_code, json.dumps(request)))
    cur.execute("SELECT overall_result FROM rpt.stock_check WHERE scenario_code = %s AND check_code = %s",
                (scenario_code, check_code))
    result = cur.fetchone()[0]
    conn.commit()
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--scenario", required=True, help="scenario code (database pethaven_test_<scenario>)")
    parser.add_argument("--run-code", required=True)
    parser.add_argument("--as-of", required=True, help='e.g. "2026-09-16 16:00 Australia/Sydney"')
    parser.add_argument("--observe", action="store_true", help="save report observations after a successful load")
    args = parser.parse_args()

    conn = db.connect(db.test_database_name(args.scenario))
    try:
        load_run_id, status, message = run_load(conn, args.scenario, args.run_code, args.as_of)
        print(f"load run {load_run_id} ({args.run_code}): {status} {message}")
        if args.observe and status == "succeeded":
            print("report run:", *save_observation(conn, args.scenario, args.run_code, args.as_of, load_run_id))
    finally:
        conn.close()
    return 0 if status == "succeeded" else 1


if __name__ == "__main__":
    sys.exit(main())
