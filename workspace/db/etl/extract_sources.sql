-- =============================================================================
-- etl/extract_sources.sql
-- Purpose: Full extraction of all 19 source tables into raw for one load run,
--          with an extraction manifest per table.
-- Prerequisites: 04_raw_tables.sql; a running audit.load_run row.
-- Inputs: p_load_run_id; p_skip_tables (test hook, normally empty).
-- Outputs: raw.* rows tagged with the run, audit.source_extract manifests.
-- Execution: Called by scripts/run_pipeline.py:
--            CALL raw.extract_sources(<load_run_id>);
-- Transaction: The runner calls it in one REPEATABLE READ transaction, so all
--              tables are read from one consistent database snapshot and the
--              source/raw counts in each manifest come from the same snapshot.
--              The runner commits it before validation (raw is evidence even
--              if the load is later rejected).
-- Rerun behaviour: A run can be extracted once (raw unique keys). Every new run
--                  stores a new full copy; that grows raw, not the warehouse.
-- Failure behaviour: Any error rolls back this run's raw rows; the runner then
--                    marks the run failed.
-- Business rules: Architecture_and_Data_Model.md 1.2, 5.1 and 12.2.
--
-- Full extraction is a prototype choice for a small fixture: it makes
-- completeness checks and retries simple. A production extractor would need
-- incremental change capture.
-- =============================================================================

CREATE FUNCTION raw.source_tables()
RETURNS TABLE (system_code text, source_schema text, source_table text, raw_table text)
LANGUAGE sql
IMMUTABLE
AS $$
    VALUES
        ('store_sales', 'src_store_sales', 'store',                  'store_sales_store'),
        ('store_sales', 'src_store_sales', 'product',                'store_sales_product'),
        ('store_sales', 'src_store_sales', 'sale',                   'store_sales_sale'),
        ('store_sales', 'src_store_sales', 'sale_line',              'store_sales_sale_line'),
        ('online',      'src_online',      'fulfilment_location',    'online_fulfilment_location'),
        ('online',      'src_online',      'web_order',              'online_web_order'),
        ('online',      'src_online',      'web_order_line',         'online_web_order_line'),
        ('online',      'src_online',      'order_status_history',   'online_order_status_history'),
        ('online',      'src_online',      'web_stock_copy',         'online_web_stock_copy'),
        ('stock',       'src_stock',       'product',                'stock_product'),
        ('stock',       'src_stock',       'product_barcode',        'stock_product_barcode'),
        ('stock',       'src_stock',       'location',               'stock_location'),
        ('stock',       'src_stock',       'external_location_code', 'stock_external_location_code'),
        ('stock',       'src_stock',       'stock_transfer',         'stock_stock_transfer'),
        ('stock',       'src_stock',       'stock_transfer_line',    'stock_stock_transfer_line'),
        ('stock',       'src_stock',       'stock_movement',         'stock_stock_movement'),
        ('stock',       'src_stock',       'stock_on_hand',          'stock_stock_on_hand'),
        ('stock',       'src_stock',       'stock_snapshot',         'stock_stock_snapshot'),
        ('stock',       'src_stock',       'movement_application',   'stock_movement_application')
$$;
COMMENT ON FUNCTION raw.source_tables() IS
'The 19 source tables every load must extract, with their raw table names (source prefix + unchanged table name). Used by extraction and by the completeness check. No side effects.';

CREATE PROCEDURE raw.extract_sources(
    p_load_run_id  bigint,
    p_skip_tables  text[] DEFAULT ARRAY[]::text[]
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_table         record;
    v_columns       text;
    v_started_at    timestamptz;
    v_extracted_at  timestamptz := clock_timestamp();
    v_raw_count     bigint;
    v_source_count  bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM audit.load_run WHERE load_run_id = p_load_run_id AND status = 'running') THEN
        RAISE EXCEPTION 'Load run % is not running', p_load_run_id;
    END IF;

    FOR v_table IN SELECT * FROM raw.source_tables() LOOP
        -- Test hook for T24 (source completeness): a skipped table gets no
        -- manifest, which validation must treat as an incomplete extract.
        CONTINUE WHEN (v_table.system_code || '.' || v_table.source_table) = ANY (p_skip_tables);

        v_started_at := clock_timestamp();

        -- Raw tables repeat the source column names exactly, so the column
        -- list is read from the source table definition.
        SELECT string_agg(quote_ident(c.column_name), ', ' ORDER BY c.ordinal_position)
          INTO v_columns
          FROM information_schema.columns AS c
         WHERE c.table_schema = v_table.source_schema
           AND c.table_name = v_table.source_table;

        EXECUTE format(
            'INSERT INTO raw.%I (load_run_id, extracted_at, %s) SELECT $1, $2, %s FROM %I.%I',
            v_table.raw_table, v_columns, v_columns, v_table.source_schema, v_table.source_table)
        USING p_load_run_id, v_extracted_at;
        GET DIAGNOSTICS v_raw_count = ROW_COUNT;

        EXECUTE format('SELECT count(*) FROM %I.%I', v_table.source_schema, v_table.source_table)
           INTO v_source_count;

        INSERT INTO audit.source_extract (
            load_run_id, system_code, table_name, started_at, finished_at,
            source_row_count, raw_row_count, rejected_count, status)
        VALUES (
            p_load_run_id, v_table.system_code, v_table.source_table, v_started_at, clock_timestamp(),
            v_source_count, v_raw_count, 0, 'succeeded');
    END LOOP;
END;
$$;
COMMENT ON PROCEDURE raw.extract_sources(bigint, text[]) IS
'Copies every row of the 19 source tables into raw for load run p_load_run_id and writes one manifest per table with source and raw counts. p_skip_tables (for example {online.web_order_line}) omits tables to test completeness checking. Must run in one REPEATABLE READ transaction. Raises an error unless the run is running.';
