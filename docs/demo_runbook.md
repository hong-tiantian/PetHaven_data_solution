# PetHaven prototype: demonstration runbook

Step-by-step instructions for the live demonstration and the recorded end-to-end video. Every command runs in the provided Lab Environment. Nothing in the lab configuration is modified.

## 0. One day before

1. Start Docker Desktop.
2. From the repository root, build and start the lab. The first build downloads images and Python packages, so do it on a good network before the demo day.

   ```bash
   docker compose up -d
   ```

3. Run the full acceptance suite once and check that the last line reads `FAIL 0, SKIP 0`.

   ```bash
   docker compose exec python python /workspace/scripts/run_acceptance.py --quiet
   ```

4. Open CloudBeaver at <http://localhost:8978> and create a PostgreSQL connection (one-time setup, saved in `data/cloudbeaver`):

   | Field | Value |
   | --- | --- |
   | Host | `postgres` |
   | Port | `5432` |
   | Database | `pethaven_test_case_1_baseline` |
   | User / password | `student` / `student` |

   Tick "Show all databases" so the other `pethaven_test_*` databases are visible.

5. Keep the recorded video ready as a fallback.

If another copy of the course lab is running, its containers use the same names (`student-postgres`, and so on). Stop it first with `docker compose down`, without `-v`, in that lab's folder; its data stays in that folder's `data/` directory.

## 1. Opening: what the prototype shows (about 1 minute)

- **Problem.** The website copies a midnight stock balance at 5 am and does not see till sales made during the day (Spec 2.1).
- **Three sources.** `src_store_sales`, `src_online` and `src_stock` are separate schemas, each with its own business actions and schedule (Spec 3.1).
- **Integration.** Integration reads recent till sales directly. It does not wait for central's 1 am import (Spec 7.2).

## 2. Baseline Case 1, step by step (about 4 minutes)

```bash
docker compose exec python python /workspace/scripts/run_scenario.py case_1_baseline --pause
```

The runner pauses after each checkpoint and prints the Parramatta dog food line: website quantity, then the integrated calculated on hand, reserved, available and shortfall. Talking points at each pause:

| Checkpoint | Show | Say |
| --- | --- | --- |
| `cp_d1_0100` | website `NULL` | The website has no copy yet. Unknown is never shown as zero. |
| `cp_d1_0500` | 5 / 5 | The 5 am copy of the midnight snapshot. Both calculations agree. |
| `cp_d1_0930` | 4 / reserved 1 | Customer A's order is a reservation, not a physical movement. |
| `cp_d1_1400` | website 4, available 0 | Four till sales are already in the store sales database. Central and the website have not seen them; integration has. |
| `cp_d1_1500` | website 3, shortfall 1 | The website accepted Sarah's order using its own outdated calculation. Two commitments now compete for one bag. |
| `cp_d1_1545` | website 4 | The cancellation released Sarah's reservation, so the website goes back up to 4. |
| `cp_d2_0100` | website still 4 | Only central processed the store sales at 1 am. |
| `cp_d2_0500` | website 0 | The 5 am refresh copies one bag and subtracts A's carried-over reservation. |
| `cp_d2_0500_repeat` | unchanged | Rerunning the full load adds raw evidence but no business facts (T09). |
| `cp_hist_d1_1500` | shortfall 1 | A later rebuild of 3 pm still shows Sarah at risk, because it uses status history. |

## 3. Improved Case 1 (about 1 minute)

```bash
docker compose exec python python /workspace/scripts/run_scenario.py case_1_improved --pause
```

At `chk_sarah_1500` the simulated check answers **INSUFFICIENT**, and no order is created. Point out that the website still says 4 at the same moment (Spec 7.3).

## 4. The three reports in CloudBeaver (about 3 minutes)

Open database `pethaven_test_case_1_baseline` and run:

