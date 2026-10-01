-- =============================================================================
-- 08_reporting_objects.sql
-- Purpose: Create the shared stock calculations, the saved-observation tables,
--          the simulated stock check and the three reporting views.
-- Prerequisites: 01-07.
-- Inputs: Published warehouse facts (dw) and load runs (audit.load_run).
-- Outputs: rpt functions, tables and views listed below.
-- Execution: Applied by scripts/apply_schema.py.
-- Transaction: One transaction for the whole file (runner-owned).
-- Rerun behaviour: Not rerunnable; rebuild in a fresh isolated database.
-- Business rules: Spec section 5 and 7; Architecture_and_Data_Model.md
--                 sections 9, 10 and 13.
--
-- One calculation, used everywhere
-- --------------------------------
-- rpt.calculate_inventory is the only implementation of the integrated stock
-- formula. Saved observations, the order-risk allocation and the simulated
-- stock check all read it, so every report and the check use the same
-- definitions (Spec 7.5, last bullet).
--
--   on_hand   = opening snapshot + signed movements in [cutoff, observed_at]
--   reserved  = order lines whose effective status at observed_at is
--               awaiting_pick or ready
--   available = greatest(on_hand - reserved, 0)
--   shortfall = greatest(reserved - on_hand, 0)
--
-- What a calculation may see
-- --------------------------
-- A calculation is always "as known by" one successful load run: it uses only
-- facts first published by that run or an earlier-published run, compared by
-- publication order (audit.load_run.publication_sequence), never by run ID.
-- A later load can reconstruct an earlier business time with more evidence;
-- that is saved as a separate observation and never replaces the earlier one.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

CREATE FUNCTION rpt.visible_load_runs(p_load_run_id bigint)
RETURNS TABLE (visible_load_run_id bigint)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_status   text;
    v_sequence bigint;
BEGIN
    SELECT lr.status, lr.publication_sequence
      INTO v_status, v_sequence
      FROM audit.load_run AS lr
     WHERE lr.load_run_id = p_load_run_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Load run % does not exist', p_load_run_id;
    END IF;
    IF v_status <> 'succeeded' THEN
        RAISE EXCEPTION 'Load run % has status %; only a succeeded (published) run can be used for a calculation',
            p_load_run_id, v_status;
    END IF;

    RETURN QUERY
        SELECT lr.load_run_id
          FROM audit.load_run AS lr
         WHERE lr.status = 'succeeded'
           AND lr.publication_sequence <= v_sequence;
END;
$$;
COMMENT ON FUNCTION rpt.visible_load_runs(bigint) IS
'Returns the load runs whose facts a calculation based on p_load_run_id may use: every succeeded run published no later than it. Raises an error if p_load_run_id does not exist or did not succeed. No side effects.';

CREATE FUNCTION rpt.assert_observation_allowed(p_observed_at timestamptz, p_load_run_id bigint)
RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_source_as_of_at timestamptz;
BEGIN
    SELECT lr.source_as_of_at INTO v_source_as_of_at
      FROM audit.load_run AS lr
     WHERE lr.load_run_id = p_load_run_id;

    IF p_observed_at IS NULL THEN
        RAISE EXCEPTION 'Observation time must not be null';
    END IF;
    -- Observing beyond the checkpoint would silently assume that nothing
    -- happened after the sources were extracted (Arch 9.2).
    IF p_observed_at > v_source_as_of_at THEN
        RAISE EXCEPTION 'Observation time % is later than load run % source checkpoint %',
            p_observed_at, p_load_run_id, v_source_as_of_at;
    END IF;
END;
$$;
COMMENT ON FUNCTION rpt.assert_observation_allowed(timestamptz, bigint) IS
'Raises an error when p_observed_at is null or later than the selected load run''s source_as_of_at checkpoint. Returns nothing otherwise. No side effects.';

CREATE FUNCTION rpt.effective_order_status(p_observed_at timestamptz, p_load_run_id bigint)
RETURNS TABLE (
    order_id          text,
    order_status_key  bigint,
    effective_status  text,
    reason_code       text,
    status_occurred_at timestamptz
)
LANGUAGE plpgsql
STABLE
AS $$
#variable_conflict use_column
BEGIN
    -- The last eligible event at or before the observation time wins. Ties on
    -- occurred_at are resolved by the source event sequence. Today's source
    -- current_status is deliberately not used (Arch 9.4).
    RETURN QUERY
        SELECT DISTINCT ON (e.order_id)
               e.order_id, e.order_status_key, e.new_status, e.reason_code, e.occurred_at
          FROM dw.fact_order_status_event AS e
         WHERE e.first_load_run_id IN (SELECT visible_load_run_id FROM rpt.visible_load_runs(p_load_run_id))
           AND e.occurred_at <= p_observed_at
         ORDER BY e.order_id, e.occurred_at DESC, e.event_sequence DESC;
END;
$$;
COMMENT ON FUNCTION rpt.effective_order_status(timestamptz, bigint) IS
'Returns one row per order accepted by p_observed_at (as known by load p_load_run_id) with its effective status, reason and status time. Orders with no eligible event are not yet accepted and are omitted. No side effects.';


