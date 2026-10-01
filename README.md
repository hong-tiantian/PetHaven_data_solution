# PetHaven Data Solution

Assignment 2 prototype (32113 Advanced Database). PetHaven's website accepts Click & Collect orders that the store cannot fulfil, because the website works from a stock balance copied each morning and does not see the day's till sales.

The prototype combines the three source databases (store sales, online orders, central stock) into a dimensional warehouse. It then:

- calculates availability for each product at each location;
- compares the result with what the website believed;
- identifies orders at risk;
- demonstrates a simulated stock check.

- Business rules: [00_req_feedback/Assignment2_Spec.md](00_req_feedback/Assignment2_Spec.md)
- Design: [docs/Architecture_and_Data_Model.md](docs/Architecture_and_Data_Model.md)
- Verification results and what is not implemented: [docs/implementation_notes.md](docs/implementation_notes.md)
- Rule → SQL → test mapping: [docs/traceability.md](docs/traceability.md)
- Demonstration script: [docs/demo_runbook.md](docs/demo_runbook.md)

## Runs in the provided Lab Environment

`docker-compose.yml`, `python/Dockerfile` and `python/requirements.txt` are the course lab files, unchanged. They provide:

- PostgreSQL 15 (`postgres:5432`, user `student`, password `student`);
- a Python 3.11 container;
- CloudBeaver at <http://localhost:8978>.

The lab's Neo4j and ClickHouse containers also start, but the prototype does not use them. All project code is in `workspace/`, which the compose file mounts as `/workspace`.

## How to run the project

You need **Docker Desktop** and **Git**. Nothing else needs installing: Python, PostgreSQL and all libraries run inside the lab containers.

