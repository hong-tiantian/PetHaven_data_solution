-- =============================================================================
-- etl/load_control.sql
-- Purpose: Start, reject and fail a load run (audit.load_run state changes).
--          Publication (status succeeded) happens inside dw.load_warehouse.
-- Prerequisites: 03_audit_tables.sql.
-- Inputs: Load run identifiers and the scenario checkpoint.
-- Outputs: audit.load_run rows and status changes.
-- Execution: Called by scripts/run_pipeline.py in this order:
--   1. audit.start_load_run            (own transaction)
--   2. raw.extract_sources             (own REPEATABLE READ transaction)
--   3. stg.validate_sources + stg.prepare_staging (own transaction)
--   4a. audit.reject_load_run           when step 3 recorded any error, or
--   4b. dw.load_warehouse               (one publication transaction)
--   5. audit.fail_load_run              in a new transaction if 2 or 4b failed
-- Transaction: Each routine runs in the caller's transaction.
-- Rerun behaviour: A new run is created for every load; runs are never reused.
-- Business rules: Architecture_and_Data_Model.md 12.
-- =============================================================================

CREATE FUNCTION audit.start_load_run(
    p_scenario_code    text,
    p_run_code         text,
    p_source_as_of_at  timestamptz,
    p_code_revision    text
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    v_load_run_id bigint;
BEGIN
    -- Loads are serial in this prototype (Arch 9.2).
    IF EXISTS (SELECT 1 FROM audit.load_run WHERE status = 'running') THEN
        RAISE EXCEPTION 'Another load run is still running';
    END IF;

    INSERT INTO audit.load_run (run_code, scenario_code, source_as_of_at, code_revision, mapping_revision)
    VALUES (p_run_code, p_scenario_code, p_source_as_of_at, p_code_revision,
            coalesce((SELECT max(revision) FROM audit.mapping_change), 'seed-v1'))
    RETURNING load_run_id INTO v_load_run_id;

    RETURN v_load_run_id;
END;
$$;
COMMENT ON FUNCTION audit.start_load_run(text, text, timestamptz, text) IS
'Creates a running load run for a scenario checkpoint and returns its ID. Records the current mapping revision. Raises an error if another run is still running.';

CREATE PROCEDURE audit.reject_load_run(p_load_run_id bigint)
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE audit.load_run
       SET status = 'rejected',
           finished_at = clock_timestamp(),
           summary_error = (
               SELECT count(*) || ' validation error(s): ' || string_agg(DISTINCT rule_code, ', ')
                 FROM audit.data_quality_issue
                WHERE load_run_id = p_load_run_id AND severity = 'error')
     WHERE load_run_id = p_load_run_id AND status = 'running';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Load run % is not running', p_load_run_id;
    END IF;
END;
$$;
COMMENT ON PROCEDURE audit.reject_load_run(bigint) IS
'Marks a running load as rejected because validation recorded errors. Raw evidence and issues are kept; nothing is published.';

CREATE PROCEDURE audit.fail_load_run(p_load_run_id bigint, p_error text)
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE audit.load_run
       SET status = 'failed',
           finished_at = clock_timestamp(),
           summary_error = left(p_error, 2000)
     WHERE load_run_id = p_load_run_id AND status = 'running';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Load run % is not running', p_load_run_id;
    END IF;
END;
$$;
COMMENT ON PROCEDURE audit.fail_load_run(bigint, text) IS
'Marks a running load as failed after an execution or extraction error. Called in a new transaction after the failed work was rolled back, so no partial publication is visible.';
