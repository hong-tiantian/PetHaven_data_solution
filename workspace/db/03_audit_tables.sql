-- =============================================================================
-- 03_audit_tables.sql
-- Purpose: Create pipeline execution records: load runs, extraction manifests,
--          record lineage, data-quality issues, mapping changes and the
--          scenario step log used by the acceptance runner.
-- Prerequisites: 01_schemas.sql.
-- Inputs: None.
-- Outputs: audit tables with catalogue comments.
-- Execution: Applied by scripts/apply_schema.py.
-- Transaction: One transaction for the whole file (runner-owned).
-- Rerun behaviour: Not rerunnable; rebuild in a fresh isolated database.
-- Business rules: Architecture_and_Data_Model.md sections 8.2 and 12.1.
-- =============================================================================

-- Publication order is compared through this sequence, not through numeric
-- run IDs: a run created earlier can be published later (Arch 9.2).
CREATE SEQUENCE audit.publication_sequence;
COMMENT ON SEQUENCE audit.publication_sequence IS
'Gives each successfully published load an increasing publication order.';

CREATE TABLE audit.load_run (
    load_run_id            bigint GENERATED ALWAYS AS IDENTITY,
    run_code               text        NOT NULL,
    scenario_code          text        NOT NULL,
    source_as_of_at        timestamptz NOT NULL,
    started_at             timestamptz NOT NULL DEFAULT clock_timestamp(),
    finished_at            timestamptz,
    published_at           timestamptz,
    publication_sequence   bigint,
    scenario_published_at  timestamptz,
    status                 text        NOT NULL DEFAULT 'running',
    code_revision          text        NOT NULL,
    mapping_revision       text,
    summary_error          text,
    CONSTRAINT pk_load_run PRIMARY KEY (load_run_id),
    CONSTRAINT uq_load_run_code UNIQUE (scenario_code, run_code),
    CONSTRAINT uq_load_run_publication_sequence UNIQUE (publication_sequence),
    CONSTRAINT ck_load_run_status CHECK (status IN ('running', 'succeeded', 'rejected', 'failed')),
    -- Only a succeeded run is published, and it must say when and in what order.
    CONSTRAINT ck_load_run_publication CHECK (
        (status = 'succeeded') = (published_at IS NOT NULL AND publication_sequence IS NOT NULL)
    )
);
COMMENT ON TABLE audit.load_run IS
'One execution of the integration pipeline at a simulated business checkpoint. Status running -> succeeded (published), rejected (validation errors) or failed (execution or extraction error). Only succeeded runs are visible to calculations.';
COMMENT ON COLUMN audit.load_run.run_code IS
'Human-readable checkpoint label from the scenario file, for example cp_d1_1500.';
COMMENT ON COLUMN audit.load_run.source_as_of_at IS
'Simulated business time the sources had reached when they were extracted. Calculations may not observe a time later than this.';
COMMENT ON COLUMN audit.load_run.started_at IS
'Actual wall-clock time the run started. A different clock from the synthetic business times.';
COMMENT ON COLUMN audit.load_run.published_at IS
'Actual wall-clock time the run became visible to reporting. Null unless status is succeeded.';
COMMENT ON COLUMN audit.load_run.scenario_published_at IS
'Simulated time at which this load is treated as incorporated in the time-compressed demonstration (equal to source_as_of_at). Durations measured from it are labelled simulated delay.';

CREATE TABLE audit.source_extract (
    load_run_id       bigint      NOT NULL,
    system_code       text        NOT NULL,
    table_name        text        NOT NULL,
    started_at        timestamptz NOT NULL,
    finished_at       timestamptz,
    source_row_count  bigint,
    raw_row_count     bigint,
    rejected_count    bigint      NOT NULL DEFAULT 0,
    status            text        NOT NULL,
    CONSTRAINT pk_source_extract PRIMARY KEY (load_run_id, system_code, table_name),
    CONSTRAINT fk_source_extract_load_run FOREIGN KEY (load_run_id)
        REFERENCES audit.load_run (load_run_id),
    CONSTRAINT ck_source_extract_status CHECK (status IN ('succeeded', 'failed'))
);
COMMENT ON TABLE audit.source_extract IS
'Extraction manifest: one row per source table extracted in a load run, with source and raw row counts. A required table without a succeeded manifest, or with unequal counts, blocks publication.';

