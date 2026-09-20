"""Supabase client factory. Credentials come from environment variables (.env), never from code."""
import os
from pathlib import Path

from dotenv import load_dotenv
from supabase import Client, create_client

# Load .env from the repository root, regardless of where the script is run from.
load_dotenv(Path(__file__).resolve().parents[1] / ".env")


def get_client() -> Client:
    url = os.getenv("SUPABASE_URL")
    key = os.getenv("SUPABASE_SECRET_KEY")
    if not url or not key:
        raise RuntimeError(
            "Missing SUPABASE_URL or SUPABASE_SECRET_KEY. "
            "Copy .env.example to .env and fill in your values."
        )
    return create_client(url, key)