Run every command from the **repository root** (the folder that contains `docker-compose.yml`). On Windows, use **PowerShell** or **Command Prompt**. In Git Bash, see [Troubleshooting](#troubleshooting).

### Step 1: Get the code (once)

```bash
git clone https://github.com/hong-tiantian/PetHaven_data_solution.git
```

```bash
cd PetHaven_data_solution
```

### Step 2: Start Docker Desktop

Open Docker Desktop and wait until it says the engine is running. Every `docker` command below fails while Docker Desktop is closed.

If you have another copy of the course lab (for example from the workshops), stop it first. Run this in **that lab's folder**, without `-v`:

```bash
docker compose down
```

Both copies use the same container names (`student-postgres`, ...), so only one can run at a time. The other lab's data stays in its own `data/` folder; `docker compose up -d` in that folder brings it back later.

### Step 3: Start the Lab Environment

```bash
docker compose up -d
```

- **First time:** this downloads the database images and builds the Python container. It needs internet access and can take several minutes.
- **After that:** it starts in seconds.

Check that all five containers are `Up`:

```bash
docker compose ps
```

The first time PostgreSQL starts, it needs about 20–30 seconds to initialise. Wait that long before Step 4, or you may see `Connection refused`.

### Step 4: Build the databases and run every check (one command)

```bash
docker compose exec python python /workspace/scripts/run_acceptance.py
```

It usually takes one to two minutes. For each of the nine scenarios it:

1. Recreates an isolated empty database, `pethaven_test_<scenario>`.
2. Creates all schemas, tables and routines.
3. Loads the synthetic data and simulates the business days, including the existing hourly, 1 am and 5 am jobs.
4. Runs the ETL at every checkpoint and saves the reports.
5. Compares the saved results with fixed expected values written from the Spec, printing expected value, actual value and PASS/FAIL/SKIP for each check.

**It worked if the last lines say:**

```text
TOTAL: 272 checks - PASS 272, FAIL 0, SKIP 0
Results written to /workspace/tests/results/acceptance_results.csv and acceptance_summary.md
```

Any FAIL or SKIP is listed in `workspace/tests/results/acceptance_summary.md`, and the command exits with code 1.

The lab's own `lab` database and any shared database (for example Supabase) are never reset. Only `pethaven_test_*` databases are recreated, so it is safe to run this command again at any time.

### Step 5: Look at the data

The repository contains **no data files**. The synthetic data is written as SQL in `workspace/db/seed/`. Step 4 creates the data in your local lab database, and it stays there after the run (stored in `data/`, not in Git).

To browse it, open CloudBeaver at <http://localhost:8978>. The first time, create an administrator login when CloudBeaver asks, then add a **PostgreSQL** connection:

| Field | Value |
| --- | --- |
| Host | `postgres` |
| Port | `5432` |
| Database | `pethaven_test_case_1_baseline` (or any other `pethaven_test_<scenario>`) |
| User / password | `student` / `student` |

Tick "Show all databases" to see all nine scenario databases. Good starting points are the report views:

- `rpt.v_availability_comparison`
- `rpt.v_order_risk_and_cancellation`
- `rpt.v_data_update_delay`
- `rpt.v_website_stock_age`

Ready-made queries are in [docs/demo_runbook.md](docs/demo_runbook.md).

To get the reports as CSV files instead, run `export_reports.py` (see below). The files go to `workspace/reports/<scenario>/`.

### Step 6: Stop the lab when you are done

```bash
docker compose stop
```

Your data is kept. Next time, start Docker Desktop and run `docker compose start` (or `docker compose up -d`).

### Other commands

| Task | Command (run from the repository root) |
| --- | --- |
| Step through one scenario with pauses (live demo) | `docker compose exec python python /workspace/scripts/run_scenario.py case_1_baseline --pause` |
| Run the acceptance checks for one scenario | `docker compose exec python python /workspace/scripts/run_acceptance.py --scenario case_2` |
| Export the reports to CSV (`workspace/reports/`) | `docker compose exec python python /workspace/scripts/export_reports.py` |
| Stop the lab (data kept) | `docker compose stop` |
| Remove the lab containers (data kept in `data/`) | `docker compose down` |

Scenarios: `case_1_baseline`, `case_1_improved`, `case_2`, `movement_checks`, `unknown_identifier`, `conflicting_duplicate`, `failed_publication`, `source_completeness`, `pre_cutoff_late_record`.

Avoid `docker compose down -v`, and do not delete `data/`. Both remove the local databases. If that happens, rerun Step 4 to rebuild them.

### Troubleshooting

| Message | Cause and fix |
| --- | --- |
| `failed to connect to the docker API` or `Cannot connect to the Docker daemon` | Docker Desktop is not running. Start it, wait until the engine is running, and retry. |
| `Conflict. The container name "/student-postgres" is already in use` | Another copy of the course lab exists. In that lab's folder run `docker compose down`, without `-v`, then repeat Step 3. |
| `Connection refused` from `run_acceptance.py` | PostgreSQL is still starting. Wait 20–30 seconds and run the command again. |
| `can't open file '/workspace/C:/Program Files/Git/...'` | Git Bash rewrote the `/workspace` path. Use PowerShell, or put `MSYS_NO_PATHCONV=1` in front of the command, for example `MSYS_NO_PATHCONV=1 docker compose exec python python /workspace/scripts/run_acceptance.py`. |
| `the input device is not a TTY` | Add `-T` after `exec` (`docker compose exec -T python python ...`). The `--pause` demo mode needs an interactive terminal, so run it without `-T` in a normal terminal window. |
| `port is already allocated` (5432, 8978, ...) | Another program uses that port, often a locally installed PostgreSQL. Stop that program, then repeat Step 3. |

## Repository layout

```text
docker-compose.yml, python/      Lab Environment (unchanged course files)
workspace/
  db/01_schemas.sql ... 08_reporting_objects.sql   schemas, tables, calculations, report views
  db/source_actions/   business actions of the three sources (till sale, order, receipt, ...)
  db/source_jobs/      existing schedules: hourly processing, 1 am import, midnight snapshot, 5 am refresh
  db/etl/              extract -> validate -> stage -> publish -> save report observations
  db/seed/             reference mappings, base master data and the nine scenario scripts
  scripts/             Python runners (orchestration only; the logic is in SQL)
  tests/expected/      fixed expected values per scenario (written from the Spec)
  tests/sql/           read-only queries that fetch the actual values
  tests/results/       latest acceptance results
docs/                  design, implementation notes, traceability, demo runbook
00_req_feedback/       assignment brief, Spec, tutor feedback, subject notes
data/                  lab database files created by Docker (not in Git)
```

## Database schemas

| Schema | Role |
| --- | --- |
| `src_store_sales`, `src_online`, `src_stock` | The three business sources |
| `raw` | Immutable extracts, one copy per load run |
| `ref` | Approved product and location code mappings |
| `stg` | Validation, code matching and one identity per physical event |
| `dw` | Dimensional warehouse (product, location, date; five fact tables) |
| `rpt` | Shared stock calculation, saved observations, simulated check, three report views |
| `audit` | Load runs, extraction manifests, lineage, data-quality issues |

## Supabase (optional backup only)

The team's Supabase project is not part of the tested workflow. See [docs/supabase_backup.md](docs/supabase_backup.md). Never commit a `.env` file or connection strings.
