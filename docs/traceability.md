# Business rules, SQL and tests: traceability

This table maps each business rule in the [Spec](../00_req_feedback/Assignment2_Spec.md) and the [architecture design](Architecture_and_Data_Model.md) to the SQL that implements it and the acceptance checks that verify it. File paths are relative to `workspace/`.

- Expected values are in `tests/expected/<scenario>.csv`.
- Actual values are read by `tests/sql/common_checks.sql` and `tests/sql/<scenario>.sql`.

## Rules

| # | Business rule | Spec / Arch | Implemented in | Verified by (scenario) |
| --- | --- | --- | --- | --- |
| R1 | Three separate business sources, each with its own actions | Spec 3.1, 4; Arch 4 | `db/01_schemas.sql`, `db/02_source_tables.sql`, `db/source_actions/*.sql` | All scenarios |
| R2 | A completed till sale is saved immediately and reduces stock at completion time | Spec 4.1 | `src_store_sales.record_sale`; `db/etl/prepare_staging.sql` §3a | T01, T03 (case_1_baseline, case_2) |
| R3 | Accepting an order creates a reservation and no physical movement | Spec 4.2 A, 5.1 | `src_online.place_order`; `rpt.calculate_inventory` (reserved) | T01, T05 (movement_checks) |
| R4 | The website accepts an order only if its own outdated calculation shows stock | Spec 4.2 A, 5.3 | `src_online.website_available_quantity`, `src_online.place_order` | T01 (Sarah accepted with website 4), T03 |
| R5 | Ready keeps the goods on hand and reserved | Spec 4.2 B | `src_online.change_order_status` | T04, T12 |
| R6 | Collection reduces on hand and ends the reservation at the same time | Spec 4.2 B, 5.2 | `db/etl/prepare_staging.sql` §3b; `rpt.effective_order_status` | T04, T13 |
| R7 | Cancellation before collection releases the reservation, creates no movement and keeps the reason | Spec 4.2 C, 5.5 | `src_online.change_order_status`; `rpt.v_order_risk_and_cancellation` | T01, T03, T05, T17 |
| R8 | A supplier receipt increases only the receiving DC | Spec 4.3 A | `src_stock.record_supplier_receipt` | T06 |
| R9 | Creating a transfer moves nothing; dispatch reduces the origin; receipt increases the destination; in-transit goods belong to no location | Spec 4.3 B | `src_stock.create_transfer`, `dispatch_transfer`, `receive_transfer` | T07, T16 |
| R10 | Adjustments are signed, with a reason; corrections append a linked reversal | Spec 4.3 C; Arch 10.5 | `src_stock.record_adjustment`, `record_reversal`; `dw.load_warehouse` (`reverses_movement_key`) | T26, T11, T18 |
| R11 | Central applies local movements hourly, once each | Spec 3.2; Arch 11.1 | `db/source_jobs/apply_local_movements.sql` | T06, T22 |
| R12 | The 1 am import keeps the original event identity and applies each event once | Spec 3.2, 4.3 D, 5.2; Arch 11.2 | `db/source_jobs/import_daily_transactions.sql` | T08, T22 |
| R13 | The midnight snapshot = previous snapshot + events in [previous cutoff, cutoff); an event at exactly midnight belongs after it | Spec 3.2, 5.1; Arch 9.3, 11.2 | `db/source_jobs/create_midnight_snapshot.sql` | T10, T11 |
| R14 | The 5 am refresh copies the midnight snapshot; the website subtracts its own collections since the cutoff and its active reservations | Spec 5.3; Arch 10.2, 11.3 | `db/source_jobs/refresh_website_stock.sql`; `rpt.calculate_website_inventory` | T01, T12, T13 |
| R15 | Integrated on hand = opening + movements in [cutoff, observed]; available and shortfall as defined | Spec 5.1; Arch 10.1 | `rpt.calculate_inventory` | T01–T07, T11, T13 |
| R16 | One physical event is counted once even when several sources hold it | Spec 5.2; Arch 8 | `db/etl/prepare_staging.sql` §4–5; `uq_fact_stock_movement_origin` | T08, T09, T15 |
| R17 | When the opening snapshot advances, events already inside it are not subtracted again | Spec 5.2 | `rpt.calculate_inventory` (opening, `movement_since_opening`) | T10 |
| R18 | Product and location codes are matched only through approved mappings; unmatched codes are flagged, never guessed | Spec 5.4; Arch 5.2 | `db/05_reference_tables.sql`; `db/seed/reference_mappings.sql`; `db/etl/validate_sources.sql` §2–3; `db/etl/prepare_staging.sql` §2 | T14 |
| R19 | History is kept; historical results use the status at the observation time | Spec 5.5, 7.4; Arch 9.4 | `dw.fact_order_status_event`; `rpt.effective_order_status` | T17 |
| R20 | At-risk allocation: on hand before reservations, by acceptance time, order ID breaks ties | Spec 7.4; Arch 10.4 | `rpt.allocate_order_stock` | T03, T17, T19 |
| R21 | The simulated stock check uses the same calculation and creates no order; every line must be covered | Spec 7.1, 7.3; Arch 13.1 | `rpt.check_availability`; `rpt.record_stock_check` | T02, T20 |
| R22 | Unknown is not zero (missing opening, missing website copy, unpublished load) | Arch 9.3, 10.2, 13.1 | `rpt.calculate_inventory` and `calculate_website_inventory` quality status; `rpt.check_availability` | T01 (missing copy), T14, T16, T21, T24, T25 |
| R23 | Event, recording, load and publication times are kept apart; snapshot cutoff and copy time are kept apart | Spec 3.2, 7.4, 8.1; Arch 9.1 | Timestamp columns in all layers; `rpt.v_data_update_delay`; `rpt.v_website_stock_age` | T23 |
| R24 | A calculation sees only what a published load knew; saved observations never change | Arch 9.2, 13.2 | `rpt.visible_load_runs`; `rpt.report_run` and observations | T17, T18 |
| R25 | Any validation error rejects the whole load; publication is atomic; raw evidence is kept | Arch 6, 12.2 | `scripts/run_pipeline.py`; `db/etl/load_warehouse.sql`; `db/etl/load_control.sql` | T14, T15, T21, T24 |
| R26 | A conflicting duplicate blocks publication and names both raw records | Arch 8.2 | `db/etl/prepare_staging.sql` §4 | T15 |
| R27 | An omitted source table blocks publication | Arch 12.1 | `raw.extract_sources` manifests; `db/etl/validate_sources.sql` §1 | T24 |
| R28 | A late record before the cutoff needs reconciliation and is not subtracted after the cutoff | Arch 10.5 | `db/etl/prepare_staging.sql` §8; `rpt.calculate_inventory` (`late_before_cutoff`) | T25 |
| R29 | Baseline and improved runs are separate executions | Arch 14.1 | Separate databases `pethaven_test_case_1_baseline` and `pethaven_test_case_1_improved` | T01, T02 |
| R30 | An unsupported order-status correction is rejected visibly | Arch 10.5 | `src_online.change_order_status` (terminal-status guard); `stg.validate_sources` (`unsupported_correction`) | T26 |

