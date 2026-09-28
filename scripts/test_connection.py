"""Check that your .env credentials work.

Usage:  python scripts/test_connection.py [table_name]
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from postgrest.exceptions import APIError  # noqa: E402

from src.db import get_client  # noqa: E402


def main() -> None:
    table = sys.argv[1] if len(sys.argv) > 1 else "src_grooming_services"
    client = get_client()
    try:
        res = client.table(table).select("*").limit(3).execute()
    except APIError as e:
        if e.code == "PGRST205":
            print(
                f"Connected to Supabase, but table '{table}' does not exist yet. "
                "Run python scripts/apply_schema.py (or paste db/schema.sql into the Supabase SQL Editor)."
            )
            return
        raise
    print(f"OK - connected. Table '{table}' returned {len(res.data)} row(s).")


if __name__ == "__main__":
    main()
