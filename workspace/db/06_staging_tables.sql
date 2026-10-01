-- =============================================================================
-- 06_staging_tables.sql
-- Purpose: Create the run-scoped integration work tables: validated, typed and
--          matched records ready for warehouse publication.
-- Prerequisites: 01_schemas.sql, 03_audit_tables.sql.
-- Inputs: None (filled by db/etl/prepare_staging.sql).
-- Outputs: stg tables keyed by load_run_id.
-- Execution: Applied by scripts/apply_schema.py.
-- Transaction: One transaction for the whole file (runner-owned).
-- Rerun behaviour: Not rerunnable; rebuild in a fresh isolated database.
-- Business rules: Architecture_and_Data_Model.md sections 6 and 8.
--
-- Staging rows are working data. Every key starts with load_run_id and every
-- transformation is restricted to one run. Rows from earlier runs are kept for
-- debugging only; raw extracts and published warehouse rows are the durable
-- evidence. Product and location columns hold the matched shared identifiers
-- (SKU and canonical location code), never the original source codes.
-- =============================================================================

CREATE TABLE stg.product (
    load_run_id    bigint        NOT NULL,
    sku            text          NOT NULL,
    product_name   text          NOT NULL,
    brand          text          NOT NULL,
    category       text          NOT NULL,
    pack_size      numeric(12,3) NOT NULL,
    pack_unit      text          NOT NULL,
    is_active      boolean       NOT NULL,
    raw_record_id  bigint        NOT NULL,
    CONSTRAINT pk_stg_product PRIMARY KEY (load_run_id, sku),
    CONSTRAINT fk_stg_product_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id)
);
COMMENT ON TABLE stg.product IS
'One validated central product in a load run. Rebuildable working data.';

CREATE TABLE stg.location (
    load_run_id    bigint NOT NULL,
    location_code  text   NOT NULL,
    location_name  text   NOT NULL,
    location_type  text   NOT NULL,
    suburb         text   NOT NULL,
    raw_record_id  bigint NOT NULL,
    CONSTRAINT pk_stg_location PRIMARY KEY (load_run_id, location_code),
    CONSTRAINT fk_stg_location_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id)
);
COMMENT ON TABLE stg.location IS
'One validated canonical location in a load run. Rebuildable working data.';

CREATE TABLE stg.stock_event_candidate (
    load_run_id                bigint      NOT NULL,
    raw_table_name             text        NOT NULL,
    raw_record_id              bigint      NOT NULL,
    origin_system_code         text        NOT NULL,
    origin_event_type          text        NOT NULL,
    origin_event_id            text        NOT NULL,
    origin_line_id             text        NOT NULL,
    is_original_representation boolean     NOT NULL,
    sku                        text,
    location_code              text,
    movement_type              text        NOT NULL,
    quantity                   integer     NOT NULL,
    occurred_at                timestamptz NOT NULL,
    source_recorded_at         timestamptz NOT NULL,
    order_id                   text,
    order_line_id              text,
    transfer_id                text,
    transfer_line_id           text,
    delivery_reference         text,
    supplier_reference         text,
    reason_code                text,
    reverses_origin_system_code text,
    reverses_origin_event_type  text,
    reverses_origin_event_id    text,
    reverses_origin_line_id     text,
    support_raw_table_name      text,
    support_raw_record_id       bigint,
    CONSTRAINT pk_stg_stock_event_candidate PRIMARY KEY (load_run_id, raw_table_name, raw_record_id),
    CONSTRAINT fk_stg_stock_event_candidate_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id)
);
COMMENT ON TABLE stg.stock_event_candidate IS
'One raw representation of a physical event line in a load run: a till sale line, an online collection line, or a central movement (local or imported). Several candidates can share one origin identity; they must agree before one canonical event is published.';
COMMENT ON COLUMN stg.stock_event_candidate.is_original_representation IS
'True when the row comes from the source that created the event (for example the till sale line); false for the central imported copy of that event.';
COMMENT ON COLUMN stg.stock_event_candidate.raw_table_name IS
'Raw row that carries the line: raw.store_sales_sale_line, raw.online_web_order_line (for a collection or shipment) or raw.stock_stock_movement.';
COMMENT ON COLUMN stg.stock_event_candidate.support_raw_table_name IS
'Header or event row that completes the line: the sale header for a till sale, the collected/shipped status event for an online fulfilment. Recorded as supporting lineage.';
COMMENT ON COLUMN stg.stock_event_candidate.source_recorded_at IS
'Recording time in the source of this representation. For central imported copies this is the 1 am import time.';