-- -----------------------------------------------------------------------------
-- Integrated stock calculation
-- -----------------------------------------------------------------------------

CREATE FUNCTION rpt.calculate_inventory(p_observed_at timestamptz, p_load_run_id bigint)
RETURNS TABLE (
    product_key         bigint,
    location_key        bigint,
    observed_at         timestamptz,
    load_run_id         bigint,
    snapshot_key        bigint,
    opening_cutoff_at   timestamptz,
    opening_quantity    integer,
    movement_quantity   bigint,
    on_hand_quantity    bigint,
    reserved_quantity   bigint,
    available_quantity  bigint,
    shortfall_quantity  bigint,
    quality_status      text
)
LANGUAGE plpgsql
STABLE
AS $$
#variable_conflict use_column
BEGIN
    PERFORM rpt.assert_observation_allowed(p_observed_at, p_load_run_id);

    RETURN QUERY
    WITH runs AS (
        SELECT visible_load_run_id AS run_id FROM rpt.visible_load_runs(p_load_run_id)
    ),
    movement AS (
        SELECT m.*
          FROM dw.fact_stock_movement AS m
         WHERE m.first_load_run_id IN (SELECT run_id FROM runs)
           AND m.occurred_at <= p_observed_at
    ),
    snapshot AS (
        SELECT s.*
          FROM dw.fact_stock_snapshot AS s
         WHERE s.first_load_run_id IN (SELECT run_id FROM runs)
           AND s.cutoff_at <= p_observed_at
    ),
    order_line AS (
        SELECT l.product_key, l.location_key, l.quantity, st.effective_status
          FROM dw.fact_order_line AS l
          JOIN rpt.effective_order_status(p_observed_at, p_load_run_id) AS st
            ON st.order_id = l.order_id
         WHERE l.first_load_run_id IN (SELECT run_id FROM runs)
    ),
    web_copy AS (
        SELECT c.product_key, c.location_key
          FROM dw.fact_web_stock_copy AS c
         WHERE c.first_load_run_id IN (SELECT run_id FROM runs)
           AND c.copied_at <= p_observed_at
    ),
    -- The universe is the union of every kind of evidence. Inner-joining to
    -- snapshots would hide a pair whose opening balance is missing (Arch 9.2).
    pair AS (
        SELECT product_key, location_key FROM snapshot
        UNION SELECT product_key, location_key FROM movement
        UNION SELECT product_key, location_key FROM order_line
        UNION SELECT product_key, location_key FROM web_copy
    ),
    -- Newest snapshot with cutoff_at <= observed_at for each pair.
    opening AS (
        SELECT DISTINCT ON (s.product_key, s.location_key)
               s.product_key, s.location_key, s.snapshot_key, s.cutoff_at, s.created_at, s.on_hand_quantity
          FROM snapshot AS s
         ORDER BY s.product_key, s.location_key, s.cutoff_at DESC, s.created_at DESC, s.snapshot_key DESC
    ),
    -- Two snapshots with the same cutoff but different balances cannot both be
    -- right; block instead of choosing one arbitrarily (Arch 9.3).
    opening_conflict AS (
        SELECT s.product_key, s.location_key
          FROM snapshot AS s
          JOIN opening AS o USING (product_key, location_key)
         WHERE s.cutoff_at = o.cutoff_at
         GROUP BY s.product_key, s.location_key
        HAVING count(DISTINCT s.on_hand_quantity) > 1
    ),
    -- The opening snapshot already includes events strictly before its cutoff.
    -- Include an event exactly at the cutoff in the subsequent movement total.
    -- Each physical event is a single fact (one origin identity), so a till
    -- sale and its later central import are counted once.
    movement_since_opening AS (
        SELECT o.product_key, o.location_key, coalesce(sum(m.quantity), 0)::bigint AS movement_quantity
          FROM opening AS o
          LEFT JOIN movement AS m
            ON m.product_key = o.product_key
           AND m.location_key = o.location_key
           AND m.occurred_at >= o.cutoff_at
         GROUP BY o.product_key, o.location_key
    ),
    -- An event before the cutoff that its source recorded only after the
    -- snapshot was created cannot be inside that snapshot. Subtracting it
    -- after the cutoff would also be wrong, so the pair needs reconciliation
    -- (Arch 10.5).
    late_before_cutoff AS (
        SELECT DISTINCT o.product_key, o.location_key
          FROM opening AS o
          JOIN movement AS m
            ON m.product_key = o.product_key
           AND m.location_key = o.location_key
           AND m.occurred_at < o.cutoff_at
           AND m.source_recorded_at > o.created_at
    ),
    reserved AS (
        SELECT ol.product_key, ol.location_key, sum(ol.quantity)::bigint AS reserved_quantity
          FROM order_line AS ol
         WHERE ol.effective_status IN ('awaiting_pick', 'ready')
         GROUP BY ol.product_key, ol.location_key
    ),
    assessed AS (
        SELECT p.product_key,
               p.location_key,
               o.snapshot_key,
               o.cutoff_at,
               o.on_hand_quantity AS opening_quantity,
               ms.movement_quantity,
               coalesce(r.reserved_quantity, 0) AS reserved_quantity,
               (o.on_hand_quantity + ms.movement_quantity)::bigint AS raw_on_hand,
               CASE
                   WHEN o.snapshot_key IS NULL THEN 'missing_opening'
                   WHEN oc.product_key IS NOT NULL OR lb.product_key IS NOT NULL THEN 'reconciliation_required'
                   WHEN o.on_hand_quantity + ms.movement_quantity < 0 THEN 'negative_on_hand'
                   ELSE 'valid'
               END AS quality_status
          FROM pair AS p
          LEFT JOIN opening AS o USING (product_key, location_key)
          LEFT JOIN movement_since_opening AS ms USING (product_key, location_key)
          LEFT JOIN opening_conflict AS oc USING (product_key, location_key)
          LEFT JOIN late_before_cutoff AS lb USING (product_key, location_key)
          LEFT JOIN reserved AS r USING (product_key, location_key)
    )
    SELECT a.product_key,
           a.location_key,
           p_observed_at,
           p_load_run_id,
           a.snapshot_key,
           a.cutoff_at,
           a.opening_quantity,
           a.movement_quantity,
           -- Unknown stays null; it is never shown as zero. A negative balance
           -- is kept as a diagnostic, not presented as negative physical stock.
           CASE WHEN a.quality_status IN ('valid', 'negative_on_hand') THEN a.raw_on_hand END,
           a.reserved_quantity,
           CASE WHEN a.quality_status = 'valid' THEN greatest(a.raw_on_hand - a.reserved_quantity, 0) END,
           CASE WHEN a.quality_status = 'valid' THEN greatest(a.reserved_quantity - a.raw_on_hand, 0) END,
           a.quality_status
      FROM assessed AS a;