CREATE TABLE audit.record_lineage (
    lineage_id         bigint GENERATED ALWAYS AS IDENTITY,
    load_run_id        bigint NOT NULL,
    raw_table_name     text   NOT NULL,
    raw_record_id      bigint NOT NULL,
    target_table_name  text   NOT NULL,
    target_key         bigint NOT NULL,
    disposition        text   NOT NULL,
    CONSTRAINT pk_record_lineage PRIMARY KEY (lineage_id),
    CONSTRAINT fk_record_lineage_load_run FOREIGN KEY (load_run_id)
        REFERENCES audit.load_run (load_run_id),
    CONSTRAINT uq_record_lineage UNIQUE
        (load_run_id, raw_table_name, raw_record_id, target_table_name, target_key),
    CONSTRAINT ck_record_lineage_disposition CHECK (disposition IN ('loaded', 'duplicate', 'supporting'))
);
COMMENT ON TABLE audit.record_lineage IS
'Links an extracted raw row to the warehouse row it created (loaded), repeated (duplicate) or helped to build (supporting). Several raw rows can support one fact, and one raw header can support several facts. The target is polymorphic, so target validity is checked by the loader rather than by a foreign key.';
COMMENT ON COLUMN audit.record_lineage.disposition IS
'loaded: this run inserted the target from this row. duplicate: the target already existed or another representation inserted it. supporting: header or status row used to build the target.';

CREATE TABLE audit.data_quality_issue (
    issue_id                bigint GENERATED ALWAYS AS IDENTITY,
    load_run_id             bigint      NOT NULL,
    rule_code               text        NOT NULL,
    severity                text        NOT NULL,
    raw_table_name          text,
    raw_record_id           bigint,
    source_reference        text,
    sku                     text,
    location_code           text,
    message                 text        NOT NULL,
    detected_at             timestamptz NOT NULL DEFAULT clock_timestamp(),
    resolution_note         text,
    resolved_by_load_run_id bigint,
    CONSTRAINT pk_data_quality_issue PRIMARY KEY (issue_id),
    CONSTRAINT fk_data_quality_issue_load_run FOREIGN KEY (load_run_id)
        REFERENCES audit.load_run (load_run_id),
    CONSTRAINT fk_data_quality_issue_resolved_by FOREIGN KEY (resolved_by_load_run_id)
        REFERENCES audit.load_run (load_run_id),
    CONSTRAINT ck_data_quality_issue_severity CHECK (severity IN ('error', 'warning'))
);
COMMENT ON TABLE audit.data_quality_issue IS
'One validation finding for a load run. Any error rejects the whole run (conservative policy, Arch 6); warnings are published and counted. Issues are retained after later runs succeed.';
COMMENT ON COLUMN audit.data_quality_issue.source_reference IS
'Business identity of the affected record, for example store_sales:sale:S-0123-0001:1.';

CREATE TABLE audit.mapping_change (
    change_id        bigint GENERATED ALWAYS AS IDENTITY,
    mapping_type     text        NOT NULL,
    mapping_key      text        NOT NULL,
    previous_target  text,
    new_target       text        NOT NULL,
    changed_at       timestamptz NOT NULL DEFAULT clock_timestamp(),
    reason           text        NOT NULL,
    revision         text        NOT NULL,
    CONSTRAINT pk_mapping_change PRIMARY KEY (change_id),
    CONSTRAINT ck_mapping_change_type CHECK (mapping_type IN ('product', 'location'))
);
COMMENT ON TABLE audit.mapping_change IS
'One reviewed change to a reference mapping after the initial seed, with its reason. Changing an already-used mapping to a different target is not allowed silently.';

CREATE TABLE audit.scenario_step (
    step_id        bigint GENERATED ALWAYS AS IDENTITY,
    scenario_code  text        NOT NULL,
    step_order     integer     NOT NULL,
    step_kind      text        NOT NULL,
    step_code      text        NOT NULL,
    description    text,
    status         text        NOT NULL,
    error_message  text,
    executed_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT pk_scenario_step PRIMARY KEY (step_id),
    CONSTRAINT ck_scenario_step_status CHECK (status IN ('succeeded', 'expected_error'))
);
COMMENT ON TABLE audit.scenario_step IS
'Test-harness log written by scripts/run_scenario.py: one row per executed scenario step. expected_error records a step that was required to be rejected (for example an unsupported correction). Not business data.';
