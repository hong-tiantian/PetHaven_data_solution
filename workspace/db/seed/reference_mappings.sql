-- =============================================================================
-- seed/reference_mappings.sql
-- Purpose: Seed the reviewed location-code mappings used by integration.
-- Prerequisites: 05_reference_tables.sql.
-- Inputs: None (synthetic, reviewed mapping list below).
-- Outputs: ref.location_identifier rows.
-- Execution: Applied by scripts/apply_schema.py after the schema files.
-- Transaction: One transaction (runner-owned).
-- Rerun behaviour: Not rerunnable (primary key); rebuild in a fresh database.
-- Business rules: Spec 5.4; Architecture_and_Data_Model.md 5.2.
--
-- The three sources use different codes for the same physical place:
--   till store code 0123 = online pickup code store-parramatta = central STR-PAR.
-- Codes are text so that leading zeros are kept. Product mappings are not
-- seeded here: they are taken from each validated central product extract.
-- =============================================================================

INSERT INTO ref.location_identifier
    (system_code, location_code, canonical_location_code, approved_at, mapping_basis)
VALUES
    ('store_sales', '0123',              'STR-PAR', '2026-09-01 09:00 Australia/Sydney', 'Reviewed location mapping list v1'),
    ('store_sales', '0145',              'STR-CHA', '2026-09-01 09:00 Australia/Sydney', 'Reviewed location mapping list v1'),
    ('store_sales', '0167',              'STR-NEW', '2026-09-01 09:00 Australia/Sydney', 'Reviewed location mapping list v1'),
    ('online',      'store-parramatta',  'STR-PAR', '2026-09-01 09:00 Australia/Sydney', 'Reviewed location mapping list v1'),
    ('online',      'store-chatswood',   'STR-CHA', '2026-09-01 09:00 Australia/Sydney', 'Reviewed location mapping list v1'),
    ('online',      'store-newtown',     'STR-NEW', '2026-09-01 09:00 Australia/Sydney', 'Reviewed location mapping list v1'),
    ('online',      'dc-moorebank',      'DC-MOO',  '2026-09-01 09:00 Australia/Sydney', 'Reviewed location mapping list v1'),
    ('stock',       'STR-PAR',           'STR-PAR', '2026-09-01 09:00 Australia/Sydney', 'Reviewed location mapping list v1'),
    ('stock',       'STR-CHA',           'STR-CHA', '2026-09-01 09:00 Australia/Sydney', 'Reviewed location mapping list v1'),
    ('stock',       'STR-NEW',           'STR-NEW', '2026-09-01 09:00 Australia/Sydney', 'Reviewed location mapping list v1'),
    ('stock',       'DC-MOO',            'DC-MOO',  '2026-09-01 09:00 Australia/Sydney', 'Reviewed location mapping list v1');