END;
$$;
COMMENT ON FUNCTION rpt.calculate_inventory(timestamptz, bigint) IS
'Integrated availability for every known product/location at p_observed_at, as known by succeeded load p_load_run_id. Returns opening snapshot basis, movements since its cutoff (inclusive), on hand, active reservations, available and shortfall, plus quality_status valid, missing_opening, negative_on_hand or reconciliation_required. Quantities that cannot be established are null, never zero. Raises an error for an unsuccessful load or an observation later than the load checkpoint. No side effects.';


-- -----------------------------------------------------------------------------
-- Existing website baseline (Spec 5.3)
-- -----------------------------------------------------------------------------

CREATE FUNCTION rpt.calculate_website_inventory(p_observed_at timestamptz, p_load_run_id bigint)
RETURNS TABLE (
    product_key                 bigint,
    location_key                bigint,
    web_copy_key                bigint,
    copy_id                     text,
    snapshot_cutoff_at          timestamptz,
    copied_at                   timestamptz,
    copied_on_hand_quantity     integer,
    fulfilment_quantity         bigint,
    reserved_quantity           bigint,
    website_net_quantity        bigint,
    website_available_quantity  bigint,
    website_quality_status      text
)
LANGUAGE plpgsql
STABLE
AS $$
#variable_conflict use_column
BEGIN
    PERFORM rpt.assert_observation_allowed(p_observed_at, p_load_run_id);

    RETURN QUERY
    WITH runs AS (
        SELECT visible_load_run_id AS run_id FROM rpt.visible_load_runs(p_load_run_id)
    ),
    -- The website replaces its whole copy at each refresh: use the latest
    -- refresh copied at or before the observation, keeping that copy's own
    -- cutoff even if a newer central snapshot exists.
    latest_refresh AS (
        SELECT c.copy_id
          FROM dw.fact_web_stock_copy AS c
         WHERE c.first_load_run_id IN (SELECT run_id FROM runs)
           AND c.copied_at <= p_observed_at
         ORDER BY c.copied_at DESC, c.copy_id DESC
         LIMIT 1
    ),
    web_copy AS (
        SELECT c.*
          FROM dw.fact_web_stock_copy AS c
         WHERE c.copy_id = (SELECT copy_id FROM latest_refresh)
           AND c.first_load_run_id IN (SELECT run_id FROM runs)
    ),
    refresh_cutoff AS (
        SELECT max(snapshot_cutoff_at) AS cutoff_at FROM web_copy
    ),
    order_line AS (
        SELECT l.product_key, l.location_key, l.quantity, st.effective_status
          FROM dw.fact_order_line AS l
          JOIN rpt.effective_order_status(p_observed_at, p_load_run_id) AS st
            ON st.order_id = l.order_id
         WHERE l.first_load_run_id IN (SELECT run_id FROM runs)
    ),
    reserved AS (
        SELECT ol.product_key, ol.location_key, sum(ol.quantity)::bigint AS reserved_quantity
          FROM order_line AS ol
         WHERE ol.effective_status IN ('awaiting_pick', 'ready')
         GROUP BY ol.product_key, ol.location_key
    ),
    -- The website knows only its own physical fulfilments. It misses till
    -- sales, receipts, transfers and adjustments after its copied cutoff.
    -- Interval is inclusive at both ends: [copied cutoff, observed_at].
    fulfilment AS (
        SELECT m.product_key, m.location_key, sum(-m.quantity)::bigint AS fulfilment_quantity
          FROM dw.fact_stock_movement AS m
         WHERE m.first_load_run_id IN (SELECT run_id FROM runs)
           AND m.movement_type IN ('online_collection', 'online_shipment')
           AND m.occurred_at >= (SELECT cutoff_at FROM refresh_cutoff)
           AND m.occurred_at <= p_observed_at
         GROUP BY m.product_key, m.location_key
    ),
    pair AS (
        SELECT product_key, location_key FROM web_copy
        UNION SELECT product_key, location_key FROM order_line
    )
    SELECT p.product_key,
           p.location_key,
           c.web_copy_key,
           c.copy_id,
           c.snapshot_cutoff_at,
           c.copied_at,
           c.on_hand_quantity,
           coalesce(f.fulfilment_quantity, 0),
           coalesce(r.reserved_quantity, 0),
           (c.on_hand_quantity - coalesce(f.fulfilment_quantity, 0) - coalesce(r.reserved_quantity, 0))::bigint,
           greatest(c.on_hand_quantity - coalesce(f.fulfilment_quantity, 0) - coalesce(r.reserved_quantity, 0), 0)::bigint,
           -- No copy means the baseline is unknown, not zero.
           CASE WHEN c.web_copy_key IS NULL THEN 'missing_copy' ELSE 'valid' END
      FROM pair AS p
      LEFT JOIN web_copy AS c USING (product_key, location_key)
      LEFT JOIN fulfilment AS f USING (product_key, location_key)
      LEFT JOIN reserved AS r USING (product_key, location_key);
