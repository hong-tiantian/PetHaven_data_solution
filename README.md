# PetHaven Data Solution

## Required setup

Use the following steps on a new machine before working on the project.

### 1) Clone the repo

```bash
git clone <repo-url>
cd PetHaven_data_solution
```

### 2) Create and activate a virtual environment

```bash
python3 -m venv .venv
source .venv/bin/activate
```

### 3) Upgrade pip

```bash
python -m pip install --upgrade pip
```

### 4) Install project dependencies

```bash
pip install -r requirements.txt
```

## Required environment variables

Create a local `.env` file in the repository root. Do not commit it.

```bash
cp .env.example .env
```

Then fill in the values from the team’s Supabase project:

- `SUPABASE_URL`
- `SUPABASE_SECRET_KEY`
- `DATABASE_URL` (only for the person who creates the tables, see below)

If the project does not yet have a `.env.example`, ask the project owner for the correct values and add them locally only.

## Creating the database tables (one person, once)

The table structure lives in `db/schema.sql`. Only ONE person needs to apply it to the shared Supabase project.

1. In Supabase click **Connect** -> **Session pooler**, copy the URI, and replace `[YOUR-PASSWORD]` with the database password.
2. Put it in your local `.env` as `DATABASE_URL=...` (URL-encode special characters in the password).
3. Run:

```bash
python scripts/apply_schema.py
```

The script shows which database it will write to and asks for confirmation. It is safe to re-run, and if anything fails nothing is created. Then check the connection with `python scripts/test_connection.py`.

The schema currently covers only the three UC1 (Customer & Pet Profile) source systems (`src_pos_*`, `src_digital_*`, `src_grooming_*`), enough to load the initial synthetic data. Staging, MDM and the dimensional data warehouse (Silver and Gold layers) are added in later pull requests.

If the database still has tables from an earlier version of the schema (`mdm_*`, `gov_*`, `v_*` or old `src_*` tables such as `src_product_*` and `src_customer_*`), the script stops and tells you. On a development database with no real data, remove them and apply the new schema in one step with:

```bash
python scripts/apply_schema.py --reset
```

`--reset` deletes those tables **with their data** and asks you to type `reset` first.

Everyone else can skip this section. Change the structure by editing `db/schema.sql` in a pull request.

## Loading the synthetic data (UC1)

`db/seed_sources.sql` fills the three source systems with synthetic data (577 rows). It contains:

- **Scenario customers** (hand written): 13 real people spread over 26 source records, each reproducing a UC1 problem (the same person under several IDs, duplicates inside one system, an old email at the salon, pets spelt differently, a pet with no owner record, and two different people both called James Lee who must NOT be merged). The table at the top of the file lists them.
- **Background customers** (generated, fixed values): 52 single-source customers with unique emails and phones, for realistic report volume.

After `apply_schema.py`, run (one person, on the shared database):

```bash
python scripts/load_seed.py
```

It empties every `src_` table and reloads it in one transaction, so it is safe to re-run.

## Manual steps team members should know

1. Ask to be added to the correct Supabase project / organization.
2. Accept the invitation and verify access in the Supabase dashboard.
3. Open the project and go to Settings -> API Keys.
4. Copy the connection values into your local `.env` file.
5. Keep `.env` local only and never commit it to Git.
6. If you are working with database scripts, make sure your local environment is active before running commands.

## Local workflow

```bash
source .venv/bin/activate
python -m pip install -r requirements.txt
```

Use the active virtual environment for all local scripts and database commands.

## Important notes

- `.env` is secret and should never be shared in chat, GitHub issues, or PRs.
- `SUPABASE_SECRET_KEY` should only be used in local or server-side scripts, not in frontend code.
- If a key is exposed, rotate it immediately in Supabase.
- Keep project configuration and schema changes documented and reviewed in pull requests.
