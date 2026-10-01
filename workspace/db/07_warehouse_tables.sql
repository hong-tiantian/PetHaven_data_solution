-- =============================================================================
-- 07_warehouse_tables.sql
-- Purpose: Create the integrated dimensional warehouse: shared product,
--          location and date dimensions, and five fact tables.
-- Prerequisites: 01_schemas.sql, 03_audit_tables.sql.
-- Inputs: None (facts are published by db/etl/load_warehouse.sql).
-- Outputs: dw dimensions, facts, indexes and the dw.sydney_date_key function.
-- Execution: Applied by scripts/apply_schema.py.
-- Transaction: One transaction for the whole file (runner-owned).
-- Rerun behaviour: Not rerunnable; rebuild in a fresh isolated database.
-- Business rules: Architecture_and_Data_Model.md section 7.
--
-- Fact rules
-- * Facts are append-only. A repeat extraction of the same business identity is
--   a no-op after an equality check; conflicting content is rejected during
--   validation and never overwrites a fact.
-- * Exact timestamps stay on the facts; the date key alone is too coarse for
--   the scenarios. Date keys use the Sydney business date.
-- * Facts reference dimensions with surrogate keys and never depend on live
--   source rows through foreign keys.
-- * Stock balances (snapshot and copy facts) are additive across products and
--   locations but NOT across time: never sum daily snapshots.
-- =============================================================================

-- Sydney business date of an instant, as a YYYYMMDD integer key. STABLE rather
-- than IMMUTABLE because time-zone rules can change with tzdata updates.
CREATE FUNCTION dw.sydney_date_key(p_at timestamptz)
RETURNS integer
LANGUAGE sql
STABLE
AS $$
    SELECT to_char((p_at AT TIME ZONE 'Australia/Sydney')::date, 'YYYYMMDD')::integer;
$$;
COMMENT ON FUNCTION dw.sydney_date_key(timestamptz) IS
'Returns the Sydney calendar date of p_at as an integer YYYYMMDD key for dw.dim_date. No side effects; returns null for a null input.';

-- ------------------------------------------------------------------ dimensions
CREATE TABLE dw.dim_date (
    date_key     integer NOT NULL,
    full_date    date    NOT NULL,
    year_number  integer NOT NULL,
    month_number integer NOT NULL,
    day_number   integer NOT NULL,
    iso_weekday  integer NOT NULL,
    weekday_name text    NOT NULL,
    CONSTRAINT pk_dim_date PRIMARY KEY (date_key),
    CONSTRAINT uq_dim_date_full_date UNIQUE (full_date)
);
COMMENT ON TABLE dw.dim_date IS
'One Sydney calendar date. Static reference dimension pre-filled for 2026-2027, which covers every synthetic scenario date.';

INSERT INTO dw.dim_date (date_key, full_date, year_number, month_number, day_number, iso_weekday, weekday_name)
SELECT to_char(d, 'YYYYMMDD')::integer,
       d::date,
       extract(year FROM d)::integer,
       extract(month FROM d)::integer,
       extract(day FROM d)::integer,
       extract(isodow FROM d)::integer,
       trim(to_char(d, 'Day'))
FROM generate_series(date '2026-01-01', date '2027-12-31', interval '1 day') AS g(d);

CREATE TABLE dw.dim_product (
    product_key        bigint GENERATED ALWAYS AS IDENTITY,
    sku                text          NOT NULL,
    product_name       text          NOT NULL,
    brand              text          NOT NULL,
    category           text          NOT NULL,
    pack_size          numeric(12,3) NOT NULL,
    pack_unit          text          NOT NULL,
    is_active          boolean       NOT NULL,
    first_load_run_id  bigint        NOT NULL,
    CONSTRAINT pk_dim_product PRIMARY KEY (product_key),
    CONSTRAINT uq_dim_product_sku UNIQUE (sku),
    CONSTRAINT fk_dim_product_first_run FOREIGN KEY (first_load_run_id) REFERENCES audit.load_run (load_run_id)
);
COMMENT ON TABLE dw.dim_product IS
'One PetHaven product, keyed by surrogate product_key with SKU as business key. Attributes are fixed during the scenarios; no slowly changing dimension history is kept (Arch 7.1).';

