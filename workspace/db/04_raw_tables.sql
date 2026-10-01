-- =============================================================================
-- 04_raw_tables.sql
-- Purpose: Create one raw extraction table for each of the 19 source tables.
-- Prerequisites: 01_schemas.sql, 03_audit_tables.sql (audit.load_run).
-- Inputs: None.
-- Outputs: raw.<source prefix>_<source table> tables.
-- Execution: Applied by scripts/apply_schema.py.
-- Transaction: One transaction for the whole file (runner-owned).
-- Rerun behaviour: Not rerunnable; rebuild in a fresh isolated database.
-- Business rules: Architecture_and_Data_Model.md section 5.1.
--
-- Every raw table:
-- * keeps all source columns with compatible types but WITHOUT the source's
--   NOT NULL, foreign key or business CHECK constraints, so an incomplete or
--   invalid extract can still be recorded and then reported by validation;
-- * adds raw_record_id (primary key), load_run_id and extracted_at;
-- * is unique on (load_run_id, source primary key): one copy per source row per
--   run. A later run stores another copy; that is extraction evidence, not a
--   new business fact.
-- The unique index starts with load_run_id, so it also serves run-scoped reads.
-- Raw rows are never updated after extraction.
-- =============================================================================

-- ---------------------------------------------------------------- store sales
CREATE TABLE raw.store_sales_store (
    raw_record_id bigint GENERATED ALWAYS AS IDENTITY,
    load_run_id   bigint      NOT NULL,
    extracted_at  timestamptz NOT NULL,
    store_code    text,
    store_name    text,
    suburb        text,
    CONSTRAINT pk_raw_store_sales_store PRIMARY KEY (raw_record_id),
    CONSTRAINT fk_raw_store_sales_store_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id),
    CONSTRAINT uq_raw_store_sales_store UNIQUE (load_run_id, store_code)
);
COMMENT ON TABLE raw.store_sales_store IS 'Extracted copy of src_store_sales.store for one load run. Immutable evidence.';

CREATE TABLE raw.store_sales_product (
    raw_record_id bigint GENERATED ALWAYS AS IDENTITY,
    load_run_id   bigint      NOT NULL,
    extracted_at  timestamptz NOT NULL,
    barcode       text,
    product_name  text,
    unit_price    numeric(12,2),
    CONSTRAINT pk_raw_store_sales_product PRIMARY KEY (raw_record_id),
    CONSTRAINT fk_raw_store_sales_product_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id),
    CONSTRAINT uq_raw_store_sales_product UNIQUE (load_run_id, barcode)
);
COMMENT ON TABLE raw.store_sales_product IS 'Extracted copy of src_store_sales.product (till barcode list) for one load run. Immutable evidence.';

CREATE TABLE raw.store_sales_sale (
    raw_record_id bigint GENERATED ALWAYS AS IDENTITY,
    load_run_id   bigint      NOT NULL,
    extracted_at  timestamptz NOT NULL,
    sale_id       text,
    store_code    text,
    till_id       text,
    completed_at  timestamptz,
    recorded_at   timestamptz,
    CONSTRAINT pk_raw_store_sales_sale PRIMARY KEY (raw_record_id),
    CONSTRAINT fk_raw_store_sales_sale_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id),
    CONSTRAINT uq_raw_store_sales_sale UNIQUE (load_run_id, sale_id)
);
COMMENT ON TABLE raw.store_sales_sale IS 'Extracted copy of src_store_sales.sale (sale headers) for one load run. Immutable evidence.';

CREATE TABLE raw.store_sales_sale_line (
    raw_record_id bigint GENERATED ALWAYS AS IDENTITY,
    load_run_id   bigint      NOT NULL,
    extracted_at  timestamptz NOT NULL,
    sale_id       text,
    line_id       text,
    barcode       text,
    quantity      integer,
    unit_price    numeric(12,2),
    CONSTRAINT pk_raw_store_sales_sale_line PRIMARY KEY (raw_record_id),
    CONSTRAINT fk_raw_store_sales_sale_line_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id),
    CONSTRAINT uq_raw_store_sales_sale_line UNIQUE (load_run_id, sale_id, line_id)
);
COMMENT ON TABLE raw.store_sales_sale_line IS 'Extracted copy of src_store_sales.sale_line for one load run. Immutable evidence; the direct source of recent in-store stock reductions.';