CREATE TABLE stg.stock_event (
    load_run_id                 bigint      NOT NULL,
    origin_system_code          text        NOT NULL,
    origin_event_type           text        NOT NULL,
    origin_event_id             text        NOT NULL,
    origin_line_id              text        NOT NULL,
    sku                         text        NOT NULL,
    location_code               text        NOT NULL,
    movement_type               text        NOT NULL,
    quantity                    integer     NOT NULL,
    occurred_at                 timestamptz NOT NULL,
    source_recorded_at          timestamptz NOT NULL,
    order_id                    text,
    order_line_id               text,
    transfer_id                 text,
    transfer_line_id            text,
    delivery_reference          text,
    supplier_reference          text,
    reason_code                 text,
    reverses_origin_system_code text,
    reverses_origin_event_type  text,
    reverses_origin_event_id    text,
    reverses_origin_line_id     text,
    CONSTRAINT pk_stg_stock_event PRIMARY KEY
        (load_run_id, origin_system_code, origin_event_type, origin_event_id, origin_line_id),
    CONSTRAINT fk_stg_stock_event_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id)
);
COMMENT ON TABLE stg.stock_event IS
'One canonical physical event line in a load run, after all its representations were matched and found to agree. This is the unit that is published once to dw.fact_stock_movement.';
COMMENT ON COLUMN stg.stock_event.source_recorded_at IS
'Recording time in the originating source (the till or website for imported events), not the central import time.';

CREATE TABLE stg.order_line (
    load_run_id         bigint      NOT NULL,
    order_id            text        NOT NULL,
    line_id             text        NOT NULL,
    sku                 text        NOT NULL,
    location_code       text        NOT NULL,
    quantity            integer     NOT NULL,
    placed_at           timestamptz NOT NULL,
    source_recorded_at  timestamptz NOT NULL,
    fulfilment_type     text        NOT NULL,
    raw_record_id       bigint      NOT NULL,
    header_raw_record_id bigint     NOT NULL,
    CONSTRAINT pk_stg_order_line PRIMARY KEY (load_run_id, order_id, line_id),
    CONSTRAINT fk_stg_order_line_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id)
);
COMMENT ON TABLE stg.order_line IS
'One accepted online order line with matched SKU and canonical pickup/fulfilment location, in a load run.';

CREATE TABLE stg.order_status_event (
    load_run_id         bigint      NOT NULL,
    event_id            text        NOT NULL,
    order_id            text        NOT NULL,
    event_sequence      integer     NOT NULL,
    previous_status     text,
    new_status          text        NOT NULL,
    occurred_at         timestamptz NOT NULL,
    source_recorded_at  timestamptz NOT NULL,
    reason_code         text,
    corrects_event_id   text,
    raw_record_id       bigint      NOT NULL,
    CONSTRAINT pk_stg_order_status_event PRIMARY KEY (load_run_id, event_id),
    CONSTRAINT fk_stg_order_status_event_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id)
);
COMMENT ON TABLE stg.order_status_event IS
'One validated online order status event in a load run.';

CREATE TABLE stg.stock_snapshot (
    load_run_id       bigint      NOT NULL,
    snapshot_id       text        NOT NULL,
    sku               text        NOT NULL,
    location_code     text        NOT NULL,
    on_hand_quantity  integer     NOT NULL,
    cutoff_at         timestamptz NOT NULL,
    created_at        timestamptz NOT NULL,
    raw_record_id     bigint      NOT NULL,
    CONSTRAINT pk_stg_stock_snapshot PRIMARY KEY (load_run_id, snapshot_id, sku, location_code),
    CONSTRAINT fk_stg_stock_snapshot_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id)
);
COMMENT ON TABLE stg.stock_snapshot IS
'One validated central snapshot balance (opening-balance candidate) in a load run.';

CREATE TABLE stg.web_stock_copy (
    load_run_id         bigint      NOT NULL,
    copy_id             text        NOT NULL,
    sku                 text        NOT NULL,
    location_code       text        NOT NULL,
    on_hand_quantity    integer     NOT NULL,
    source_snapshot_id  text        NOT NULL,
    snapshot_cutoff_at  timestamptz NOT NULL,
    copied_at           timestamptz NOT NULL,
    raw_record_id       bigint      NOT NULL,
    CONSTRAINT pk_stg_web_stock_copy PRIMARY KEY (load_run_id, copy_id, sku, location_code),
    CONSTRAINT fk_stg_web_stock_copy_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id)
);
COMMENT ON TABLE stg.web_stock_copy IS
'One validated website stock copy balance with a canonical location, in a load run.';
