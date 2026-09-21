"""Apply db/schema.sql to your Supabase database.

Usage:
    python scripts/apply_schema.py            # shows the target and asks first
    python scripts/apply_schema.py --yes      # no confirmation prompt
    python scripts/apply_schema.py --reset    # FIRST delete every table and view
                                              # from an older schema version, then apply

Needs DATABASE_URL in .env (Supabase dashboard -> Connect -> Session pooler).
The whole run is ONE transaction: if anything fails, nothing is changed.
schema.sql is safe to re-run (CREATE ... IF NOT EXISTS).

--reset deletes tables named src_*, mdm_*, gov_* and views named v_* in the
public schema, WITH their data. Use it only on a development database, for
example to remove the tables of the earlier 33-table version.
"""
import os
import re
import sys
from pathlib import Path

import psycopg
from dotenv import load_dotenv
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict

ROOT = Path(__file__).resolve().parents[1]
SCHEMA_FILE = ROOT / "db" / "schema.sql"

load_dotenv(ROOT / ".env")

# Objects this project has ever created (old versions used mdm_, gov_ and v_ too).
OLD_OBJECTS = """
    select table_name, table_type from information_schema.tables
    where table_schema = 'public'
      and (table_name ~ '^(src|mdm|gov|v)_' or table_name = 'animals')
    order by table_type, table_name
"""


def list_project_objects(conn):
    """Return (tables, views) of this project that exist in the public schema."""
    rows = conn.execute(OLD_OBJECTS).fetchall()
    tables = [name for name, kind in rows if kind == "BASE TABLE"]
    views = [name for name, kind in rows if kind == "VIEW"]
    return tables, views


def row_count(conn, table):
    query = sql.SQL("select count(*) from public.{}").format(sql.Identifier(table))
    return conn.execute(query).fetchone()[0]


def drop_all(conn, tables, views):
    for view in views:
        conn.execute(sql.SQL("drop view if exists public.{} cascade").format(sql.Identifier(view)))
    for table in tables:
        conn.execute(sql.SQL("drop table if exists public.{} cascade").format(sql.Identifier(table)))


def main() -> int:
    args = sys.argv[1:]
    reset = "--reset" in args
    assume_yes = "--yes" in args

    url = os.getenv("DATABASE_URL")
    if not url:
        print("DATABASE_URL is missing. Copy it from Supabase (Connect -> Session pooler) into .env.")
        print("See .env.example for the format.")
        return 1
    if not SCHEMA_FILE.exists():
        print(f"Cannot find {SCHEMA_FILE}")
        return 1

    schema_sql = SCHEMA_FILE.read_text(encoding="utf-8")
    expected_tables = re.findall(r"^\s*create table if not exists\s+public\.(\w+)", schema_sql, flags=re.I | re.M)

    # Show where we are about to write (never print the password).
    try:
        target = conninfo_to_dict(url)
    except psycopg.ProgrammingError:
        print("DATABASE_URL is not a valid connection string. Check it for typos.")
        print("If your password has special characters (@ : / # ?), URL-encode them.")
        return 1
    print(f"Target: host={target.get('host')}  db={target.get('dbname')}  user={target.get('user')}")
    print(f"File:   {SCHEMA_FILE.relative_to(ROOT)}  ({len(expected_tables)} tables)")

    try:
        with psycopg.connect(url, connect_timeout=15) as conn:
            old_tables, old_views = ([], [])
            if reset:
                old_tables, old_views = list_project_objects(conn)
                if old_tables or old_views:
                    print("\n--reset will DELETE these, including all their data:")
                    for table in old_tables:
                        print(f"  table {table:<32} {row_count(conn, table)} row(s)")
                    for view in old_views:
                        print(f"  view  {view}")
                    conn.commit()  # end the read-only transaction before we wait for the user
                    if not assume_yes:
                        if input("\nType 'reset' to delete them and apply the schema: ").strip() != "reset":
                            print("Cancelled. Nothing was changed.")
                            return 0
                else:
                    print("\n--reset: no old tables or views found, nothing to delete.")
                    conn.commit()
                    if not assume_yes and input("Apply the schema to this database? [y/N] ").strip().lower() != "y":
                        print("Cancelled. Nothing was changed.")
                        return 0
            else:
                # Tables from an older schema version would make CREATE ... IF NOT EXISTS
                # skip tables that have the same name but other columns. Stop with a clear message.
                present_now, views_now = list_project_objects(conn)
                conn.commit()
                leftovers = sorted(t for t in present_now if t not in expected_tables) + sorted(views_now)
                if leftovers:
                    print("\nThis database still has objects from an older schema version:")
                    print("  " + ", ".join(leftovers))
                    print("Nothing was changed. Tables with the same name as a new table may also have old columns.")
                    print("On a development database with no real data, run:  python scripts/apply_schema.py --reset")
                    return 1
                if not assume_yes and input("Apply the schema to this database? [y/N] ").strip().lower() != "y":
                    print("Cancelled. Nothing was changed.")
                    return 0

            # One transaction: committed when the block ends, rolled back on any error.
            if reset:
                drop_all(conn, old_tables, old_views)
            conn.execute(schema_sql)
            present, _views = list_project_objects(conn)
    except psycopg.OperationalError as e:
        print(f"\nCould not connect: {str(e).strip()}")
        print("Check the password and host in DATABASE_URL. If the host starts with 'db.', it may be IPv6-only:")
        print("use the Session pooler connection string instead.")
        return 1
    except psycopg.Error as e:
        print(f"\nThe schema failed, so NOTHING was changed (the whole run was rolled back):\n{str(e).strip()}")
        return 1

    found = len([t for t in present if t in expected_tables])
    print(f"\nDone. {found} of {len(expected_tables)} tables from db/schema.sql now exist.")
    if found < len(expected_tables):
        print("Fewer tables than expected: re-run this script or check the Supabase SQL Editor.")
    else:
        print("Next: python scripts/test_connection.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