-- ---------------------------------------------------------------- online orders
CREATE TABLE raw.online_fulfilment_location (
    raw_record_id bigint GENERATED ALWAYS AS IDENTITY,
    load_run_id   bigint      NOT NULL,
    extracted_at  timestamptz NOT NULL,
    location_code text,
    location_name text,
    location_type text,
    CONSTRAINT pk_raw_online_fulfilment_location PRIMARY KEY (raw_record_id),
    CONSTRAINT fk_raw_online_fulfilment_location_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id),
    CONSTRAINT uq_raw_online_fulfilment_location UNIQUE (load_run_id, location_code)
);
COMMENT ON TABLE raw.online_fulfilment_location IS 'Extracted copy of src_online.fulfilment_location for one load run. Immutable evidence.';

CREATE TABLE raw.online_web_order (
    raw_record_id   bigint GENERATED ALWAYS AS IDENTITY,
    load_run_id     bigint      NOT NULL,
    extracted_at    timestamptz NOT NULL,
    order_id        text,
    placed_at       timestamptz,
    recorded_at     timestamptz,
    fulfilment_type text,
    location_code   text,
    current_status  text,
    updated_at      timestamptz,
    CONSTRAINT pk_raw_online_web_order PRIMARY KEY (raw_record_id),
    CONSTRAINT fk_raw_online_web_order_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id),
    CONSTRAINT uq_raw_online_web_order UNIQUE (load_run_id, order_id)
);
COMMENT ON TABLE raw.online_web_order IS 'Extracted copy of src_online.web_order (current order state) for one load run. Immutable evidence.';

CREATE TABLE raw.online_web_order_line (
    raw_record_id bigint GENERATED ALWAYS AS IDENTITY,
    load_run_id   bigint      NOT NULL,
    extracted_at  timestamptz NOT NULL,
    order_id      text,
    line_id       text,
    sku           text,
    quantity      integer,
    CONSTRAINT pk_raw_online_web_order_line PRIMARY KEY (raw_record_id),
    CONSTRAINT fk_raw_online_web_order_line_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id),
    CONSTRAINT uq_raw_online_web_order_line UNIQUE (load_run_id, order_id, line_id)
);
COMMENT ON TABLE raw.online_web_order_line IS 'Extracted copy of src_online.web_order_line for one load run. Immutable evidence.';

CREATE TABLE raw.online_order_status_history (
    raw_record_id     bigint GENERATED ALWAYS AS IDENTITY,
    load_run_id       bigint      NOT NULL,
    extracted_at      timestamptz NOT NULL,
    event_id          text,
    order_id          text,
    event_sequence    integer,
    previous_status   text,
    new_status        text,
    occurred_at       timestamptz,
    recorded_at       timestamptz,
    reason_code       text,
    corrects_event_id text,
    CONSTRAINT pk_raw_online_order_status_history PRIMARY KEY (raw_record_id),
    CONSTRAINT fk_raw_online_order_status_history_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id),
    CONSTRAINT uq_raw_online_order_status_history UNIQUE (load_run_id, event_id)
);
COMMENT ON TABLE raw.online_order_status_history IS 'Extracted copy of src_online.order_status_history for one load run. Immutable evidence; collected/shipped events are the direct source of online physical reductions.';

CREATE TABLE raw.online_web_stock_copy (
    raw_record_id      bigint GENERATED ALWAYS AS IDENTITY,
    load_run_id        bigint      NOT NULL,
    extracted_at       timestamptz NOT NULL,
    copy_id            text,
    sku                text,
    location_code      text,
    on_hand_quantity   integer,
    source_snapshot_id text,
    snapshot_cutoff_at timestamptz,
    copied_at          timestamptz,
    CONSTRAINT pk_raw_online_web_stock_copy PRIMARY KEY (raw_record_id),
    CONSTRAINT fk_raw_online_web_stock_copy_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id),
    CONSTRAINT uq_raw_online_web_stock_copy UNIQUE (load_run_id, copy_id, sku, location_code)
);
COMMENT ON TABLE raw.online_web_stock_copy IS 'Extracted copy of src_online.web_stock_copy for one load run. Immutable evidence of the stock basis the website used.';

