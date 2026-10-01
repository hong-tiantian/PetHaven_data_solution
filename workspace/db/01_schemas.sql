-- =============================================================================
-- 01_schemas.sql
-- Purpose: Create the nine PetHaven schemas and describe each one in the
--          database catalogue.
-- Prerequisites: An empty project database (see scripts/apply_schema.py).
-- Inputs: None.
-- Outputs: Schemas src_store_sales, src_online, src_stock, raw, ref, stg, dw,
--          rpt and audit, each with a COMMENT ON SCHEMA description.
-- Execution: Applied first by scripts/apply_schema.py; can also be run in
--            CloudBeaver against an empty database.
-- Transaction: The runner applies each numbered file in one transaction.
-- Rerun behaviour: Not rerunnable; CREATE SCHEMA fails if a schema exists.
--                  Rebuild by creating a fresh isolated database instead.
-- Business rules: Architecture_and_Data_Model.md section 3.1.
-- =============================================================================

-- Three business sources. In PetHaven each is a separate operational
-- database; the lab represents them as separate schemas in one database.
CREATE SCHEMA src_store_sales;
CREATE SCHEMA src_online;
CREATE SCHEMA src_stock;

-- Internal processing stages. They are not additional business sources.
CREATE SCHEMA raw;
CREATE SCHEMA ref;
CREATE SCHEMA stg;
CREATE SCHEMA dw;
CREATE SCHEMA rpt;
CREATE SCHEMA audit;

COMMENT ON SCHEMA src_store_sales IS
'Store sales business source. Records completed till sales and sale lines. Does not maintain inventory balances or online reservations.';

COMMENT ON SCHEMA src_online IS
'Online orders business source. Records accepted orders, status history and website stock copies. Active reservations are derived from order lines and status history.';

COMMENT ON SCHEMA src_stock IS
'Central stock business source. Records products, locations, physical movements, current recorded balances and reconciled snapshots for stores and the distribution centre.';

COMMENT ON SCHEMA raw IS
'Internal extraction layer. Preserves source-shaped records and their identifiers for each load run. Extracted values are retained as evidence rather than corrected in place.';

COMMENT ON SCHEMA ref IS
'Internal reference mappings. Links source product and location identifiers to shared identifiers. Does not maintain stock balances.';

COMMENT ON SCHEMA stg IS
'Internal integration work area. Holds validated and matched records for a load run, including canonical physical event identities. It is not permanent reporting history.';

COMMENT ON SCHEMA dw IS
'Integrated dimensional warehouse. Stores shared dimensions, physical events, order history, opening snapshots and website copies. Does not operate live checkout.';

COMMENT ON SCHEMA rpt IS
'Inventory calculations and reporting. Provides shared availability and order-risk calculations, saved observations, report views and the simulated stock check.';

COMMENT ON SCHEMA audit IS
'Pipeline execution records. Tracks extraction, validation issues, lineage, mapping changes and publication. Does not represent an additional business data source.';