END;
$$;
COMMENT ON FUNCTION rpt.calculate_website_inventory(timestamptz, bigint) IS
'Recalculates what the existing website believed at p_observed_at: latest copied midnight balance minus online collections/shipments since that copy''s cutoff minus active online reservations (Spec 5.3), as known by load p_load_run_id. website_quality_status is missing_copy (quantities null) when no copy exists. No side effects.';


-- -----------------------------------------------------------------------------
-- Allocation of on-hand stock to active Click & Collect lines (Arch 10.4)
-- -----------------------------------------------------------------------------

CREATE FUNCTION rpt.allocate_order_stock(p_observed_at timestamptz, p_load_run_id bigint)
RETURNS TABLE (
    order_line_key             bigint,
    order_id                   text,
    line_id                    text,
    product_key                bigint,
    location_key               bigint,
    placed_at                  timestamptz,
    order_status_key           bigint,
    effective_status           text,
    requested_quantity         integer,
    on_hand_quantity           bigint,
    earlier_requested_quantity bigint,
    allocated_quantity         bigint,
    line_shortfall_quantity    bigint
)
LANGUAGE plpgsql
STABLE
AS $$
#variable_conflict use_column
BEGIN
    RETURN QUERY
    WITH runs AS (
        SELECT visible_load_run_id AS run_id FROM rpt.visible_load_runs(p_load_run_id)
    ),
    inventory AS (
        SELECT * FROM rpt.calculate_inventory(p_observed_at, p_load_run_id)
    ),
    active_line AS (
        SELECT l.order_line_key, l.order_id, l.line_id, l.product_key, l.location_key,
               l.placed_at, st.order_status_key, st.effective_status, l.quantity
          FROM dw.fact_order_line AS l
          JOIN rpt.effective_order_status(p_observed_at, p_load_run_id) AS st
            ON st.order_id = l.order_id
         WHERE l.first_load_run_id IN (SELECT run_id FROM runs)
           AND l.fulfilment_type = 'click_collect'
           AND st.effective_status IN ('awaiting_pick', 'ready')
    ),
    -- Start from on hand BEFORE subtracting reservations, then give units to
    -- lines in acceptance order. Order ID (byte-wise "C" collation) breaks
    -- equal acceptance times deterministically. The frame ends at the
    -- previous row, so a line never competes with itself.
    ranked AS (
        SELECT a.*,
               i.on_hand_quantity AS pair_on_hand,
               i.quality_status,
               coalesce(sum(a.quantity) OVER (
                   PARTITION BY a.product_key, a.location_key
                   ORDER BY a.placed_at, a.order_id COLLATE "C", a.line_id COLLATE "C"
                   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
               ), 0)::bigint AS earlier_requested
          FROM active_line AS a
          LEFT JOIN inventory AS i USING (product_key, location_key)
    )
    SELECT r.order_line_key, r.order_id, r.line_id, r.product_key, r.location_key,
           r.placed_at, r.order_status_key, r.effective_status, r.quantity,
           r.pair_on_hand,
           r.earlier_requested,
           -- An allocation is an explanation of priority, not a reservation.
           -- It is unknown when on hand is unknown or invalid.
           CASE WHEN r.quality_status = 'valid'
                THEN least(r.quantity::bigint, greatest(r.pair_on_hand - r.earlier_requested, 0)) END,
           CASE WHEN r.quality_status = 'valid'
                THEN r.quantity - least(r.quantity::bigint, greatest(r.pair_on_hand - r.earlier_requested, 0)) END
      FROM ranked AS r;