-- ---------------------------------------------------------------- central stock
CREATE TABLE raw.stock_product (
    raw_record_id bigint GENERATED ALWAYS AS IDENTITY,
    load_run_id   bigint      NOT NULL,
    extracted_at  timestamptz NOT NULL,
    sku           text,
    product_name  text,
    brand         text,
    category      text,
    pack_size     numeric(12,3),
    pack_unit     text,
    is_active     boolean,
    CONSTRAINT pk_raw_stock_product PRIMARY KEY (raw_record_id),
    CONSTRAINT fk_raw_stock_product_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id),
    CONSTRAINT uq_raw_stock_product UNIQUE (load_run_id, sku)
);
COMMENT ON TABLE raw.stock_product IS 'Extracted copy of src_stock.product for one load run. Immutable evidence.';

CREATE TABLE raw.stock_product_barcode (
    raw_record_id bigint GENERATED ALWAYS AS IDENTITY,
    load_run_id   bigint      NOT NULL,
    extracted_at  timestamptz NOT NULL,
    barcode       text,
    sku           text,
    CONSTRAINT pk_raw_stock_product_barcode PRIMARY KEY (raw_record_id),
    CONSTRAINT fk_raw_stock_product_barcode_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id),
    CONSTRAINT uq_raw_stock_product_barcode UNIQUE (load_run_id, barcode)
);
COMMENT ON TABLE raw.stock_product_barcode IS 'Extracted copy of src_stock.product_barcode for one load run. Source of the approved barcode-to-SKU mappings.';

CREATE TABLE raw.stock_location (
    raw_record_id bigint GENERATED ALWAYS AS IDENTITY,
    load_run_id   bigint      NOT NULL,
    extracted_at  timestamptz NOT NULL,
    location_code text,
    location_name text,
    location_type text,
    suburb        text,
    CONSTRAINT pk_raw_stock_location PRIMARY KEY (raw_record_id),
    CONSTRAINT fk_raw_stock_location_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id),
    CONSTRAINT uq_raw_stock_location UNIQUE (load_run_id, location_code)
);
COMMENT ON TABLE raw.stock_location IS 'Extracted copy of src_stock.location for one load run. Immutable evidence.';

CREATE TABLE raw.stock_external_location_code (
    raw_record_id bigint GENERATED ALWAYS AS IDENTITY,
    load_run_id   bigint      NOT NULL,
    extracted_at  timestamptz NOT NULL,
    system_code   text,
    external_code text,
    location_code text,
    CONSTRAINT pk_raw_stock_external_location_code PRIMARY KEY (raw_record_id),
    CONSTRAINT fk_raw_stock_external_location_code_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id),
    CONSTRAINT uq_raw_stock_external_location_code UNIQUE (load_run_id, system_code, external_code)
);
COMMENT ON TABLE raw.stock_external_location_code IS 'Extracted copy of src_stock.external_location_code for one load run. Kept as evidence only; integration uses ref.location_identifier.';

CREATE TABLE raw.stock_stock_transfer (
    raw_record_id             bigint GENERATED ALWAYS AS IDENTITY,
    load_run_id               bigint      NOT NULL,
    extracted_at              timestamptz NOT NULL,
    transfer_id               text,
    origin_location_code      text,
    destination_location_code text,
    created_at                timestamptz,
    current_status            text,
    CONSTRAINT pk_raw_stock_stock_transfer PRIMARY KEY (raw_record_id),
    CONSTRAINT fk_raw_stock_stock_transfer_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id),
    CONSTRAINT uq_raw_stock_stock_transfer UNIQUE (load_run_id, transfer_id)
);
COMMENT ON TABLE raw.stock_stock_transfer IS 'Extracted copy of src_stock.stock_transfer for one load run. Supporting evidence; transfers create no movement by themselves.';