CREATE TABLE dw.dim_location (
    location_key       bigint GENERATED ALWAYS AS IDENTITY,
    location_code      text   NOT NULL,
    location_name      text   NOT NULL,
    location_type      text   NOT NULL,
    suburb             text   NOT NULL,
    first_load_run_id  bigint NOT NULL,
    CONSTRAINT pk_dim_location PRIMARY KEY (location_key),
    CONSTRAINT uq_dim_location_code UNIQUE (location_code),
    CONSTRAINT fk_dim_location_first_run FOREIGN KEY (first_load_run_id) REFERENCES audit.load_run (load_run_id),
    CONSTRAINT ck_dim_location_type CHECK (location_type IN ('store', 'dc'))
);
COMMENT ON TABLE dw.dim_location IS
'One store or the DC, keyed by surrogate location_key with the canonical central code as business key. The DC is a location type, not a sales channel.';

-- ----------------------------------------------------------------------- facts
CREATE TABLE dw.fact_stock_movement (
    movement_key          bigint GENERATED ALWAYS AS IDENTITY,
    origin_system_code    text        NOT NULL,
    origin_event_type     text        NOT NULL,
    origin_event_id       text        NOT NULL,
    origin_line_id        text        NOT NULL,
    product_key           bigint      NOT NULL,
    location_key          bigint      NOT NULL,
    event_date_key        integer     NOT NULL,
    movement_type         text        NOT NULL,
    quantity              integer     NOT NULL,
    occurred_at           timestamptz NOT NULL,
    source_recorded_at    timestamptz NOT NULL,
    order_id              text,
    order_line_id         text,
    transfer_id           text,
    transfer_line_id      text,
    delivery_reference    text,
    supplier_reference    text,
    reason_code           text,
    reverses_movement_key bigint,
    first_load_run_id     bigint      NOT NULL,
    warehouse_loaded_at   timestamptz NOT NULL,
    CONSTRAINT pk_fact_stock_movement PRIMARY KEY (movement_key),
    -- One fact per original physical event line: the core double-count guard.
    CONSTRAINT uq_fact_stock_movement_origin UNIQUE
        (origin_system_code, origin_event_type, origin_event_id, origin_line_id),
    CONSTRAINT fk_fact_stock_movement_product FOREIGN KEY (product_key) REFERENCES dw.dim_product (product_key),
    CONSTRAINT fk_fact_stock_movement_location FOREIGN KEY (location_key) REFERENCES dw.dim_location (location_key),
    CONSTRAINT fk_fact_stock_movement_date FOREIGN KEY (event_date_key) REFERENCES dw.dim_date (date_key),
    CONSTRAINT fk_fact_stock_movement_reverses FOREIGN KEY (reverses_movement_key) REFERENCES dw.fact_stock_movement (movement_key),
    CONSTRAINT fk_fact_stock_movement_first_run FOREIGN KEY (first_load_run_id) REFERENCES audit.load_run (load_run_id),
    CONSTRAINT ck_fact_stock_movement_quantity CHECK (quantity <> 0)
);
COMMENT ON TABLE dw.fact_stock_movement IS
'One original physical stock event line (till sale line, online collection line, receipt, transfer dispatch or receipt, adjustment or reversal). Grain: unique four-part origin identity. Append-only. A till sale and its later central import are one fact.';
COMMENT ON COLUMN dw.fact_stock_movement.quantity IS
'Signed change in whole sellable units at one location. Positive values add stock; negative values remove stock. Reservations are not physical movements.';
COMMENT ON COLUMN dw.fact_stock_movement.source_recorded_at IS
'Time the originating source recorded the event (till, website or central), not the central import time and not the warehouse load time.';
COMMENT ON COLUMN dw.fact_stock_movement.first_load_run_id IS
'Load run that first published this fact. Never changed by a repeat extraction; used to decide which facts a selected load could see.';
COMMENT ON COLUMN dw.fact_stock_movement.warehouse_loaded_at IS
'Actual wall-clock insertion time. Not a business time.';

