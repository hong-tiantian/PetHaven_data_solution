-- =============================================================================
-- 05_reference_tables.sql
-- Purpose: Create the reference mappings that link each source's product and
--          location identifiers to the shared SKU and canonical location code.
-- Prerequisites: 01_schemas.sql, 03_audit_tables.sql.
-- Inputs: None (mappings are seeded by db/seed/reference_mappings.sql and
--         refreshed from central product extracts by db/etl/validate_sources.sql).
-- Outputs: ref.source_system, ref.product_identifier, ref.location_identifier.
-- Execution: Applied by scripts/apply_schema.py.
-- Transaction: One transaction for the whole file (runner-owned).
-- Rerun behaviour: Not rerunnable; rebuild in a fresh isolated database.
-- Business rules: Spec section 5.4; Architecture_and_Data_Model.md section 5.2.
--
-- Matching is exact. A missing mapping is a data-quality issue: integration
-- never matches by product name, suburb or approximate text, and never assigns
-- a default product or store.
-- =============================================================================

CREATE TABLE ref.source_system (
    system_code  text NOT NULL,
    system_name  text NOT NULL,
    CONSTRAINT pk_source_system PRIMARY KEY (system_code)
);
COMMENT ON TABLE ref.source_system IS
'One business source database: store_sales, online or stock. Reference data.';

INSERT INTO ref.source_system (system_code, system_name) VALUES
    ('store_sales', 'Store sales database (in-store POS tills)'),
    ('online',      'Online orders database (website and order management)'),
    ('stock',       'Central stock database');

-- Extraction manifests name the source system they came from.
ALTER TABLE audit.source_extract
    ADD CONSTRAINT fk_source_extract_system FOREIGN KEY (system_code)
        REFERENCES ref.source_system (system_code);

CREATE TABLE ref.product_identifier (
    system_code       text        NOT NULL,
    identifier_type   text        NOT NULL,
    identifier_value  text        NOT NULL,
    sku               text        NOT NULL,
    approved_at       timestamptz NOT NULL,
    mapping_basis     text        NOT NULL,
    CONSTRAINT pk_product_identifier PRIMARY KEY (system_code, identifier_type, identifier_value),
    CONSTRAINT fk_product_identifier_system FOREIGN KEY (system_code)
        REFERENCES ref.source_system (system_code),
    CONSTRAINT ck_product_identifier_type CHECK (identifier_type IN ('barcode', 'sku')),
    -- Tills identify products by barcode; online and central use the SKU.
    CONSTRAINT ck_product_identifier_type_by_system CHECK (
        (system_code = 'store_sales' AND identifier_type = 'barcode')
        OR (system_code IN ('online', 'stock') AND identifier_type = 'sku')
    )
);
COMMENT ON TABLE ref.product_identifier IS
'One approved link from a source product identifier to the shared SKU. Barcode links come from validated central product_barcode extracts; SKU self-links are explicit for online and stock records. The primary key guarantees at most one match per identifier.';
COMMENT ON COLUMN ref.product_identifier.mapping_basis IS
'Why the mapping is trusted, for example the central extract run that supplied it.';

CREATE TABLE ref.location_identifier (
    system_code              text        NOT NULL,
    location_code            text        NOT NULL,
    canonical_location_code  text        NOT NULL,
    approved_at              timestamptz NOT NULL,
    mapping_basis            text        NOT NULL,
    CONSTRAINT pk_location_identifier PRIMARY KEY (system_code, location_code),
    CONSTRAINT fk_location_identifier_system FOREIGN KEY (system_code)
        REFERENCES ref.source_system (system_code)
);
COMMENT ON TABLE ref.location_identifier IS
'One reviewed link from a source location code (till store code, online pickup code or central code) to the canonical central location code. Seeded from a reviewed file; later changes are recorded in audit.mapping_change.';
COMMENT ON COLUMN ref.location_identifier.canonical_location_code IS
'Shared location code, equal to the central stock location code, for example STR-PAR. Checked against central location extracts during validation.';
