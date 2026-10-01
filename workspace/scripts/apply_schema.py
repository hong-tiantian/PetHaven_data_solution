"""Create every PetHaven schema object in one database.

Purpose
    Apply the numbered schema files, the source write procedures, the existing
    source jobs, the ETL routines and the reviewed reference mappings, in
    dependency order.

Prerequisites
    The Lab Environment is running (``docker compose up -d``).

Usage (inside the lab's python container)
    python /workspace/scripts/apply_schema.py --scenario case_1_baseline
        Recreates the isolated database pethaven_test_case_1_baseline and
        applies the schema. Only pethaven_test_* databases are ever dropped.

    python /workspace/scripts/apply_schema.py --database-url "<url>"
        Optional backup target (for example the team's Supabase project).
        Applies the schema into an EXISTING database without dropping
        anything, and refuses if any PetHaven schema already exists there.
        Not part of the tested lab workflow; see docs/supabase_backup.md.

Transaction
    Each file is applied in its own transaction and committed; a failing file
    stops the run with the error and leaves earlier files applied (the target
    is a disposable test database).

Rerun behaviour
    With --scenario the database is recreated from empty, so it is safe to
    rerun. With --database-url it refuses to run twice.
"""

from __future__ import annotations

import argparse
import sys

import pethaven_db as db

# Dependency order: schemas, tables, routines, then reference seed data.
SCHEMA_FILES = [
    "01_schemas.sql",
    "02_source_tables.sql",
    "03_audit_tables.sql",
    "04_raw_tables.sql",
    "05_reference_tables.sql",
    "06_staging_tables.sql",
    "07_warehouse_tables.sql",
    "08_reporting_objects.sql",
    "source_actions/store_sales_actions.sql",
    "source_actions/online_actions.sql",
    "source_actions/stock_actions.sql",
    "source_jobs/apply_local_movements.sql",
    "source_jobs/import_daily_transactions.sql",
    "source_jobs/create_midnight_snapshot.sql",
    "source_jobs/refresh_website_stock.sql",
    "etl/load_control.sql",
    "etl/extract_sources.sql",
    "etl/validate_sources.sql",
    "etl/prepare_staging.sql",
    "etl/load_warehouse.sql",
    "etl/save_report_observations.sql",
    "seed/reference_mappings.sql",
]

PROJECT_SCHEMAS = ("src_store_sales", "src_online", "src_stock", "raw", "ref", "stg", "dw", "rpt", "audit")


def apply_all(conn, verbose: bool = True) -> None:
    """Apply every schema file in order, one committed transaction per file."""
    for relative in SCHEMA_FILES:
        try:
            db.run_sql_file(conn, db.DB_DIR / relative)
            conn.commit()
        except Exception:
            conn.rollback()
            print(f"  FAILED while applying db/{relative}", file=sys.stderr)
            raise
        if verbose:
            print(f"  applied db/{relative}")


def assert_no_project_schemas(conn) -> None:
    """Raise if any PetHaven schema already exists (protects shared databases)."""
    with conn.cursor() as cur:
        cur.execute("SELECT nspname FROM pg_namespace WHERE nspname = ANY(%s)", (list(PROJECT_SCHEMAS),))
        existing = [row[0] for row in cur.fetchall()]
    conn.rollback()
    if existing:
        raise RuntimeError(
            "Refusing to apply: PetHaven schemas already exist in this database "
            f"({', '.join(existing)}). Nothing is dropped automatically.")


def prepare_test_database(scenario_code: str, verbose: bool = True) -> str:
    """Recreate the isolated database for a scenario and apply the schema."""
    database = db.test_database_name(scenario_code)
    db.recreate_test_database(database)
    conn = db.connect(database)
    try:
        apply_all(conn, verbose=verbose)
    finally:
        conn.close()
    return database


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--scenario", help="scenario code; recreates pethaven_test_<scenario>")
    target.add_argument("--database-url", help="existing non-lab database (backup target); never dropped")
    args = parser.parse_args()

    if args.scenario:
        database = prepare_test_database(args.scenario)
        print(f"Schema applied to isolated database {database}")
    else:
        conn = db.connect(dsn=args.database_url)
        try:
            assert_no_project_schemas(conn)
            apply_all(conn)
        finally:
            conn.close()
        print("Schema applied to the database given by --database-url")
    return 0


if __name__ == "__main__":
    sys.exit(main())
