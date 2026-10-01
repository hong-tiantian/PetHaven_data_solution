-- =============================================================================
-- 02_source_tables.sql
-- Purpose: Create the tables of the three simulated business sources:
--          store sales (tills), online orders (website) and central stock.
-- Prerequisites: 01_schemas.sql.
-- Inputs: None.
-- Outputs: Source tables with keys, row-level checks and catalogue comments.
-- Execution: Applied by scripts/apply_schema.py after 01_schemas.sql.
-- Transaction: One transaction for the whole file (runner-owned).
-- Rerun behaviour: Not rerunnable; rebuild in a fresh isolated database.
-- Business rules: Spec sections 4.1-4.3; Architecture_and_Data_Model.md
--                 section 4.
--
-- Design notes
-- * Source foreign keys stay inside their own source schema. Identifiers that
--   refer to another source (for example an online order line's SKU) are plain
--   text and are only matched later by the integration layer (ref schema).
-- * Row-level CHECK constraints cannot enforce cross-row rules such as
--   "every sale has at least one line". Those rules are enforced by the source
--   write procedures in db/source_actions/ and verified by the integration
--   validation in db/etl/validate_sources.sql.
-- * Identifiers and codes are text so that leading zeros (store code 0123,
--   barcode 0930000102310) are preserved exactly.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Source 1: store sales database (in-store POS tills)
-- -----------------------------------------------------------------------------

CREATE TABLE src_store_sales.store (
    store_code  text NOT NULL,
    store_name  text NOT NULL,
    suburb      text NOT NULL,
    CONSTRAINT pk_store PRIMARY KEY (store_code)
);
COMMENT ON TABLE src_store_sales.store IS
'One store known to the tills. Current reference data maintained by the POS system. The till store code is not the central location code; integration maps it through ref.location_identifier.';
COMMENT ON COLUMN src_store_sales.store.store_code IS
'Till store code, for example 0123 for Parramatta. Text, so leading zeros are preserved.';

CREATE TABLE src_store_sales.product (
    barcode       text          NOT NULL,
    product_name  text          NOT NULL,
    unit_price    numeric(12,2) NOT NULL,
    CONSTRAINT pk_product PRIMARY KEY (barcode),
    CONSTRAINT ck_product_unit_price CHECK (unit_price >= 0)
);
COMMENT ON TABLE src_store_sales.product IS
'One barcode recognised by the tills, with its description and shelf price. Current reference data. A barcode can exist here before central stock knows it; integration flags such a barcode as unmatched rather than guessing a product.';

CREATE TABLE src_store_sales.sale (
    sale_id       text        NOT NULL,
    store_code    text        NOT NULL,
    till_id       text        NOT NULL,
    completed_at  timestamptz NOT NULL,
    recorded_at   timestamptz NOT NULL,
    CONSTRAINT pk_sale PRIMARY KEY (sale_id),
    CONSTRAINT fk_sale_store FOREIGN KEY (store_code)
        REFERENCES src_store_sales.store (store_code),
    -- A connected till saves the sale when it completes, never before.
    CONSTRAINT ck_sale_recorded_after_completion CHECK (recorded_at >= completed_at)
);
COMMENT ON TABLE src_store_sales.sale IS
'One completed till purchase (sale header). Immutable event history: a completed sale is never edited. Scanning without completing payment creates no row.';
COMMENT ON COLUMN src_store_sales.sale.completed_at IS
'Business time at which payment succeeded and the goods left with the customer. Physical stock falls at this time.';
COMMENT ON COLUMN src_store_sales.sale.recorded_at IS
'Time the store sales database saved the sale. Equal to completed_at for connected tills in this prototype.';

CREATE TABLE src_store_sales.sale_line (
    sale_id     text          NOT NULL,
    line_id     text          NOT NULL,
    barcode     text          NOT NULL,
    quantity    integer       NOT NULL,
    unit_price  numeric(12,2) NOT NULL,
    CONSTRAINT pk_sale_line PRIMARY KEY (sale_id, line_id),
    CONSTRAINT fk_sale_line_sale FOREIGN KEY (sale_id)
        REFERENCES src_store_sales.sale (sale_id),
    CONSTRAINT fk_sale_line_product FOREIGN KEY (barcode)
        REFERENCES src_store_sales.product (barcode),
    CONSTRAINT ck_sale_line_quantity CHECK (quantity > 0),
    CONSTRAINT ck_sale_line_unit_price CHECK (unit_price >= 0)
);
COMMENT ON TABLE src_store_sales.sale_line IS
'One product line within a completed sale. Immutable event history. Each line reduces physical stock by its quantity at the sale completion time.';
COMMENT ON COLUMN src_store_sales.sale_line.quantity IS
'Positive number of whole sellable packs sold. The stock reduction sign is applied during integration.';


-- -----------------------------------------------------------------------------
-- Source 2: online orders database (website / app / order management)
-- -----------------------------------------------------------------------------

CREATE TABLE src_online.fulfilment_location (
    location_code  text NOT NULL,
    location_name  text NOT NULL,
    location_type  text NOT NULL,
    CONSTRAINT pk_fulfilment_location PRIMARY KEY (location_code),
    CONSTRAINT ck_fulfilment_location_type CHECK (location_type IN ('store', 'dc'))
);
COMMENT ON TABLE src_online.fulfilment_location IS
'One pickup store or the distribution centre as known to the online store. Current reference data. Codes such as store-parramatta differ from till and central codes.';

CREATE TABLE src_online.web_order (
    order_id          text        NOT NULL,
    placed_at         timestamptz NOT NULL,
    recorded_at       timestamptz NOT NULL,
    fulfilment_type   text        NOT NULL,
    location_code     text        NOT NULL,
    current_status    text        NOT NULL,
    updated_at        timestamptz NOT NULL,
    CONSTRAINT pk_web_order PRIMARY KEY (order_id),
    CONSTRAINT fk_web_order_location FOREIGN KEY (location_code)
        REFERENCES src_online.fulfilment_location (location_code),
    CONSTRAINT ck_web_order_fulfilment_type
        CHECK (fulfilment_type IN ('click_collect', 'home_delivery')),
    CONSTRAINT ck_web_order_status
        CHECK (current_status IN ('awaiting_pick', 'ready', 'collected', 'shipped', 'cancelled')),
    -- Click & Collect ends in collection; home delivery ends in shipment.
    CONSTRAINT ck_web_order_terminal_status_matches_type CHECK (
        NOT (fulfilment_type = 'click_collect' AND current_status = 'shipped')
        AND NOT (fulfilment_type = 'home_delivery' AND current_status = 'collected')
    )
);
COMMENT ON TABLE src_online.web_order IS
'One accepted online order and its current state. Current transaction record: current_status and updated_at change as staff work the order; order_status_history keeps every change.';
COMMENT ON COLUMN src_online.web_order.location_code IS
'Selected fulfilment location: the pickup store for Click & Collect, the DC for home delivery. Fixed after acceptance.';
COMMENT ON COLUMN src_online.web_order.current_status IS
'Latest status. A validation aid only; historical calculations use order_status_history at the observation time.';

CREATE TABLE src_online.web_order_line (
    order_id  text    NOT NULL,
    line_id   text    NOT NULL,
    sku       text    NOT NULL,
    quantity  integer NOT NULL,
    CONSTRAINT pk_web_order_line PRIMARY KEY (order_id, line_id),
    CONSTRAINT fk_web_order_line_order FOREIGN KEY (order_id)
        REFERENCES src_online.web_order (order_id),
    -- One line per SKU keeps allocation per order and product unambiguous.
    CONSTRAINT uq_web_order_line_order_sku UNIQUE (order_id, sku),
    CONSTRAINT ck_web_order_line_quantity CHECK (quantity > 0)
);
COMMENT ON TABLE src_online.web_order_line IS
'One product line in an accepted online order. Fixed after acceptance in this prototype; each line follows its order status (no partial collection). Active reservations are derived from these lines.';
COMMENT ON COLUMN src_online.web_order_line.sku IS
'PetHaven SKU as used by the website. Not a foreign key: the online source has no product table; integration matches it against central products.';

CREATE TABLE src_online.order_status_history (
    event_id           text        NOT NULL,
    order_id           text        NOT NULL,
    event_sequence     integer     NOT NULL,
    previous_status    text,
    new_status         text        NOT NULL,
    occurred_at        timestamptz NOT NULL,
    recorded_at        timestamptz NOT NULL,
    reason_code        text,
    corrects_event_id  text,
    CONSTRAINT pk_order_status_history PRIMARY KEY (event_id),
    CONSTRAINT fk_order_status_history_order FOREIGN KEY (order_id)
        REFERENCES src_online.web_order (order_id),
    CONSTRAINT fk_order_status_history_corrects FOREIGN KEY (corrects_event_id)
        REFERENCES src_online.order_status_history (event_id),
    CONSTRAINT uq_order_status_history_sequence UNIQUE (order_id, event_sequence),
    CONSTRAINT ck_order_status_history_sequence CHECK (event_sequence >= 1),
    CONSTRAINT ck_order_status_history_new_status
        CHECK (new_status IN ('awaiting_pick', 'ready', 'collected', 'shipped', 'cancelled')),
    -- The first event is the acceptance and has no previous status; every
    -- later event names the status it replaced.
    CONSTRAINT ck_order_status_history_first_event CHECK (
        (event_sequence = 1 AND previous_status IS NULL AND new_status = 'awaiting_pick')
        OR (event_sequence > 1 AND previous_status IS NOT NULL)
    ),
    CONSTRAINT ck_order_status_history_cancel_reason
        CHECK (new_status <> 'cancelled' OR reason_code IS NOT NULL),
    CONSTRAINT ck_order_status_history_reason_code
        CHECK (reason_code IS NULL OR reason_code IN ('insufficient_stock', 'customer_request', 'other')),
    CONSTRAINT ck_order_status_history_recorded
        CHECK (recorded_at >= occurred_at)
);
COMMENT ON TABLE src_online.order_status_history IS
'One recorded status transition per online order event. History is retained; corrections append an explicitly linked event rather than overwrite an earlier transition.';
COMMENT ON COLUMN src_online.order_status_history.occurred_at IS
'Business time at which the status transition took effect. Used with event_sequence to reconstruct order state at an observation time.';
COMMENT ON COLUMN src_online.order_status_history.recorded_at IS
'Time the online source recorded this transition. Distinct from its business occurrence time and the later warehouse load time.';
COMMENT ON COLUMN src_online.order_status_history.reason_code IS
'Required for cancellations: insufficient_stock separates stock-related cancellations from customer_request (change of mind).';
COMMENT ON COLUMN src_online.order_status_history.corrects_event_id IS
'Reserved for an explicitly linked correction event. Order-status correction is not implemented in this prototype; the write procedure rejects it visibly.';

CREATE TABLE src_online.web_stock_copy (
    copy_id             text        NOT NULL,
    sku                 text        NOT NULL,
    location_code       text        NOT NULL,
    on_hand_quantity    integer     NOT NULL,
    source_snapshot_id  text        NOT NULL,
    snapshot_cutoff_at  timestamptz NOT NULL,
    copied_at           timestamptz NOT NULL,
    CONSTRAINT pk_web_stock_copy PRIMARY KEY (copy_id, sku, location_code),
    CONSTRAINT fk_web_stock_copy_location FOREIGN KEY (location_code)
        REFERENCES src_online.fulfilment_location (location_code),
    CONSTRAINT ck_web_stock_copy_quantity CHECK (on_hand_quantity >= 0),
    -- A copy is taken after the snapshot cutoff it copies, never before.
    CONSTRAINT ck_web_stock_copy_after_cutoff CHECK (copied_at >= snapshot_cutoff_at)
);
COMMENT ON TABLE src_online.web_stock_copy IS
'One copied product/location on-hand balance from one 5 am website refresh. Immutable: a later refresh adds a new copy_id instead of updating rows. The website uses its latest copy as the opening balance of its own outdated calculation.';
COMMENT ON COLUMN src_online.web_stock_copy.source_snapshot_id IS
'Central snapshot that was copied. A text reference to the central source, not a cross-source foreign key.';
COMMENT ON COLUMN src_online.web_stock_copy.snapshot_cutoff_at IS
'Effective time of the copied balance (midnight). The copy reflects events strictly before this time.';
COMMENT ON COLUMN src_online.web_stock_copy.copied_at IS
'Time the website copied the snapshot (5 am). Copying later does not make the balance a 5 am count.';


-- -----------------------------------------------------------------------------
-- Source 3: central stock database
-- -----------------------------------------------------------------------------

CREATE TABLE src_stock.product (
    sku           text          NOT NULL,
    product_name  text          NOT NULL,
    brand         text          NOT NULL,
    category      text          NOT NULL,
    pack_size     numeric(12,3) NOT NULL,
    pack_unit     text          NOT NULL,
    is_active     boolean       NOT NULL,
    CONSTRAINT pk_stock_product PRIMARY KEY (sku),
    CONSTRAINT ck_stock_product_pack_size CHECK (pack_size > 0)
);
COMMENT ON TABLE src_stock.product IS
'One PetHaven product (master data). Quantities everywhere are whole sellable packs; pack_size and pack_unit describe one pack and are not stock units.';

CREATE TABLE src_stock.product_barcode (
    barcode  text NOT NULL,
    sku      text NOT NULL,
    CONSTRAINT pk_product_barcode PRIMARY KEY (barcode),
    CONSTRAINT fk_product_barcode_product FOREIGN KEY (sku)
        REFERENCES src_stock.product (sku)
);
COMMENT ON TABLE src_stock.product_barcode IS
'One barcode-to-SKU link. Several barcodes may identify one SKU. This is the authoritative list integration uses to match scanned barcodes.';

CREATE TABLE src_stock.location (
    location_code  text NOT NULL,
    location_name  text NOT NULL,
    location_type  text NOT NULL,
    suburb         text NOT NULL,
    CONSTRAINT pk_location PRIMARY KEY (location_code),
    CONSTRAINT ck_location_type CHECK (location_type IN ('store', 'dc'))
);
COMMENT ON TABLE src_stock.location IS
'One physical location where stock is held: a store or the distribution centre (DC). Master data. Goods in transit are not a location.';

CREATE TABLE src_stock.external_location_code (
    system_code    text NOT NULL,
    external_code  text NOT NULL,
    location_code  text NOT NULL,
    CONSTRAINT pk_external_location_code PRIMARY KEY (system_code, external_code),
    CONSTRAINT fk_external_location_code_location FOREIGN KEY (location_code)
        REFERENCES src_stock.location (location_code),
    CONSTRAINT ck_external_location_code_system CHECK (system_code IN ('store_sales', 'online'))
);
COMMENT ON TABLE src_stock.external_location_code IS
'Codes the other existing systems use for a central location (till store code, website pickup code). Used only by the existing 1 am import and 5 am website feed, which ran before the warehouse existed. Integration does not trust this table; it uses the reviewed ref.location_identifier mappings.';

CREATE TABLE src_stock.stock_transfer (
    transfer_id                text        NOT NULL,
    origin_location_code       text        NOT NULL,
    destination_location_code  text        NOT NULL,
    created_at                 timestamptz NOT NULL,
    current_status             text        NOT NULL,
    CONSTRAINT pk_stock_transfer PRIMARY KEY (transfer_id),
    CONSTRAINT fk_stock_transfer_origin FOREIGN KEY (origin_location_code)
        REFERENCES src_stock.location (location_code),
    CONSTRAINT fk_stock_transfer_destination FOREIGN KEY (destination_location_code)
        REFERENCES src_stock.location (location_code),
    CONSTRAINT ck_stock_transfer_distinct_locations
        CHECK (origin_location_code <> destination_location_code),
    CONSTRAINT ck_stock_transfer_status
        CHECK (current_status IN ('created', 'dispatched', 'received'))
);
COMMENT ON TABLE src_stock.stock_transfer IS
'One stock transfer between two locations and its current status. Current transaction record. Creating a transfer moves no stock; dispatch and receipt movements do.';

CREATE TABLE src_stock.stock_transfer_line (
    transfer_id  text    NOT NULL,
    line_id      text    NOT NULL,
    sku          text    NOT NULL,
    quantity     integer NOT NULL,
    CONSTRAINT pk_stock_transfer_line PRIMARY KEY (transfer_id, line_id),
    CONSTRAINT fk_stock_transfer_line_transfer FOREIGN KEY (transfer_id)
        REFERENCES src_stock.stock_transfer (transfer_id),
    CONSTRAINT fk_stock_transfer_line_product FOREIGN KEY (sku)
        REFERENCES src_stock.product (sku),
    CONSTRAINT ck_stock_transfer_line_quantity CHECK (quantity > 0)
);
COMMENT ON TABLE src_stock.stock_transfer_line IS
'One product line of a transfer. A planned quantity, not a physical movement: counting it as well as its dispatch movement would deduct stock twice. Dispatch and receipt times come from the linked movements.';

CREATE TABLE src_stock.stock_movement (
    movement_id          text        NOT NULL,
    sku                  text        NOT NULL,
    location_code        text        NOT NULL,
    movement_type        text        NOT NULL,
    quantity             integer     NOT NULL,
    occurred_at          timestamptz NOT NULL,
    recorded_at          timestamptz NOT NULL,
    origin_system_code   text        NOT NULL,
    origin_event_type    text        NOT NULL,
    origin_event_id      text        NOT NULL,
    origin_line_id       text        NOT NULL,
    transfer_id          text,
    transfer_line_id     text,
    delivery_reference   text,
    supplier_reference   text,
    reason_code          text,
    reverses_movement_id text,
    CONSTRAINT pk_stock_movement PRIMARY KEY (movement_id),
    CONSTRAINT fk_stock_movement_product FOREIGN KEY (sku)
        REFERENCES src_stock.product (sku),
    CONSTRAINT fk_stock_movement_location FOREIGN KEY (location_code)
        REFERENCES src_stock.location (location_code),
    CONSTRAINT fk_stock_movement_transfer_line FOREIGN KEY (transfer_id, transfer_line_id)
        REFERENCES src_stock.stock_transfer_line (transfer_id, line_id),
    CONSTRAINT fk_stock_movement_reverses FOREIGN KEY (reverses_movement_id)
        REFERENCES src_stock.stock_movement (movement_id),
    -- One central row per original business event line. This is what stops a
    -- rerun of the 1 am import from creating a second copy of the same sale.
    CONSTRAINT uq_stock_movement_origin UNIQUE
        (origin_system_code, origin_event_type, origin_event_id, origin_line_id),
    CONSTRAINT ck_stock_movement_type CHECK (movement_type IN (
        'supplier_receipt', 'transfer_dispatch', 'transfer_receipt', 'adjustment',
        'store_sale', 'online_collection', 'online_shipment', 'reversal')),
    -- Sign convention: positive adds stock at location_code, negative removes it.
    CONSTRAINT ck_stock_movement_sign CHECK (
        (movement_type IN ('supplier_receipt', 'transfer_receipt') AND quantity > 0)
        OR (movement_type IN ('transfer_dispatch', 'store_sale', 'online_collection', 'online_shipment') AND quantity < 0)
        OR (movement_type IN ('adjustment', 'reversal') AND quantity <> 0)
    ),
    -- Locally confirmed movements carry their own identity; imported rows carry
    -- the identity of the original till sale or online collection/shipment.
    CONSTRAINT ck_stock_movement_origin CHECK (
        (movement_type IN ('supplier_receipt', 'transfer_dispatch', 'transfer_receipt', 'adjustment', 'reversal')
            AND origin_system_code = 'stock' AND origin_event_type = 'movement'
            AND origin_event_id = movement_id AND origin_line_id = '0')
        OR (movement_type = 'store_sale'
            AND origin_system_code = 'store_sales' AND origin_event_type = 'sale')
        OR (movement_type = 'online_collection'
            AND origin_system_code = 'online' AND origin_event_type = 'collection')
        OR (movement_type = 'online_shipment'
            AND origin_system_code = 'online' AND origin_event_type = 'shipment')
    ),
    CONSTRAINT ck_stock_movement_receipt_references CHECK (
        movement_type <> 'supplier_receipt'
        OR (delivery_reference IS NOT NULL AND supplier_reference IS NOT NULL)
    ),
    CONSTRAINT ck_stock_movement_transfer_reference CHECK (
        (movement_type IN ('transfer_dispatch', 'transfer_receipt')) = (transfer_id IS NOT NULL)
    ),
    CONSTRAINT ck_stock_movement_reason CHECK (
        movement_type NOT IN ('adjustment', 'reversal') OR reason_code IS NOT NULL
    ),
    CONSTRAINT ck_stock_movement_reversal_reference CHECK (
        (movement_type = 'reversal') = (reverses_movement_id IS NOT NULL)
    )
);
COMMENT ON TABLE src_stock.stock_movement IS
'One signed physical quantity change at one location. Immutable event history: corrections are new reversal movements. Holds locally confirmed movements (receipts, transfers, adjustments) and rows imported overnight from till sales and online collections.';
COMMENT ON COLUMN src_stock.stock_movement.quantity IS
'Signed change in whole sellable units at one location. Positive values add stock; negative values remove stock. Reservations are not physical movements.';
COMMENT ON COLUMN src_stock.stock_movement.occurred_at IS
'Business time of the physical action (sale completion, collection, confirmed receipt/dispatch/count).';
COMMENT ON COLUMN src_stock.stock_movement.recorded_at IS
'Time central stock recorded the row. For imported rows this is the 1 am import processing time, not the original sale recording time.';
COMMENT ON COLUMN src_stock.stock_movement.origin_event_id IS
'Original business event identifier: the sale ID, the online collection status event ID, or this movement ID for a local movement. With origin_system_code, origin_event_type and origin_line_id it identifies the physical event across sources.';
COMMENT ON COLUMN src_stock.stock_movement.origin_line_id IS
'Original line identifier; the fixed text 0 for an event without lines.';

CREATE TABLE src_stock.stock_on_hand (
    sku               text        NOT NULL,
    location_code     text        NOT NULL,
    on_hand_quantity  integer     NOT NULL,
    updated_at        timestamptz NOT NULL,
    CONSTRAINT pk_stock_on_hand PRIMARY KEY (sku, location_code),
    CONSTRAINT fk_stock_on_hand_product FOREIGN KEY (sku)
        REFERENCES src_stock.product (sku),
    CONSTRAINT fk_stock_on_hand_location FOREIGN KEY (location_code)
        REFERENCES src_stock.location (location_code)
);
COMMENT ON TABLE src_stock.stock_on_hand IS
'Central current recorded quantity for one product/location. Current state of mixed age: hourly processing applies local movements, but store sales and online collections arrive only at 1 am. Not used as an opening balance by integration.';

CREATE TABLE src_stock.stock_snapshot (
    snapshot_id       text        NOT NULL,
    sku               text        NOT NULL,
    location_code     text        NOT NULL,
    on_hand_quantity  integer     NOT NULL,
    cutoff_at         timestamptz NOT NULL,
    created_at        timestamptz NOT NULL,
    CONSTRAINT pk_stock_snapshot PRIMARY KEY (snapshot_id, sku, location_code),
    CONSTRAINT fk_stock_snapshot_product FOREIGN KEY (sku)
        REFERENCES src_stock.product (sku),
    CONSTRAINT fk_stock_snapshot_location FOREIGN KEY (location_code)
        REFERENCES src_stock.location (location_code),
    CONSTRAINT ck_stock_snapshot_quantity CHECK (on_hand_quantity >= 0),
    CONSTRAINT ck_stock_snapshot_created_after_cutoff CHECK (created_at >= cutoff_at)
);
COMMENT ON TABLE src_stock.stock_snapshot IS
'One reconciled product/location balance at a defined cutoff. Immutable history. Contains every physical event strictly before cutoff_at that central knew when the snapshot was created. A missing product/location row means unknown, not zero.';
COMMENT ON COLUMN src_stock.stock_snapshot.cutoff_at IS
'Effective time of the balance (midnight). Events at exactly this time belong after the snapshot.';
COMMENT ON COLUMN src_stock.stock_snapshot.created_at IS
'Time central produced the snapshot (1 am). Events recorded after this time cannot be included.';

CREATE TABLE src_stock.movement_application (
    movement_id  text        NOT NULL,
    applied_at   timestamptz NOT NULL,
    CONSTRAINT pk_movement_application PRIMARY KEY (movement_id),
    CONSTRAINT fk_movement_application_movement FOREIGN KEY (movement_id)
        REFERENCES src_stock.stock_movement (movement_id)
);
COMMENT ON TABLE src_stock.movement_application IS
'One record per movement already applied to stock_on_hand. The primary key prevents the hourly or overnight job from applying a movement twice when it is rerun.';