END;
$$;
COMMENT ON FUNCTION rpt.allocate_order_stock(timestamptz, bigint) IS
'For every active Click & Collect line at p_observed_at, allocates calculated on hand in (placed_at, order_id, line_id) order and returns allocated and shortfall quantities (null when on hand is not valid). Analytical only: creates no reservation and does not authorise partial fulfilment. No side effects.';


-- -----------------------------------------------------------------------------
-- Simulated stock check (Spec 7.1, Arch 13.1)
-- -----------------------------------------------------------------------------

CREATE FUNCTION rpt.check_availability(
    p_observed_at    timestamptz,
    p_load_run_id    bigint,
    p_location_code  text,
    p_request        jsonb,
    p_system_code    text DEFAULT 'online'
)
RETURNS TABLE (
    sku                      text,
    requested_quantity       bigint,
    available_quantity       bigint,
    line_result              text,
    line_quality_status      text,
    overall_result           text,
    canonical_location_code  text,
    load_status              text
)
LANGUAGE plpgsql
STABLE
AS $$
#variable_conflict use_column
DECLARE
    v_load_status    text;
    v_canonical      text;
    v_location_type  text;
BEGIN
    -- Validate the request itself before looking at stock.
    IF p_request IS NULL OR jsonb_typeof(p_request) <> 'array' OR jsonb_array_length(p_request) = 0 THEN
        RAISE EXCEPTION 'Request must be a non-empty JSON array of {"sku": ..., "quantity": ...}';
    END IF;
    IF EXISTS (
        SELECT 1 FROM jsonb_to_recordset(p_request) AS r(sku text, quantity integer)
         WHERE r.sku IS NULL OR r.quantity IS NULL OR r.quantity <= 0
    ) THEN
        RAISE EXCEPTION 'Every requested line needs a SKU and a positive integer quantity';
    END IF;

    SELECT lr.status INTO v_load_status FROM audit.load_run AS lr WHERE lr.load_run_id = p_load_run_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Load run % does not exist', p_load_run_id;
    END IF;

    SELECT li.canonical_location_code INTO v_canonical
      FROM ref.location_identifier AS li
     WHERE li.system_code = p_system_code AND li.location_code = p_location_code;
    SELECT d.location_type INTO v_location_type
      FROM dw.dim_location AS d WHERE d.location_code = v_canonical;
    IF v_location_type = 'dc' THEN
        RAISE EXCEPTION 'Click & Collect pickup location must be a store, not %', v_canonical;
    END IF;

    -- A rejected, failed or running load gives no stock answer. The check
    -- never falls back silently to an older successful run.
    IF v_load_status <> 'succeeded' THEN
        RETURN QUERY
            SELECT r.sku, sum(r.quantity)::bigint, NULL::bigint, 'unknown'::text,
                   'load_not_published'::text, 'unknown'::text, v_canonical, v_load_status
              FROM jsonb_to_recordset(p_request) AS r(sku text, quantity integer)
             GROUP BY r.sku;
        RETURN;
    END IF;

    RETURN QUERY
    WITH requested AS (
        -- Duplicate SKUs in one request are added together before checking.
        SELECT r.sku, sum(r.quantity)::bigint AS quantity
          FROM jsonb_to_recordset(p_request) AS r(sku text, quantity integer)
         GROUP BY r.sku
    ),
    inventory AS (
        SELECT p.sku, i.available_quantity, i.quality_status
          FROM dw.dim_product AS p
          JOIN dw.dim_location AS l ON l.location_code = v_canonical
          JOIN rpt.calculate_inventory(p_observed_at, p_load_run_id) AS i
            ON i.product_key = p.product_key AND i.location_key = l.location_key
    ),
    line AS (
        SELECT q.sku,
               q.quantity,
               i.available_quantity,
               CASE
                   WHEN v_canonical IS NULL OR v_location_type IS NULL THEN 'unknown_location'
                   WHEN i.sku IS NULL THEN 'missing_opening'
                   ELSE i.quality_status
               END AS quality_status
          FROM requested AS q
          LEFT JOIN inventory AS i USING (sku)
    ),
    judged AS (
        SELECT l.*,
               CASE
                   WHEN l.quality_status <> 'valid' THEN 'unknown'
                   WHEN l.available_quantity >= l.quantity THEN 'sufficient'
                   ELSE 'insufficient'
               END AS line_result
          FROM line AS l
    )
    SELECT j.sku,
           j.quantity,
           j.available_quantity,
           j.line_result,
           j.quality_status,
           -- Every line must be covered at the one pickup store. A known
           -- shortage makes the request insufficient even if another line is
           -- unknown; otherwise any unknown line makes the answer unknown.
           CASE
               WHEN bool_or(j.line_result = 'insufficient') OVER () THEN 'insufficient'
               WHEN bool_or(j.line_result = 'unknown') OVER () THEN 'unknown'
               ELSE 'sufficient'
           END,
           v_canonical,
           v_load_status
      FROM judged AS j;
