"""One-command reproducible acceptance run for the PetHaven prototype.

Purpose
    For every scenario: recreate its isolated empty database on the lab
    server, create all schemas and routines, load the synthetic data, run the
    simulated business day(s) with the existing schedules, run the ETL at each
    checkpoint, then compare the saved results with the FIXED expected values
    in tests/expected/<scenario>.csv. The expected values were written from
    the Spec before the calculations were implemented and never reuse them.

Usage (from the repository root on the host)
    docker compose exec python python /workspace/scripts/run_acceptance.py
    docker compose exec python python /workspace/scripts/run_acceptance.py --scenario case_1_baseline

Outputs
    * A table per scenario: test ID, check, expected, actual, PASS/FAIL/SKIP.
    * tests/results/acceptance_results.csv and acceptance_summary.md.
    * Exit code 0 only if every check passed; 1 if any check failed or was
      skipped (a check is SKIPPED when its scenario could not be executed).

Safety
    Only pethaven_test_* databases on the local lab server are recreated
    (see pethaven_db.py). The lab's own database and any shared database are
    never reset. The test databases are kept after the run for inspection in
    CloudBeaver (http://localhost:8978).
"""

from __future__ import annotations

import argparse
import csv
import sys
from datetime import datetime
from pathlib import Path

import pethaven_db as db
import run_scenario

# Baseline and improved Case 1 run in separate databases (Arch 14.1).
SCENARIOS = [
    "case_1_baseline",
    "case_1_improved",
    "case_2",
    "movement_checks",
    "unknown_identifier",
    "conflicting_duplicate",
    "failed_publication",
    "source_completeness",
    "pre_cutoff_late_record",
]

RESULTS_DIR = db.TESTS_DIR / "results"


def read_expected(scenario: str) -> list[dict]:
    """Read the fixed expected values for one scenario."""
    with open(db.TESTS_DIR / "expected" / f"{scenario}.csv", newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    names = [row["check_name"] for row in rows]
    duplicates = {name for name in names if names.count(name) > 1}
    if duplicates:
        raise ValueError(f"{scenario}.csv repeats check names: {sorted(duplicates)}")
    return rows


def read_actual(scenario: str) -> dict[str, str]:
    """Run the read-only check queries and return {check_name: actual}."""
    conn = db.connect(db.test_database_name(scenario))
    actual: dict[str, str] = {}
    try:
        files = [db.TESTS_DIR / "sql" / "common_checks.sql"]
        specific = db.TESTS_DIR / "sql" / f"{scenario}.sql"
        if specific.exists():
            files.append(specific)
        for path in files:
            with conn.cursor() as cur:
                cur.execute(path.read_text(encoding="utf-8"))
                for check_name, value in cur.fetchall():
                    if check_name in actual and actual[check_name] != db.fmt(value):
                        raise ValueError(f"check {check_name} produced two different values")
                    actual[check_name] = db.fmt(value)
            conn.rollback()
    finally:
        conn.close()
    return actual


def evaluate(scenario: str, verbose: bool) -> list[dict]:
    """Execute one scenario and compare every expected check."""
    expected = read_expected(scenario)
    results: list[dict] = []
    try:
        run_scenario.run(scenario, verbose=verbose)
        actual = read_actual(scenario)
        execution_error = None
    except Exception as exc:  # the scenario itself failed; its checks are skipped
        actual = {}
        execution_error = str(exc).strip().splitlines()[0]

    results.append({
        "scenario": scenario, "test_id": "RUN", "check_name": "scenario executed",
        "expected": "completed", "actual": "completed" if execution_error is None else execution_error,
        "status": "PASS" if execution_error is None else "FAIL", "spec_reference": "",
    })
    for row in expected:
        if execution_error is not None:
            value, status = "not executed", "SKIP"
        else:
            value = actual.get(row["check_name"], "<not produced>")
            status = "PASS" if value == row["expected"].strip() else "FAIL"
        results.append({
            "scenario": scenario, "test_id": row["test_id"], "check_name": row["check_name"],
            "expected": row["expected"].strip(), "actual": value, "status": status,
            "spec_reference": row["spec_reference"],
        })
    return results


def print_table(results: list[dict]) -> None:
    """Print one scenario's results as an aligned table."""
    width = max(len(r["check_name"]) for r in results)
    print(f"\n  {'ID':<4} {'check':<{width}}  {'expected':<20} {'actual':<20} status")
    for r in results:
        print(f"  {r['test_id']:<4} {r['check_name']:<{width}}  {r['expected']:<20} {r['actual']:<20} {r['status']}")


def write_outputs(results: list[dict], started: datetime) -> None:
    """Write the CSV result file and a Markdown summary."""
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    with open(RESULTS_DIR / "acceptance_results.csv", "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(results[0].keys()))
        writer.writeheader()
        writer.writerows(results)

    lines = [
        "# Acceptance results",
        "",
        f"Run started {started:%Y-%m-%d %H:%M:%S} (container clock). Generated by scripts/run_acceptance.py.",
        "",
        "| Test | Scenario | Checks | PASS | FAIL | SKIP |",
        "| --- | --- | ---: | ---: | ---: | ---: |",
    ]
    keys = sorted({(r["test_id"], r["scenario"]) for r in results}, key=lambda k: (k[0] == "RUN", k[0], k[1]))
    for test_id, scenario in keys:
        group = [r for r in results if r["test_id"] == test_id and r["scenario"] == scenario]
        counts = {s: sum(1 for r in group if r["status"] == s) for s in ("PASS", "FAIL", "SKIP")}
        lines.append(f"| {test_id} | {scenario} | {len(group)} | {counts['PASS']} | {counts['FAIL']} | {counts['SKIP']} |")
    problems = [r for r in results if r["status"] != "PASS"]
    lines += ["", "## Checks that did not pass", ""]
    if problems:
        lines += ["| Scenario | Test | Check | Expected | Actual | Status |", "| --- | --- | --- | --- | --- | --- |"]
        lines += [f"| {r['scenario']} | {r['test_id']} | {r['check_name']} | {r['expected']} | {r['actual']} | {r['status']} |"
                  for r in problems]
    else:
        lines.append("None.")
    (RESULTS_DIR / "acceptance_summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--scenario", action="append", choices=SCENARIOS, help="run only this scenario (repeatable)")
    parser.add_argument("--quiet", action="store_true", help="do not print scenario steps")
    args = parser.parse_args()

    started = datetime.now()
    all_results: list[dict] = []
    for scenario in args.scenario or SCENARIOS:
        results = evaluate(scenario, verbose=not args.quiet)
        print_table(results)
        all_results.extend(results)

    write_outputs(all_results, started)
    totals = {s: sum(1 for r in all_results if r["status"] == s) for s in ("PASS", "FAIL", "SKIP")}
    print(f"\nTOTAL: {len(all_results)} checks - PASS {totals['PASS']}, FAIL {totals['FAIL']}, SKIP {totals['SKIP']}")
    print(f"Results written to {RESULTS_DIR / 'acceptance_results.csv'} and acceptance_summary.md")
    return 0 if totals["FAIL"] == 0 and totals["SKIP"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