CREATE TABLE dw.fact_order_line (
    order_line_key      bigint GENERATED ALWAYS AS IDENTITY,
    order_id            text        NOT NULL,
    line_id             text        NOT NULL,
    product_key         bigint      NOT NULL,
    location_key        bigint      NOT NULL,
    placed_date_key     integer     NOT NULL,
    quantity            integer     NOT NULL,
    placed_at           timestamptz NOT NULL,
    source_recorded_at  timestamptz NOT NULL,
    fulfilment_type     text        NOT NULL,
    first_load_run_id   bigint      NOT NULL,
    warehouse_loaded_at timestamptz NOT NULL,
    CONSTRAINT pk_fact_order_line PRIMARY KEY (order_line_key),
    CONSTRAINT uq_fact_order_line UNIQUE (order_id, line_id),
    CONSTRAINT fk_fact_order_line_product FOREIGN KEY (product_key) REFERENCES dw.dim_product (product_key),
    CONSTRAINT fk_fact_order_line_location FOREIGN KEY (location_key) REFERENCES dw.dim_location (location_key),
    CONSTRAINT fk_fact_order_line_date FOREIGN KEY (placed_date_key) REFERENCES dw.dim_date (date_key),
    CONSTRAINT fk_fact_order_line_first_run FOREIGN KEY (first_load_run_id) REFERENCES audit.load_run (load_run_id),
    CONSTRAINT ck_fact_order_line_quantity CHECK (quantity > 0),
    CONSTRAINT ck_fact_order_line_fulfilment_type CHECK (fulfilment_type IN ('click_collect', 'home_delivery'))
);
COMMENT ON TABLE dw.fact_order_line IS
'One accepted online order line. Grain: (order_id, line_id). Whether the line reserves stock at a time is derived from fact_order_status_event; the line itself never changes.';

CREATE TABLE dw.fact_order_status_event (
    order_status_key    bigint GENERATED ALWAYS AS IDENTITY,
    event_id            text        NOT NULL,
    order_id            text        NOT NULL,
    event_sequence      integer     NOT NULL,
    event_date_key      integer     NOT NULL,
    previous_status     text,
    new_status          text        NOT NULL,
    reason_code         text,
    corrects_event_id   text,
    occurred_at         timestamptz NOT NULL,
    source_recorded_at  timestamptz NOT NULL,
    first_load_run_id   bigint      NOT NULL,
    warehouse_loaded_at timestamptz NOT NULL,
    CONSTRAINT pk_fact_order_status_event PRIMARY KEY (order_status_key),
    CONSTRAINT uq_fact_order_status_event_id UNIQUE (event_id),
    CONSTRAINT uq_fact_order_status_event_sequence UNIQUE (order_id, event_sequence),
    CONSTRAINT fk_fact_order_status_event_date FOREIGN KEY (event_date_key) REFERENCES dw.dim_date (date_key),
    CONSTRAINT fk_fact_order_status_event_first_run FOREIGN KEY (first_load_run_id) REFERENCES audit.load_run (load_run_id)
);
COMMENT ON TABLE dw.fact_order_status_event IS
'One online order status transition. Grain: event_id. Stored once per order, not per line: reports pick one effective status per order before joining to lines, otherwise quantities would be multiplied.';