END;
$$;
COMMENT ON FUNCTION rpt.check_availability(timestamptz, bigint, text, jsonb, text) IS
'Simulated online stock check. Inputs: observation time, load run, pickup location code in p_system_code (default online, for example store-parramatta) and a JSON array of {"sku","quantity"} lines. Returns one row per requested SKU with line_result sufficient/insufficient/unknown and the overall_result. Uses rpt.calculate_inventory, so it shares the report definitions. Returns unknown for an unpublished load, unknown location or product, or invalid stock evidence. Raises an error for an empty or malformed request or a DC pickup location. Writes nothing and creates no order.';


-- -----------------------------------------------------------------------------
-- Saved observations
-- -----------------------------------------------------------------------------

CREATE TABLE rpt.report_run (
    report_run_id         bigint GENERATED ALWAYS AS IDENTITY,
    load_run_id           bigint      NOT NULL,
    scenario_code         text        NOT NULL,
    checkpoint_code       text        NOT NULL,
    observed_at           timestamptz NOT NULL,
    created_at            timestamptz NOT NULL DEFAULT clock_timestamp(),
    status                text        NOT NULL DEFAULT 'building',
    calculation_revision  text        NOT NULL,
    CONSTRAINT pk_report_run PRIMARY KEY (report_run_id),
    CONSTRAINT fk_report_run_load_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id),
    CONSTRAINT uq_report_run_checkpoint UNIQUE (scenario_code, checkpoint_code),
    CONSTRAINT ck_report_run_status CHECK (status IN ('building', 'ready', 'failed'))
);
COMMENT ON TABLE rpt.report_run IS
'One saved calculation of all reports at one observation time from one load run. Only ready runs are exposed by the report views; dashboards select one report run so all panels share the same time and load.';
COMMENT ON COLUMN rpt.report_run.checkpoint_code IS
'Scenario label of the observation, for example cp_d1_1500 or cp_hist_d1_1500 for a later reconstruction of 3 pm.';

CREATE TABLE rpt.inventory_observation (
    report_run_id                bigint NOT NULL,
    product_key                  bigint NOT NULL,
    location_key                 bigint NOT NULL,
    snapshot_key                 bigint,
    opening_cutoff_at            timestamptz,
    opening_quantity             integer,
    movement_quantity            bigint,
    on_hand_quantity             bigint,
    reserved_quantity            bigint,
    available_quantity           bigint,
    shortfall_quantity           bigint,
    quality_status               text   NOT NULL,
    web_copy_key                 bigint,
    website_copy_id              text,
    website_snapshot_cutoff_at   timestamptz,
    website_copied_at            timestamptz,
    website_copied_on_hand_quantity integer,
    website_fulfilment_quantity  bigint,
    website_reserved_quantity    bigint,
    website_available_quantity   bigint,
    website_quality_status       text   NOT NULL,
    availability_difference      bigint,
    CONSTRAINT pk_inventory_observation PRIMARY KEY (report_run_id, product_key, location_key),
    CONSTRAINT fk_inventory_observation_report_run FOREIGN KEY (report_run_id) REFERENCES rpt.report_run (report_run_id),
    CONSTRAINT fk_inventory_observation_product FOREIGN KEY (product_key) REFERENCES dw.dim_product (product_key),
    CONSTRAINT fk_inventory_observation_location FOREIGN KEY (location_key) REFERENCES dw.dim_location (location_key),
    CONSTRAINT fk_inventory_observation_snapshot FOREIGN KEY (snapshot_key) REFERENCES dw.fact_stock_snapshot (snapshot_key),
    CONSTRAINT fk_inventory_observation_web_copy FOREIGN KEY (web_copy_key) REFERENCES dw.fact_web_stock_copy (web_copy_key),
    CONSTRAINT ck_inventory_observation_quality CHECK (quality_status IN
        ('valid', 'missing_opening', 'negative_on_hand', 'reconciliation_required')),
    CONSTRAINT ck_inventory_observation_website_quality CHECK (website_quality_status IN ('valid', 'missing_copy'))
);
COMMENT ON TABLE rpt.inventory_observation IS
'One saved product/location result of a report run: integrated quantities, the website baseline and their difference. Immutable once its report run is ready.';
COMMENT ON COLUMN rpt.inventory_observation.available_quantity IS
'Quantity available for a new commitment at the saved observation and load. Null when the calculation cannot establish availability; zero means known unavailability.';
COMMENT ON COLUMN rpt.inventory_observation.availability_difference IS
'website_available_quantity - available_quantity. Positive: the website overstates availability. Negative: it understates. Null when either side is unknown.';

