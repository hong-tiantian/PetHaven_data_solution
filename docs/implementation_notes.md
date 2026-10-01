# Implementation status

This file holds only the current verification results and the items that are not implemented. The design decisions themselves are recorded in [Architecture_and_Data_Model.md](Architecture_and_Data_Model.md). The mapping from business rules to SQL and tests is in [traceability.md](traceability.md).

## Verification results (1 October 2026)

Command, run in the provided Lab Environment from the repository root:

```bash
docker compose exec python python /workspace/scripts/run_acceptance.py
```

| Measure | Result |
| --- | --- |
| Scenarios executed | 9 of 9 |
| Checks compared | 272 (all required checks T01–T26, plus one execution check per scenario) |
| PASS / FAIL / SKIP | 272 / 0 / 0 |
| Exit code | 0 |

The full per-check output is in `workspace/tests/results/acceptance_results.csv` and `acceptance_summary.md`.

**Do the tests detect real errors?** As a one-off mutation check, two calculation rules were deliberately broken and then restored:

- the midnight boundary (`>=` changed to `>`);
- the allocation tie-break (order ID sorted in reverse).

T11 and T19 then failed (6 checks) and the run exited with code 1.

## Not implemented, not executed, or limited

| Item | Status |
| --- | --- |
| Home delivery / `shipped` path | Constraints and code paths exist, but no scenario exercises them, so they are **not tested** |
| Order-status correction events (`corrects_event_id`) | **Not implemented**; rejected visibly (T26) |
| Reconciliation after a pre-cutoff late record (replacement snapshot or correction) | **Not implemented**; the problem is detected and flagged only (T25) |
| Incremental / change-data-capture extraction | **Not implemented**; every load extracts in full |
| Graphical dashboard | **Not built**; reports are SQL views plus CSV exports |
| Supabase backup path (`apply_schema.py --database-url`) | Written but **not executed** |
| ERD, refined architecture image, demonstration recording | **Not produced** (milestone 7) |
| Performance tests on a larger fixture | **Not done** |
| Partial collection, returns, partial transfers, split fulfilment | Out of scope (Spec 2.2, 4.3) |
| Concurrent reservation control in a live checkout | Out of scope (Spec 7.3) |
| Concurrent loads | Not supported by design; only one load may be `running` at a time |
