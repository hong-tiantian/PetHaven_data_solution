"""Load the UC1 synthetic data (db/seed_sources.sql) into your Supabase database.

Usage:
    python scripts/load_seed.py          # shows the target and asks first
    python scripts/load_seed.py --yes    # no confirmation prompt

Needs DATABASE_URL in .env (same as scripts/apply_schema.py) and the tables
from db/schema.sql. The seed file EMPTIES every src_ table and reloads it,
so it is safe to re-run. The whole run is ONE transaction: if anything
fails, nothing is changed.
"""
import os
import sys
from pathlib import Path

import psycopg
from dotenv import load_dotenv
from psycopg.conninfo import conninfo_to_dict

ROOT = Path(__file__).resolve().parents[1]
SEED_FILE = ROOT / "db" / "seed_sources.sql"

load_dotenv(ROOT / ".env")

TABLES = [
    "src_pos_stores", "src_pos_loyalty_members", "src_pos_sales", "src_pos_sale_lines",
    "src_digital_customers", "src_digital_pets", "src_digital_orders", "src_digital_order_lines",
    "src_grooming_clients", "src_grooming_pets", "src_grooming_services", "src_grooming_appointments",
]


def main() -> int:
    assume_yes = "--yes" in sys.argv[1:]

    url = os.getenv("DATABASE_URL")
    if not url:
        print("DATABASE_URL is missing. Copy it from Supabase (Connect -> Session pooler) into .env.")
        return 1
    if not SEED_FILE.exists():
        print(f"Cannot find {SEED_FILE}")
        return 1

    target = conninfo_to_dict(url)
    print(f"Target: host={target.get('host')}  db={target.get('dbname')}  user={target.get('user')}")
    print(f"File:   {SEED_FILE.relative_to(ROOT)}")
    print("This EMPTIES every src_ table and reloads the synthetic data.")
    if not assume_yes and input("Continue? [y/N] ").strip().lower() != "y":
        print("Cancelled. Nothing was changed.")
        return 0

    try:
        with psycopg.connect(url, connect_timeout=15) as conn:
            conn.execute(SEED_FILE.read_text(encoding="utf-8"))
            counts = [(t, conn.execute(f"select count(*) from public.{t}").fetchone()[0]) for t in TABLES]
    except psycopg.errors.UndefinedTable as e:
        print(f"\nA table is missing, so NOTHING was loaded. Run python scripts/apply_schema.py first.\n{e}")
        return 1
    except psycopg.Error as e:
        print(f"\nLoading failed, so NOTHING was changed (the whole run was rolled back):\n{str(e).strip()}")
        return 1

    print("\nLoaded:")
    for table, n in counts:
        print(f"  {table:<28} {n:>4} row(s)")
    print(f"  {'TOTAL':<28} {sum(n for _, n in counts):>4} row(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