## Spec section 7.5 checklist

| Spec 7.5 check | Tests |
| --- | --- |
| Case 1 reproduces the quantities in Spec section 6, including the cancellation, the separate 1 am and 5 am updates, and A's carried-over reservation | T01, T12 |
| A completed collection reduces on hand and ends its reservation without making the unit available again | T04, T13 |
| A supplier receipt increases the receiving location; a DC dispatch does not increase store stock until confirmed receipt | T06, T07 |
| Imported sales are not counted again, and rerunning a load does not duplicate them | T08, T09, T22 |
| Advancing the opening snapshot excludes events already inside it | T10, T11 |
| Barcode/location mappings join the correct records, and unmatched records are visible | T14 (and the alternative barcode in T01) |
| The simulated check and all three reports use the same definitions | T02, T20, T23 (all use `rpt.calculate_inventory`) |

## Assignment brief, section (vi)

| Brief item | Evidence |
| --- | --- |
| (a) Source databases and schemas (at least 3) | `db/02_source_tables.sql`: `src_store_sales`, `src_online`, `src_stock` |
| (b) Integrated warehouse (at least 1) | `db/07_warehouse_tables.sql`: `dw` dimensions and facts |
| (c) Commented SQL with synthetic data: create, extract, transform/load | `db/01–08`, `db/source_actions`, `db/source_jobs`, `db/etl`, `db/seed` |
| (d) At least 3 reports | `rpt.v_availability_comparison`, `rpt.v_order_risk_and_cancellation`, `rpt.v_data_update_delay` + `rpt.v_website_stock_age`; CSV exports from `scripts/export_reports.py` |
| (e) End-to-end testing | `scripts/run_acceptance.py`; `tests/results/acceptance_summary.md` |
