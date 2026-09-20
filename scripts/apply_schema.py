"""Apply db/schema.sql to your Supabase database.

Usage:
    python scripts/apply_schema.py          # shows the target and asks first
    python scripts/apply_schema.py --yes    # no confirmation prompt

Needs DATABASE_URL in .env (Supabase dashboard -> Connect -> Session pooler).
The whole file runs in ONE transaction: if anything fails, nothing is created.
schema.sql is safe to re-run (CREATE ... IF NOT EXISTS).
"""
import os
import re
import sys
from pathlib import Path

import psycopg
from dotenv import load_dotenv
from psycopg.conninfo import conninfo_to_dict

ROOT = Path(__file__).resolve().parents[1]
SCHEMA_FILE = ROOT / "db" / "schema.sql"

load_dotenv(ROOT / ".env")

COUNT_TABLES = """
    select count(*) from information_schema.tables
    where table_schema = 'public'
      and table_type = 'BASE TABLE'
      and table_name ~ '^(src|mdm|gov)_'
"""


def main() -> int:
    url = os.getenv("DATABASE_URL")
    if not url:
        print("DATABASE_URL is missing. Copy it from Supabase (Connect -> Session pooler) into .env.")
        print("See .env.example for the format.")
        return 1
    if not SCHEMA_FILE.exists():
        print(f"Cannot find {SCHEMA_FILE}")
        return 1

    sql = SCHEMA_FILE.read_text(encoding="utf-8")
    expected = len(re.findall(r"^\s*create table if not exists", sql, flags=re.I | re.M))

    # Show where we are about to write (never print the password).
    try:
        target = conninfo_to_dict(url)
    except psycopg.ProgrammingError:
        print("DATABASE_URL is not a valid connection string. Check it for typos.")
        print("If your password has special characters (@ : / # ?), URL-encode them.")
        return 1
    print(f"Target: host={target.get('host')}  db={target.get('dbname')}  user={target.get('user')}")
    print(f"File:   {SCHEMA_FILE.relative_to(ROOT)}  ({expected} tables)")

    if "--yes" not in sys.argv:
        if input("Apply the schema to this database? [y/N] ").strip().lower() != "y":
            print("Cancelled. Nothing was changed.")
            return 0

    try:
        with psycopg.connect(url, connect_timeout=15) as conn:
            conn.execute(sql)  # committed when the block ends, rolled back on any error
            found = conn.execute(COUNT_TABLES).fetchone()[0]
    except psycopg.OperationalError as e:
        print(f"\nCould not connect: {str(e).strip()}")
        print("Check the password and host in DATABASE_URL. If the host starts with 'db.', it may be IPv6-only:")
        print("use the Session pooler connection string instead.")
        return 1
    except psycopg.Error as e:
        print(f"\nThe schema failed, so NOTHING was created (the whole run was rolled back):\n{str(e).strip()}")
        return 1

    print(f"\nDone. {found} tables with prefix src_ / mdm_ / gov_ now exist (this schema defines {expected}).")
    if found < expected:
        print("Fewer tables than expected: check the SQL Editor or re-run this script.")
    else:
        print("Next: python scripts/test_connection.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
