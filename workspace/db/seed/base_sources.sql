-- =============================================================================
-- seed/base_sources.sql
-- Purpose: Synthetic master and reference data that exists in the three
--          sources before any scenario starts: products, barcodes, stores,
--          the DC and each system's own location codes.
-- Prerequisites: All schema files applied to an empty isolated database.
-- Inputs: None (synthetic data below; no real customer or business data).
-- Outputs: Rows in src_store_sales, src_online and src_stock reference tables.
-- Execution: Included as the first step of every scenario file
--            (-- @include base_sources.sql), run by scripts/run_scenario.py.
-- Transaction: One step = one transaction.
-- Rerun behaviour: Not rerunnable (primary keys); each scenario uses a fresh
--                  database.
-- Business rules: Spec 1, 3.3 and 5.4.
--
-- Products (central SKU / till barcodes)
--   PH-10231 Royal Canin Medium Adult dog food 3 kg  9300000102314, 0930000102310
--   PH-20455 KONG Classic dog toy, medium            9300000204551
--   PH-30710 Feline Greenies cat treats 130 g        9300000307108
-- Locations (central / till / online)
--   STR-PAR Parramatta store  0123  store-parramatta
--   STR-CHA Chatswood store   0145  store-chatswood
--   STR-NEW Newtown store     0167  store-newtown
--   DC-MOO  Moorebank DC      -     dc-moorebank
-- The second Royal Canin barcode starts with 0 on purpose: codes are text.
-- =============================================================================

-- @step base_sources | Load synthetic product and location master data into the three sources

-- Store sales source: what the tills know.
INSERT INTO src_store_sales.store (store_code, store_name, suburb) VALUES
    ('0123', 'PetHaven Parramatta', 'Parramatta'),
    ('0145', 'PetHaven Chatswood',  'Chatswood'),
    ('0167', 'PetHaven Newtown',    'Newtown');

INSERT INTO src_store_sales.product (barcode, product_name, unit_price) VALUES
    ('9300000102314', 'Royal Canin Medium Adult Dry Dog Food 3kg',          54.99),
    ('0930000102310', 'Royal Canin Medium Adult Dry Dog Food 3kg (multi)',  54.99),
    ('9300000204551', 'KONG Classic Dog Toy Medium',                        24.99),
    ('9300000307108', 'Feline Greenies Dental Cat Treats Chicken 130g',      9.99);

-- Online orders source: what the website knows.
INSERT INTO src_online.fulfilment_location (location_code, location_name, location_type) VALUES
    ('store-parramatta', 'Parramatta',   'store'),
    ('store-chatswood',  'Chatswood',    'store'),
    ('store-newtown',    'Newtown',      'store'),
    ('dc-moorebank',     'Moorebank DC', 'dc');

-- Central stock source: product and location master data.
INSERT INTO src_stock.product (sku, product_name, brand, category, pack_size, pack_unit, is_active) VALUES
    ('PH-10231', 'Royal Canin Medium Adult Dry Dog Food', 'Royal Canin',   'dog_food',  3.000, 'kg',   true),
    ('PH-20455', 'KONG Classic Dog Toy Medium',           'KONG',          'dog_toy',   1.000, 'each', true),
    ('PH-30710', 'Feline Greenies Dental Treats Chicken', 'Greenies',      'cat_treat', 130.000, 'g',  true);

INSERT INTO src_stock.product_barcode (barcode, sku) VALUES
    ('9300000102314', 'PH-10231'),
    ('0930000102310', 'PH-10231'),
    ('9300000204551', 'PH-20455'),
    ('9300000307108', 'PH-30710');

INSERT INTO src_stock.location (location_code, location_name, location_type, suburb) VALUES
    ('STR-PAR', 'PetHaven Parramatta',  'store', 'Parramatta'),
    ('STR-CHA', 'PetHaven Chatswood',   'store', 'Chatswood'),
    ('STR-NEW', 'PetHaven Newtown',     'store', 'Newtown'),
    ('DC-MOO',  'PetHaven Moorebank DC', 'dc',   'Moorebank');

-- Codes the existing 1 am import and 5 am website feed use.
INSERT INTO src_stock.external_location_code (system_code, external_code, location_code) VALUES
    ('store_sales', '0123',             'STR-PAR'),
    ('store_sales', '0145',             'STR-CHA'),
    ('store_sales', '0167',             'STR-NEW'),
    ('online',      'store-parramatta', 'STR-PAR'),
    ('online',      'store-chatswood',  'STR-CHA'),
    ('online',      'store-newtown',    'STR-NEW'),
    ('online',      'dc-moorebank',     'DC-MOO');