CREATE TABLE dw.fact_stock_snapshot (
    snapshot_key        bigint GENERATED ALWAYS AS IDENTITY,
    snapshot_id         text        NOT NULL,
    product_key         bigint      NOT NULL,
    location_key        bigint      NOT NULL,
    cutoff_date_key     integer     NOT NULL,
    on_hand_quantity    integer     NOT NULL,
    cutoff_at           timestamptz NOT NULL,
    created_at          timestamptz NOT NULL,
    first_load_run_id   bigint      NOT NULL,
    warehouse_loaded_at timestamptz NOT NULL,
    CONSTRAINT pk_fact_stock_snapshot PRIMARY KEY (snapshot_key),
    CONSTRAINT uq_fact_stock_snapshot UNIQUE (snapshot_id, product_key, location_key),
    CONSTRAINT fk_fact_stock_snapshot_product FOREIGN KEY (product_key) REFERENCES dw.dim_product (product_key),
    CONSTRAINT fk_fact_stock_snapshot_location FOREIGN KEY (location_key) REFERENCES dw.dim_location (location_key),
    CONSTRAINT fk_fact_stock_snapshot_date FOREIGN KEY (cutoff_date_key) REFERENCES dw.dim_date (date_key),
    CONSTRAINT fk_fact_stock_snapshot_first_run FOREIGN KEY (first_load_run_id) REFERENCES audit.load_run (load_run_id)
);
COMMENT ON TABLE dw.fact_stock_snapshot IS
'One reconciled opening balance for a product/location at a cutoff (periodic snapshot fact). Semi-additive: never sum across cutoffs.';

CREATE TABLE dw.fact_web_stock_copy (
    web_copy_key        bigint GENERATED ALWAYS AS IDENTITY,
    copy_id             text        NOT NULL,
    product_key         bigint      NOT NULL,
    location_key        bigint      NOT NULL,
    copy_date_key       integer     NOT NULL,
    on_hand_quantity    integer     NOT NULL,
    source_snapshot_id  text        NOT NULL,
    snapshot_cutoff_at  timestamptz NOT NULL,
    copied_at           timestamptz NOT NULL,
    first_load_run_id   bigint      NOT NULL,
    warehouse_loaded_at timestamptz NOT NULL,
    CONSTRAINT pk_fact_web_stock_copy PRIMARY KEY (web_copy_key),
    CONSTRAINT uq_fact_web_stock_copy UNIQUE (copy_id, product_key, location_key),
    CONSTRAINT fk_fact_web_stock_copy_product FOREIGN KEY (product_key) REFERENCES dw.dim_product (product_key),
    CONSTRAINT fk_fact_web_stock_copy_location FOREIGN KEY (location_key) REFERENCES dw.dim_location (location_key),
    CONSTRAINT fk_fact_web_stock_copy_date FOREIGN KEY (copy_date_key) REFERENCES dw.dim_date (date_key),
    CONSTRAINT fk_fact_web_stock_copy_first_run FOREIGN KEY (first_load_run_id) REFERENCES audit.load_run (load_run_id)
);
COMMENT ON TABLE dw.fact_web_stock_copy IS
'One product/location balance copied by a website refresh. Retains the copied snapshot cutoff so the website baseline can be recalculated exactly as the existing website did.';

-- --------------------------------------------------------------------- indexes
-- Access paths used by rpt.calculate_inventory and the website baseline: each
-- calculation filters one product/location and a time interval.
CREATE INDEX ix_fact_stock_movement_product_location_time
    ON dw.fact_stock_movement (product_key, location_key, occurred_at);
CREATE INDEX ix_fact_stock_snapshot_product_location_cutoff
    ON dw.fact_stock_snapshot (product_key, location_key, cutoff_at);
CREATE INDEX ix_fact_web_stock_copy_product_location_copied
    ON dw.fact_web_stock_copy (product_key, location_key, copied_at);
-- Allocation orders active lines by acceptance time and order ID per pair.
CREATE INDEX ix_fact_order_line_location_product_placed
    ON dw.fact_order_line (location_key, product_key, placed_at, order_id);
-- Effective status lookup: last event per order at or before a time.
CREATE INDEX ix_fact_order_status_event_order_time
    ON dw.fact_order_status_event (order_id, occurred_at, event_sequence);