CREATE TABLE rpt.order_line_observation (
    report_run_id            bigint NOT NULL,
    order_line_key           bigint NOT NULL,
    order_status_key         bigint NOT NULL,
    effective_status         text   NOT NULL,
    requested_quantity       integer NOT NULL,
    allocated_quantity       bigint,
    line_shortfall_quantity  bigint,
    is_at_risk               boolean,
    cancellation_reason      text,
    cancelled_at             timestamptz,
    CONSTRAINT pk_order_line_observation PRIMARY KEY (report_run_id, order_line_key),
    CONSTRAINT fk_order_line_observation_report_run FOREIGN KEY (report_run_id) REFERENCES rpt.report_run (report_run_id),
    CONSTRAINT fk_order_line_observation_line FOREIGN KEY (order_line_key) REFERENCES dw.fact_order_line (order_line_key),
    CONSTRAINT fk_order_line_observation_status FOREIGN KEY (order_status_key) REFERENCES dw.fact_order_status_event (order_status_key)
);
COMMENT ON TABLE rpt.order_line_observation IS
'One accepted Click & Collect line at a report run''s observation time, including cancelled and collected lines. Allocation fields are null for inactive lines rather than implying zero was allocated while active. Cancellation reason/time come from the effective history, not the later source state.';

CREATE TABLE rpt.stock_check (
    check_id                 bigint GENERATED ALWAYS AS IDENTITY,
    scenario_code            text        NOT NULL,
    check_code               text        NOT NULL,
    load_run_id              bigint      NOT NULL,
    observed_at              timestamptz NOT NULL,
    system_code              text        NOT NULL,
    location_code            text        NOT NULL,
    canonical_location_code  text,
    request                  jsonb       NOT NULL,
    overall_result           text        NOT NULL,
    load_status              text        NOT NULL,
    created_at               timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT pk_stock_check PRIMARY KEY (check_id),
    CONSTRAINT uq_stock_check_code UNIQUE (scenario_code, check_code),
    CONSTRAINT fk_stock_check_load_run FOREIGN KEY (load_run_id) REFERENCES audit.load_run (load_run_id),
    CONSTRAINT ck_stock_check_result CHECK (overall_result IN ('sufficient', 'insufficient', 'unknown'))
);
COMMENT ON TABLE rpt.stock_check IS
'Saved result of one simulated online stock check (rpt.check_availability). Evidence for the demonstration; it is not an order and reserves nothing.';

CREATE TABLE rpt.stock_check_line (
    check_id             bigint NOT NULL,
    sku                  text   NOT NULL,
    requested_quantity   bigint NOT NULL,
    available_quantity   bigint,
    line_result          text   NOT NULL,
    line_quality_status  text   NOT NULL,
    CONSTRAINT pk_stock_check_line PRIMARY KEY (check_id, sku),
    CONSTRAINT fk_stock_check_line_check FOREIGN KEY (check_id) REFERENCES rpt.stock_check (check_id),
    CONSTRAINT ck_stock_check_line_result CHECK (line_result IN ('sufficient', 'insufficient', 'unknown'))
);
COMMENT ON TABLE rpt.stock_check_line IS
'One requested SKU of a saved simulated stock check with its line answer.';


-- -----------------------------------------------------------------------------
-- Report 1: stock availability comparison
-- -----------------------------------------------------------------------------

CREATE VIEW rpt.v_availability_comparison AS
SELECT rr.report_run_id,
       rr.scenario_code,
       rr.checkpoint_code,
       rr.observed_at,
       lr.load_run_id,
       lr.run_code               AS load_run_code,
       lr.source_as_of_at,
       p.sku,
       p.product_name,
       l.location_code,
       l.location_name,
       l.location_type,
       o.website_available_quantity,
       o.on_hand_quantity        AS calculated_on_hand_quantity,
       o.reserved_quantity,
       o.available_quantity,
       o.shortfall_quantity,
       o.availability_difference,
       CASE
           WHEN o.availability_difference > 0 THEN 'website overstates'
           WHEN o.availability_difference < 0 THEN 'website understates'
           WHEN o.availability_difference = 0 THEN 'equal'
       END                       AS difference_direction,
       o.opening_cutoff_at,
       o.opening_quantity,
       o.movement_quantity,
       o.website_snapshot_cutoff_at,
       o.website_copied_at,
       o.quality_status,
       o.website_quality_status
  FROM rpt.report_run AS rr
  JOIN audit.load_run AS lr ON lr.load_run_id = rr.load_run_id
  JOIN rpt.inventory_observation AS o ON o.report_run_id = rr.report_run_id
  JOIN dw.dim_product AS p ON p.product_key = o.product_key
  JOIN dw.dim_location AS l ON l.location_key = o.location_key
 WHERE rr.status = 'ready';
COMMENT ON VIEW rpt.v_availability_comparison IS
'Report 1. Question: where does website availability differ from the integrated calculation? Grain: one product/location per ready report run. Shows website quantity, calculated on hand, reserved, available, shortfall, the difference and its direction, the opening and website-copy basis, and quality flags. Only ready report runs are shown.';


-- -----------------------------------------------------------------------------
-- Report 2: Click & Collect orders at risk and stock-related cancellations
-- -----------------------------------------------------------------------------

