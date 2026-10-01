# Optional backup target: Supabase

The prototype runs in the provided Lab Environment. All development, testing and the demonstration use it. Supabase is only an optional place to share the same schema with teammates who cannot run Docker.

**Status:** the Supabase path is written but has **not been executed or tested**.

## Why it can work

Supabase is a hosted PostgreSQL database. The SQL files use only standard PostgreSQL:

- no extensions;
- no `CREATE DATABASE` or `CREATE ROLE`;
- no Supabase-specific API.

Every object is created in the nine project schemas, not in `public`.

## Rules

1. **Never reset the shared database.**
   - The acceptance runner only creates and drops `pethaven_test_*` databases on the local lab server. It refuses any other host.
   - `apply_schema.py --database-url` never drops anything. It refuses to run if any PetHaven schema already exists in the target.
2. **Use the Session pooler connection string.**
   - Docker on Windows uses IPv4, and Supabase's direct connection is IPv6.
   - In Supabase: **Connect → Session pooler**, then replace `[YOUR-PASSWORD]`. URL-encode special characters in the password.
3. **Keep the connection string out of Git and out of chat.**

## Applying the schema to an empty Supabase project

```bash
docker compose exec python python /workspace/scripts/apply_schema.py --database-url "postgresql://<user>:<password>@<pooler-host>:5432/postgres"
```

This creates the schemas, routines and reference mappings only. The scenario runner (`run_scenario.py`) recreates databases and therefore works only against the lab server.

To share demo data, either:

- open the lab database through CloudBeaver; or
- export the report CSVs with `scripts/export_reports.py` and share those files.

## Old Supabase content

The previous customer/pet tables (`src_pos_*`, `src_digital_*`, `src_grooming_*` in `public`) may still exist in the team's Supabase project. They are unrelated to the new model, and these scripts do not touch them. Removing them is a team decision.
