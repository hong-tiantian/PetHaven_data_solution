-- =============================================================================
-- seed/unknown_identifier.sql
-- Purpose: T14. A till sells a barcode that central does not know yet, and a
--          new store's till uses a store code with no reviewed mapping. The
--          load must be rejected with visible issues and no optimistic stock
--          answer; after central adds the product/location and a reviewed
--          mapping is approved, the preserved evidence loads normally.
-- Prerequisites: Empty isolated scenario database with the schema applied.
-- Inputs: None (synthetic data; Day 1 = 16 Sep 2026).
-- Outputs: A rejected run with issues, then a succeeded run.
-- Execution: python /workspace/scripts/run_scenario.py unknown_identifier
-- Rerun behaviour: Not rerunnable in the same database.
-- Business rules: Spec 5.4; Architecture_and_Data_Model.md 5.2 and 6.
-- Checks: tests/expected/unknown_identifier.csv (T14).
-- =============================================================================

-- @include base_sources.sql

-- @step d1_0100_opening_snapshot | Opening snapshot at Parramatta and Chatswood
CALL src_stock.bootstrap_opening_snapshot(
    'SNAP-20260916',
    '2026-09-16 00:00 Australia/Sydney',
    '2026-09-16 01:00 Australia/Sydney',
    '[{"sku": "PH-10231", "location_code": "STR-PAR", "quantity": 5},
      {"sku": "PH-10231", "location_code": "STR-CHA", "quantity": 8}]');

-- @step d1_0500_website_refresh | 5 am: website copies the snapshot
CALL src_online.refresh_website_stock('WEB-20260916', 'SNAP-20260916', '2026-09-16 05:00 Australia/Sydney');

-- @step d1_0800_new_till_data | The tills receive a new seasonal toy barcode and the new Penrith store code before central does
INSERT INTO src_store_sales.product (barcode, product_name, unit_price)
VALUES ('9300000999995', 'PetHaven Seasonal Chew Toy', 12.99);
INSERT INTO src_store_sales.store (store_code, store_name, suburb)
VALUES ('0199', 'PetHaven Penrith', 'Penrith');

-- @step d1_1000_sale_unknown_barcode | 10 am: Parramatta sells the seasonal toy (barcode unknown to central)
CALL src_store_sales.record_sale('S-0123-0901', '0123', 'T01', '2026-09-16 10:00 Australia/Sydney',
    '[{"line_id": "1", "barcode": "9300000999995", "quantity": 1}]');

-- @step d1_1030_sale_unknown_store | 10:30 am: the Penrith till (store code 0199, not yet mapped) sells one bag of dog food
CALL src_store_sales.record_sale('S-0199-0001', '0199', 'T01', '2026-09-16 10:30 Australia/Sydney',
    '[{"line_id": "1", "barcode": "9300000102314", "quantity": 1}]');

-- @checkpoint u_d1_1100 | 2026-09-16 11:00 Australia/Sydney | Unmatched barcode and store code: the load is rejected

-- @check chk_par_rc_1100 | 2026-09-16 11:00 Australia/Sydney | store-parramatta | [{"sku": "PH-10231", "quantity": 1}] | A rejected load gives no stock answer

-- @step d1_1130_central_catches_up | 11:30 am: central adds the new product, its barcode and the Penrith location
INSERT INTO src_stock.product (sku, product_name, brand, category, pack_size, pack_unit, is_active)
VALUES ('PH-40990', 'PetHaven Seasonal Chew Toy', 'PetHaven', 'dog_toy', 1.000, 'each', true);
INSERT INTO src_stock.product_barcode (barcode, sku) VALUES ('9300000999995', 'PH-40990');
INSERT INTO src_stock.location (location_code, location_name, location_type, suburb)
VALUES ('STR-PEN', 'PetHaven Penrith', 'store', 'Penrith');
INSERT INTO src_stock.external_location_code (system_code, external_code, location_code)
VALUES ('store_sales', '0199', 'STR-PEN');

-- @step d1_1140_mapping_review | 11:40 am: data steward approves the Penrith mappings (recorded in audit.mapping_change)
INSERT INTO ref.location_identifier (system_code, location_code, canonical_location_code, approved_at, mapping_basis)
VALUES ('store_sales', '0199',    'STR-PEN', '2026-09-16 11:40 Australia/Sydney', 'Reviewed new-store mapping v2'),
       ('stock',       'STR-PEN', 'STR-PEN', '2026-09-16 11:40 Australia/Sydney', 'Reviewed new-store mapping v2');
INSERT INTO audit.mapping_change (mapping_type, mapping_key, previous_target, new_target, reason, revision)
VALUES ('location', 'store_sales:0199', NULL, 'STR-PEN', 'New Penrith store till code reviewed and approved', 'mapping-v2');

-- @checkpoint u_d1_1200 | 2026-09-16 12:00 Australia/Sydney | Mappings complete: the preserved sales now load

-- @check chk_par_rc_1200 | 2026-09-16 12:00 Australia/Sydney | store-parramatta | [{"sku": "PH-10231", "quantity": 1}] | Published load gives a real answer