CREATE VIEW rpt.v_order_risk_and_cancellation AS
SELECT rr.report_run_id,
       rr.scenario_code,
       rr.checkpoint_code,
       rr.observed_at,
       f.order_id,
       f.line_id,
       f.placed_at,
       p.sku,
       p.product_name,
       l.location_code           AS pickup_location_code,
       l.location_name           AS pickup_location_name,
       o.effective_status,
       o.requested_quantity,
       o.allocated_quantity,
       o.line_shortfall_quantity,
       o.is_at_risk,
       o.cancellation_reason,
       o.cancelled_at,
       (o.cancellation_reason = 'insufficient_stock') AS is_stock_related_cancellation
  FROM rpt.report_run AS rr
  JOIN rpt.order_line_observation AS o ON o.report_run_id = rr.report_run_id
  JOIN dw.fact_order_line AS f ON f.order_line_key = o.order_line_key
  JOIN dw.dim_product AS p ON p.product_key = f.product_key
  JOIN dw.dim_location AS l ON l.location_key = f.location_key
 WHERE rr.status = 'ready';
COMMENT ON VIEW rpt.v_order_risk_and_cancellation IS
'Report 2. Question: which accepted C&C orders cannot be covered, and which were cancelled for insufficient stock? Grain: one accepted C&C order line per ready report run, using the effective status at the observation time (not today''s status). Active lines carry allocation and shortfall; cancelled lines carry reason and time.';


-- -----------------------------------------------------------------------------
-- Report 3: data update delay (two panels)
-- -----------------------------------------------------------------------------

CREATE VIEW rpt.v_data_update_delay AS
WITH run_extract AS (
    SELECT se.load_run_id, min(se.started_at) AS extract_started_at, max(se.finished_at) AS extract_finished_at
      FROM audit.source_extract AS se
     GROUP BY se.load_run_id
),
event AS (
    SELECT 'physical_movement'::text AS event_kind,
           m.origin_system_code || ':' || m.origin_event_type || ':' || m.origin_event_id || ':' || m.origin_line_id AS source_identity,
           m.movement_type          AS event_detail,
           p.sku,
           l.location_code,
           m.occurred_at,
           m.source_recorded_at,
           m.first_load_run_id,
           m.warehouse_loaded_at
      FROM dw.fact_stock_movement AS m
      JOIN dw.dim_product AS p ON p.product_key = m.product_key
      JOIN dw.dim_location AS l ON l.location_key = m.location_key
    UNION ALL
    SELECT 'order_status',
           'online:status:' || e.event_id || ':0',
           e.order_id || ' ' || coalesce(e.previous_status, 'new') || ' -> ' || e.new_status,
           NULL,
           NULL,
           e.occurred_at,
           e.source_recorded_at,
           e.first_load_run_id,
           e.warehouse_loaded_at
      FROM dw.fact_order_status_event AS e
)
SELECT ev.event_kind,
       ev.source_identity,
       ev.event_detail,
       ev.sku,
       ev.location_code,
       ev.occurred_at,
       ev.source_recorded_at,
       ev.source_recorded_at - ev.occurred_at       AS source_recording_delay,
       lr.load_run_id                               AS first_load_run_id,
       lr.run_code                                  AS first_load_run_code,
       lr.scenario_code,
       x.extract_started_at,
       ev.warehouse_loaded_at,
       lr.published_at,
       lr.published_at - lr.started_at              AS actual_load_runtime,
       lr.scenario_published_at,
       lr.scenario_published_at - ev.occurred_at    AS simulated_delay,
       'simulated (scenario checkpoint time minus event time)'::text AS simulated_delay_label
  FROM event AS ev
  JOIN audit.load_run AS lr ON lr.load_run_id = ev.first_load_run_id
  LEFT JOIN run_extract AS x ON x.load_run_id = lr.load_run_id;
COMMENT ON VIEW rpt.v_data_update_delay IS
'Report 3, event panel. Question: how long did each event take to reach the integrated result? Grain: one physical movement fact or order status fact. Shows event time, source recording time, the first load that published it (actual extraction, insertion and publication times, actual runtime) and the simulated delay to the scenario checkpoint. Actual and simulated durations use different clocks and are labelled separately.';

CREATE VIEW rpt.v_website_stock_age AS
SELECT DISTINCT
       rr.report_run_id,
       rr.scenario_code,
       rr.checkpoint_code,
       rr.observed_at,
       o.website_copy_id,
       o.website_snapshot_cutoff_at,
       o.website_copied_at,
       rr.observed_at - o.website_snapshot_cutoff_at        AS website_basis_age,
       rr.observed_at - o.website_copied_at                 AS website_copy_age,
       o.website_copied_at - o.website_snapshot_cutoff_at   AS website_copy_lag
  FROM rpt.report_run AS rr
  JOIN rpt.inventory_observation AS o ON o.report_run_id = rr.report_run_id
 WHERE rr.status = 'ready'
   AND o.website_quality_status = 'valid';
COMMENT ON VIEW rpt.v_website_stock_age IS
'Report 3, website panel. Question: how old was the website''s stock basis at each observation? Grain: one website copy per ready report run. basis age = observed_at - snapshot cutoff; copy age = observed_at - copied_at; copy lag = copied_at - snapshot cutoff (a 5 am copy of a midnight snapshot is already five hours old).';