CREATE TABLE raw.stock_stock_transfer_line (
    raw_record_id bigint GENERATED ALWAYS AS IDENTITY,
    load_run_id   bigint      NOT NULL,
    extracted_at  timestamptz NOT NULL,
    transfer_id   text,
    line_id       text,
    sku           text,
    quantity      integer,
    CONSTRAINT pk_raw_stock_stock_transfer_line PRIMARY KEY (raw_record_id),
    CONSTRAINT fk_raw_stock_stock_transfer_line_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id),
    CONSTRAINT uq_raw_stock_stock_transfer_line UNIQUE (load_run_id, transfer_id, line_id)
);
COMMENT ON TABLE raw.stock_stock_transfer_line IS 'Extracted copy of src_stock.stock_transfer_line for one load run. Supporting evidence only.';

CREATE TABLE raw.stock_stock_movement (
    raw_record_id        bigint GENERATED ALWAYS AS IDENTITY,
    load_run_id          bigint      NOT NULL,
    extracted_at         timestamptz NOT NULL,
    movement_id          text,
    sku                  text,
    location_code        text,
    movement_type        text,
    quantity             integer,
    occurred_at          timestamptz,
    recorded_at          timestamptz,
    origin_system_code   text,
    origin_event_type    text,
    origin_event_id      text,
    origin_line_id       text,
    transfer_id          text,
    transfer_line_id     text,
    delivery_reference   text,
    supplier_reference   text,
    reason_code          text,
    reverses_movement_id text,
    CONSTRAINT pk_raw_stock_stock_movement PRIMARY KEY (raw_record_id),
    CONSTRAINT fk_raw_stock_stock_movement_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id),
    CONSTRAINT uq_raw_stock_stock_movement UNIQUE (load_run_id, movement_id)
);
COMMENT ON TABLE raw.stock_stock_movement IS 'Extracted copy of src_stock.stock_movement for one load run. Local movements are direct evidence; imported sale/collection rows are additional representations of an original event.';

CREATE TABLE raw.stock_stock_on_hand (
    raw_record_id    bigint GENERATED ALWAYS AS IDENTITY,
    load_run_id      bigint      NOT NULL,
    extracted_at     timestamptz NOT NULL,
    sku              text,
    location_code    text,
    on_hand_quantity integer,
    updated_at       timestamptz,
    CONSTRAINT pk_raw_stock_stock_on_hand PRIMARY KEY (raw_record_id),
    CONSTRAINT fk_raw_stock_stock_on_hand_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id),
    CONSTRAINT uq_raw_stock_stock_on_hand UNIQUE (load_run_id, sku, location_code)
);
COMMENT ON TABLE raw.stock_stock_on_hand IS 'Extracted copy of central current recorded balances for one load run. Kept as evidence of what central showed at the checkpoint; not used as an opening balance.';

CREATE TABLE raw.stock_stock_snapshot (
    raw_record_id    bigint GENERATED ALWAYS AS IDENTITY,
    load_run_id      bigint      NOT NULL,
    extracted_at     timestamptz NOT NULL,
    snapshot_id      text,
    sku              text,
    location_code    text,
    on_hand_quantity integer,
    cutoff_at        timestamptz,
    created_at       timestamptz,
    CONSTRAINT pk_raw_stock_stock_snapshot PRIMARY KEY (raw_record_id),
    CONSTRAINT fk_raw_stock_stock_snapshot_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id),
    CONSTRAINT uq_raw_stock_stock_snapshot UNIQUE (load_run_id, snapshot_id, sku, location_code)
);
COMMENT ON TABLE raw.stock_stock_snapshot IS 'Extracted copy of src_stock.stock_snapshot for one load run. Source of opening balances.';

CREATE TABLE raw.stock_movement_application (
    raw_record_id bigint GENERATED ALWAYS AS IDENTITY,
    load_run_id   bigint      NOT NULL,
    extracted_at  timestamptz NOT NULL,
    movement_id   text,
    applied_at    timestamptz,
    CONSTRAINT pk_raw_stock_movement_application PRIMARY KEY (raw_record_id),
    CONSTRAINT fk_raw_stock_movement_application_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id),
    CONSTRAINT uq_raw_stock_movement_application UNIQUE (load_run_id, movement_id)
);
COMMENT ON TABLE raw.stock_movement_application IS 'Extracted copy of src_stock.movement_application for one load run. Evidence of which movements central had applied to its current balances.';
