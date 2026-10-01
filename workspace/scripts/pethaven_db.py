"""Shared database helpers for the PetHaven prototype scripts.

Purpose
    Open connections to the provided Lab Environment PostgreSQL server, create
    and drop ISOLATED scenario databases safely, and run SQL files.

Connection settings
    The defaults are the Lab Environment values from docker-compose.yml
    (host ``postgres``, port 5432, user ``student``, password ``student``,
    maintenance database ``lab``). Standard libpq environment variables
    (PGHOST, PGPORT, PGUSER, PGPASSWORD) override them, for example
    ``PGHOST=localhost`` when running a script on the host machine.

Safety rules
    * Only databases whose names start with ``pethaven_test_`` are ever
      created or dropped, and only on a local lab server (host postgres,
      localhost or 127.0.0.1). The lab's own ``lab`` database and any shared or
      cloud database (for example the team's Supabase project) are never reset.
    * Uses only libraries installed by the lab's python/requirements.txt.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

import psycopg2
import psycopg2.extensions

WORKSPACE = Path(__file__).resolve().parents[1]
DB_DIR = WORKSPACE / "db"
SEED_DIR = DB_DIR / "seed"
TESTS_DIR = WORKSPACE / "tests"

TEST_DATABASE_PREFIX = "pethaven_test_"
LOCAL_LAB_HOSTS = {"postgres", "localhost", "127.0.0.1"}
SYDNEY = "Australia/Sydney"

# Revision labels recorded with every load and report run.
CODE_REVISION = "prototype-v1"
CALCULATION_REVISION = "calc-v1"


def lab_settings() -> dict:
    """Return connection keyword arguments for the lab server (env overrides)."""
    return {
        "host": os.environ.get("PGHOST", "postgres"),
        "port": int(os.environ.get("PGPORT", "5432")),
        "user": os.environ.get("PGUSER", "student"),
        "password": os.environ.get("PGPASSWORD", "student"),
    }


def connect(database: str | None = None, dsn: str | None = None):
    """Open a connection in Sydney time.

    Args:
        database: Database name on the lab server. Ignored when ``dsn`` is given.
        dsn: Full connection string, used only for the optional Supabase backup
            target (see docs/supabase_backup.md).

    Returns:
        A psycopg2 connection with autocommit off; the caller owns transactions.
    """
    if dsn:
        conn = psycopg2.connect(dsn)
    else:
        conn = psycopg2.connect(dbname=database or "lab", **lab_settings())
    with conn.cursor() as cur:
        cur.execute("SET TIME ZONE %s", (SYDNEY,))
    conn.commit()
    return conn


def test_database_name(scenario_code: str) -> str:
    """Return the isolated database name used for one scenario."""
    return TEST_DATABASE_PREFIX + scenario_code


def _assert_safe_to_reset(database: str) -> None:
    """Raise unless ``database`` is an isolated test database on a local lab server."""
    if not re.fullmatch(TEST_DATABASE_PREFIX + r"[a-z0-9_]+", database):
        raise RuntimeError(f"Refusing to create or drop '{database}': only {TEST_DATABASE_PREFIX}* databases are managed")
    host = lab_settings()["host"]
    if host not in LOCAL_LAB_HOSTS:
        raise RuntimeError(f"Refusing to create or drop databases on host '{host}': only the local lab server is allowed")


def recreate_test_database(database: str) -> None:
    """Drop (if present) and create one isolated test database on the lab server.

    Side effects: destroys the previous contents of that test database only.
    The database time zone is set to Australia/Sydney for readable output;
    stored values are timestamptz and do not depend on it.
    """
    _assert_safe_to_reset(database)
    admin = psycopg2.connect(dbname="lab", **lab_settings())
    admin.set_isolation_level(psycopg2.extensions.ISOLATION_LEVEL_AUTOCOMMIT)
    try:
        with admin.cursor() as cur:
            cur.execute(f'DROP DATABASE IF EXISTS "{database}" WITH (FORCE)')
            cur.execute(f'CREATE DATABASE "{database}"')
            cur.execute(f'ALTER DATABASE "{database}" SET timezone TO \'{SYDNEY}\'')
    finally:
        admin.close()


def run_sql_file(conn, path: Path) -> None:
    """Execute a whole SQL file in the connection's current transaction.

    No parameters are bound, so '%' characters in the file are left untouched.
    The caller commits or rolls back.
    """
    sql = Path(path).read_text(encoding="utf-8")
    with conn.cursor() as cur:
        cur.execute(sql)


def fmt(value) -> str:
    """Format a database value for printing and comparison (None -> 'NULL')."""
    return "NULL" if value is None else str(value)