```sql
-- Report 1: where does the website differ from the integrated calculation?
SELECT checkpoint_code, sku, location_code, website_available_quantity,
       calculated_on_hand_quantity, reserved_quantity, available_quantity,
       shortfall_quantity, availability_difference, difference_direction
  FROM rpt.v_availability_comparison
 WHERE checkpoint_code IN ('cp_d1_1400', 'cp_d1_1500', 'cp_d2_0500')
 ORDER BY observed_at, sku, location_code;

-- Report 2: C&C orders at risk and stock-related cancellations
SELECT checkpoint_code, order_id, effective_status, requested_quantity,
       allocated_quantity, line_shortfall_quantity, is_at_risk,
       cancellation_reason, cancelled_at
  FROM rpt.v_order_risk_and_cancellation
 ORDER BY observed_at, placed_at;

-- Report 3a: how long did events take to reach the integrated result?
SELECT source_identity, occurred_at, source_recorded_at, first_load_run_code,
       scenario_published_at, simulated_delay, warehouse_loaded_at, actual_load_runtime
  FROM rpt.v_data_update_delay
 WHERE event_kind = 'physical_movement'
 ORDER BY occurred_at;

-- Report 3b: how old was the website's stock basis?
SELECT checkpoint_code, website_snapshot_cutoff_at, website_copied_at,
       website_basis_age, website_copy_age, website_copy_lag
  FROM rpt.v_website_stock_age
 ORDER BY observed_at;
```

Explain the two clocks in report 3. `simulated_delay` uses the scenario's business times. `actual_load_runtime` is the real seconds the lab took to run the load.

Optional extra: show one physical event counted once. The till sale and its 1 am central copy share one fact; the copy only adds lineage.

```sql
SELECT g.raw_table_name, g.disposition, f.origin_event_id, f.quantity
  FROM audit.record_lineage AS g
  JOIN dw.fact_stock_movement AS f ON f.movement_key = g.target_key
 WHERE g.target_table_name = 'dw.fact_stock_movement'
   AND f.origin_event_id = 'S-0123-0001'
 ORDER BY g.load_run_id, g.raw_table_name;
```

## 5. Proof that it works (about 1 minute)

```bash
docker compose exec python python /workspace/scripts/run_acceptance.py --quiet
```

This single command:

1. Recreates nine isolated empty databases.
2. Creates all schemas.
3. Loads the synthetic data and simulates the business days and schedules.
4. Runs the ETL at every checkpoint.
5. Compares 272 saved results with fixed expected values written from the Spec.

Each row prints the expected value, the actual value and PASS/FAIL/SKIP. The exit code is non-zero if anything fails or is skipped. Results are also saved to `workspace/tests/results/`.

Failure handling, if asked (scenario databases shown in brackets):

- An unknown barcode or store code rejects the load, and the stock check answers `unknown` (`pethaven_test_unknown_identifier`).
- A central copy that disagrees with the original sale blocks publication (`pethaven_test_conflicting_duplicate`).
- A failed publication leaves no partial facts (`pethaven_test_failed_publication`).
- A late record before the cutoff requires reconciliation (`pethaven_test_pre_cutoff_late_record`).

## 6. Questions you may be asked

| Question | Short answer | Where |
| --- | --- | --- |
| Why not count the central import as another sale? | Both carry the same four-part origin identity, and the warehouse is unique on it. | `dw.fact_stock_movement` (`uq_fact_stock_movement_origin`); `db/etl/prepare_staging.sql` section 4 |
| Why use the midnight snapshot rather than central's current balance? | The current balance mixes fresh receipts with day-old sales. | Spec 3.2; `db/source_jobs/create_midnight_snapshot.sql` |
| Is an event at exactly midnight in the snapshot? | No. It belongs after the cutoff and is counted once. | T11; `rpt.calculate_inventory` |
| Does the warehouse stop overselling in production? | No. It calculates, reports and simulates the check. A production checkout would need a transactional reservation. | Spec 7.3 |
| Why one database with schemas? | Separate business ownership with simple lab extraction. It does not reproduce cross-server failures. | Architecture section 16 |
