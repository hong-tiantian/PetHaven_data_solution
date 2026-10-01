"""Execute one scenario file step by step.

Purpose
    A scenario file in db/seed/ is plain SQL divided by directive comments.
    This runner executes the business actions in order and, at each
    checkpoint, runs the integration pipeline so that sources are always
    extracted as they were at that simulated time (Arch 9.1).

Directives (one per line, fields separated by '|')
    -- @include <file>                                   insert another seed file here
    -- @focus <SKU>@<LOCATION>                           pair to print at checkpoints
    -- @step <code> | <description>                      SQL below runs as ONE transaction
    -- @expect_error <code> | <description>              SQL below MUST fail (rolled back)
    -- @checkpoint <code> | <time> | <description> [| <JSON options>]
                                                         load as of <time>, then save
                                                         report observations at <time>
    -- @observe <code> | <time> | <load code> | <description>
                                                         save observations at <time> using an
                                                         earlier or later load (reconstruction)
    -- @check <code> | <time> | <pickup code> | <JSON request> | <description>
                                                         simulated stock check with the most
                                                         recent load; creates no order

Usage (inside the lab's python container)
    python /workspace/scripts/run_scenario.py case_1_baseline
        Recreates pethaven_test_case_1_baseline, applies the schema and runs it.
    python /workspace/scripts/run_scenario.py case_1_baseline --pause
        Same, pausing after every checkpoint (live demonstration).

Transaction
    One transaction per @step / @expect_error; loads follow run_pipeline.py.

Rerun behaviour
    Always starts from a freshly recreated isolated database.

Failure behaviour
    An unexpected SQL error, or an @expect_error step that succeeds, stops the
    scenario with ScenarioError. Rejected or failed LOADS are not errors: some
    scenarios require them, and the acceptance checks verify their status.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

import apply_schema
import pethaven_db as db
import run_pipeline

DIRECTIVE = re.compile(r"^--\s*@(\w+)\s*(.*)$")


class ScenarioError(RuntimeError):
    """The scenario could not be executed as written."""


@dataclass
class Block:
    kind: str
    fields: list[str]
    source: str
    sql_lines: list[str] = field(default_factory=list)

    @property
    def sql(self) -> str:
        return "\n".join(self.sql_lines).strip()

    @property
    def has_sql(self) -> bool:
        """True when the block holds statements, not only comments."""
        return any(line.strip() and not line.strip().startswith("--") for line in self.sql_lines)


def parse(path: Path, seen: tuple = ()) -> tuple[list[Block], list[str]]:
    """Parse a scenario file (expanding @include) into blocks and focus pairs."""
    if path.name in seen:
        raise ScenarioError(f"Recursive @include of {path.name}")
    blocks: list[Block] = []
    focus: list[str] = []
    current: Block | None = None
    for line in path.read_text(encoding="utf-8").splitlines():
        match = DIRECTIVE.match(line.strip())
        if match:
            kind, rest = match.group(1), match.group(2)
            fields = [part.strip() for part in rest.split("|")]
            if kind == "include":
                child_blocks, child_focus = parse(db.SEED_DIR / fields[0], seen + (path.name,))
                blocks.extend(child_blocks)
                focus.extend(child_focus)
                current = None
            elif kind == "focus":
                focus.append(fields[0])
                current = None
            elif kind in {"step", "expect_error", "checkpoint", "observe", "check"}:
                current = Block(kind, fields, path.name)
                blocks.append(current)
            else:
                raise ScenarioError(f"{path.name}: unknown directive @{kind}")
        elif current is not None:
            current.sql_lines.append(line)
    for block in blocks:
        if block.kind in {"step", "expect_error"} and not block.has_sql:
            raise ScenarioError(f"{block.source}: @{block.kind} {block.fields[0]} has no SQL")
        if block.kind not in {"step", "expect_error"} and block.has_sql:
            raise ScenarioError(f"{block.source}: SQL found after @{block.kind} {block.fields[0]}")
    return blocks, focus


def print_focus(conn, scenario_code: str, checkpoint_code: str, focus: list[str]) -> None:
    """Print the saved comparison for the focus pairs (or every pair)."""
    cur = conn.cursor()
    cur.execute(
        """SELECT sku || '@' || location_code, website_available_quantity, calculated_on_hand_quantity,
                  reserved_quantity, available_quantity, shortfall_quantity, quality_status
             FROM rpt.v_availability_comparison
            WHERE scenario_code = %s AND checkpoint_code = %s
            ORDER BY sku, location_code""",
        (scenario_code, checkpoint_code))
    rows = [row for row in cur.fetchall() if not focus or row[0] in focus]
    conn.commit()
    for pair, website, on_hand, reserved, available, shortfall, quality in rows:
        print(f"      {pair:<20} website={db.fmt(website):>4}  on_hand={db.fmt(on_hand):>4}  "
              f"reserved={db.fmt(reserved):>3}  available={db.fmt(available):>4}  "
              f"shortfall={db.fmt(shortfall):>3}  {quality}")


def run(scenario_code: str, pause: bool = False, verbose: bool = True) -> str:
    """Recreate the scenario database, apply the schema and execute the scenario.

    Returns the database name. Raises ScenarioError on an unexpected failure.
    """
    blocks, focus = parse(db.SEED_DIR / f"{scenario_code}.sql")
    database = apply_schema.prepare_test_database(scenario_code, verbose=False)
    conn = db.connect(database)
    cur = conn.cursor()
    loads: dict[str, tuple[int, str]] = {}
    last_load: tuple[int, str] | None = None

    def log_step(order: int, block: Block, status: str, error: str | None = None) -> None:
        description = block.fields[-1] if len(block.fields) > 1 else None
        cur.execute(
            "INSERT INTO audit.scenario_step (scenario_code, step_order, step_kind, step_code, description, status, error_message) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s)",
            (scenario_code, order, block.kind, block.fields[0], description, status, error))
        conn.commit()

    def say(text: str) -> None:
        if verbose:
            print(text)

    try:
        say(f"== Scenario {scenario_code} (database {database})")
        for order, block in enumerate(blocks, start=1):
            code = block.fields[0]
            if block.kind == "step":
                say(f"  step  {code}: {block.fields[1] if len(block.fields) > 1 else ''}")
                try:
                    cur.execute(block.sql)
                    conn.commit()
                except Exception as exc:
                    conn.rollback()
                    raise ScenarioError(f"step {code} failed: {exc}".strip()) from exc
                log_step(order, block, "succeeded")

            elif block.kind == "expect_error":
                say(f"  step  {code} (must be rejected): {block.fields[1] if len(block.fields) > 1 else ''}")
                try:
                    cur.execute(block.sql)
                except Exception as exc:
                    conn.rollback()
                    message = str(exc).strip().splitlines()[0]
                    say(f"        rejected as required: {message}")
                    log_step(order, block, "expected_error", message)
                else:
                    conn.rollback()
                    raise ScenarioError(f"step {code} was expected to fail but succeeded")

            elif block.kind == "checkpoint":
                at, description = block.fields[1], block.fields[2]
                options = json.loads(block.fields[3]) if len(block.fields) > 3 and block.fields[3] else {}
                load_run_id, status, message = run_pipeline.run_load(conn, scenario_code, code, at, options)
                loads[code] = (load_run_id, at)
                last_load = (load_run_id, at)
                say(f"  CHECKPOINT {code} @ {at} - {description}")
                say(f"      load run {load_run_id}: {status}{' (' + message.splitlines()[0] + ')' if message else ''}")
                if status == "succeeded":
                    report_status, report_message = run_pipeline.save_observation(
                        conn, scenario_code, code, at, load_run_id)
                    if report_status != "ready":
                        raise ScenarioError(f"report for {code} failed: {report_message}")
                    if verbose:
                        print_focus(conn, scenario_code, code, focus)
                if pause:
                    input("      -- press Enter to continue --")

            elif block.kind == "observe":
                at, load_code, description = block.fields[1], block.fields[2], block.fields[3]
                if load_code not in loads:
                    raise ScenarioError(f"@observe {code} refers to unknown load {load_code}")
                load_run_id, _ = loads[load_code]
                report_status, report_message = run_pipeline.save_observation(
                    conn, scenario_code, code, at, load_run_id)
                if report_status != "ready":
                    raise ScenarioError(f"observation {code} failed: {report_message}")
                say(f"  OBSERVE {code} @ {at} using load {load_code} - {description}")
                if verbose:
                    print_focus(conn, scenario_code, code, focus)
                if pause:
                    input("      -- press Enter to continue --")

            elif block.kind == "check":
                at, location, request_text, description = block.fields[1:5]
                if last_load is None:
                    raise ScenarioError(f"@check {code} has no preceding load")
                result = run_pipeline.record_check(
                    conn, scenario_code, code, at, last_load[0], location, json.loads(request_text))
                say(f"  CHECK {code} @ {at} at {location} {request_text} -> {result.upper()}  ({description})")
                if pause:
                    input("      -- press Enter to continue --")
    finally:
        conn.close()
    return database


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("scenario", help="scenario file name in db/seed without .sql, e.g. case_1_baseline")
    parser.add_argument("--pause", action="store_true", help="pause after each checkpoint (demonstration)")
    args = parser.parse_args()
    try:
        database = run(args.scenario, pause=args.pause)
    except ScenarioError as exc:
        print(f"SCENARIO FAILED: {exc}", file=sys.stderr)
        return 1
    print(f"Scenario {args.scenario} finished. Browse database {database} in CloudBeaver (http://localhost:8978).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
