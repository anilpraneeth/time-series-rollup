-- Read-only, parent-first planning for resumable historical backfills.
-- Existing refresh and incremental watermark behavior remains unchanged.

CREATE FUNCTION silver._backfill_config_snapshot(config_id INTEGER)
RETURNS JSONB LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, silver SET timezone = 'UTC' SET intervalstyle = 'postgres' AS $$
DECLARE
    cfg silver.timeseries_rollup_config%ROWTYPE;
BEGIN
    SELECT rc.* INTO cfg FROM silver.timeseries_rollup_config rc
    WHERE rc.id = _backfill_config_snapshot.config_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown rollup configuration: %', config_id USING ERRCODE = '22023';
    END IF;
    RETURN jsonb_build_object(
        'id', cfg.id,
        'source_table', cfg.source_table,
        'target_table', cfg.target_table,
        'source_oid', to_regclass(cfg.source_table)::oid,
        'target_oid', to_regclass(cfg.target_table)::oid,
        'source_rollup_id', cfg.source_rollup_id,
        'engine_version', cfg.engine_version,
        'rollup_table_interval', cfg.rollup_table_interval,
        'dimension_columns', cfg.dimension_columns,
        'metric_columns', cfg.metric_columns
    );
END;
$$;

CREATE FUNCTION silver.plan_rollup_backfill(
    specific_target TEXT, window_start TIMESTAMPTZ, window_end TIMESTAMPTZ
) RETURNS TABLE (
    step_order INTEGER,
    config_id INTEGER,
    source_table TEXT,
    target_table TEXT,
    range_start TIMESTAMPTZ,
    range_end TIMESTAMPTZ,
    batch_interval INTERVAL,
    estimated_batches BIGINT
) LANGUAGE plpgsql STABLE SET search_path = pg_catalog, silver SET timezone = 'UTC' AS $$
DECLARE
    selected_name TEXT;
    selected_cfg silver.timeseries_rollup_config%ROWTYPE;
    cfg silver.timeseries_rollup_config%ROWTYPE;
    parent_cfg silver.timeseries_rollup_config%ROWTYPE;
    chain_ids INTEGER[] := ARRAY[]::INTEGER[];
    source_name TEXT;
    source_producer_id INTEGER;
    validation_error TEXT;
    chain_position INTEGER;
    bucket_seconds NUMERIC;
    batch_seconds NUMERIC;
    planned_start TIMESTAMPTZ;
    planned_end TIMESTAMPTZ;
BEGIN
    IF specific_target IS NULL OR window_start IS NULL OR window_end IS NULL
       OR NOT isfinite(window_start) OR NOT isfinite(window_end)
       OR window_start >= window_end THEN
        RAISE EXCEPTION 'Backfill target and increasing, finite range bounds are required'
            USING ERRCODE = '22023';
    END IF;
    BEGIN
        selected_name := silver._qualified_table_name(specific_target);
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Invalid schema-qualified backfill target: %', specific_target
            USING ERRCODE = '22023';
    END;
    SELECT rc.* INTO selected_cfg FROM silver.timeseries_rollup_config rc
    WHERE rc.target_table = selected_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown rollup target: %', specific_target USING ERRCODE = '22023';
    END IF;

    -- Walk the explicit lineage first, so a malformed cycle cannot make a
    -- recursive plan loop forever. The target lookup also detects a managed
    -- rollup incorrectly presented as a raw source with a NULL parent ID.
    cfg := selected_cfg;
    LOOP
        IF cfg.id = ANY(chain_ids) THEN
            RAISE EXCEPTION 'Cycle in rollup hierarchy at %', cfg.target_table
                USING ERRCODE = '55000';
        END IF;
        chain_ids := array_append(chain_ids, cfg.id);
        BEGIN
            source_name := silver._qualified_table_name(cfg.source_table);
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'Invalid source metadata for %', cfg.target_table
                USING ERRCODE = '55000';
        END;
        SELECT rc.id INTO source_producer_id FROM silver.timeseries_rollup_config rc
        WHERE rc.target_table = source_name;
        IF cfg.source_rollup_id IS DISTINCT FROM source_producer_id THEN
            RAISE EXCEPTION 'Source metadata mismatch for %: source_rollup_id must identify the configuration producing %',
                cfg.target_table, cfg.source_table USING ERRCODE = '55000';
        END IF;
        IF cfg.source_rollup_id IS NULL THEN EXIT; END IF;
        SELECT rc.* INTO parent_cfg FROM silver.timeseries_rollup_config rc
        WHERE rc.id = cfg.source_rollup_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Missing parent configuration % for %', cfg.source_rollup_id, cfg.target_table
                USING ERRCODE = '55000';
        END IF;
        IF parent_cfg.target_table IS DISTINCT FROM source_name THEN
            RAISE EXCEPTION 'Parent configuration does not produce source % for %', cfg.source_table, cfg.target_table
                USING ERRCODE = '55000';
        END IF;
        cfg := parent_cfg;
    END LOOP;

    -- Validate every level, including inactive configurations, before emitting
    -- the plan. Policies that contain calendar months have no fixed batch size.
    FOR chain_position IN REVERSE cardinality(chain_ids)..1 LOOP
        SELECT rc.* INTO cfg FROM silver.timeseries_rollup_config rc
        WHERE rc.id = chain_ids[chain_position];
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Rollup hierarchy changed during planning' USING ERRCODE = '55000';
        END IF;
        SELECT v.validation_message INTO validation_error
        FROM silver._validate_rollup_config(cfg.target_table) v WHERE NOT v.is_valid;
        IF FOUND THEN
            RAISE EXCEPTION 'Invalid rollup structure for %: %', cfg.target_table, validation_error
                USING ERRCODE = '55000';
        END IF;
        IF cfg.processing_window IS NULL OR NOT isfinite(cfg.processing_window)
           OR cfg.processing_window <= INTERVAL '0'
           OR extract(year FROM cfg.processing_window) <> 0
           OR extract(month FROM cfg.processing_window) <> 0 THEN
            RAISE EXCEPTION 'Backfill processing_window must be a finite, positive fixed interval for %', cfg.target_table
                USING ERRCODE = '55000';
        END IF;
    END LOOP;

    planned_start := silver.time_bucket(selected_cfg.rollup_table_interval, window_start);
    planned_end := silver.time_bucket(selected_cfg.rollup_table_interval, window_end);
    IF planned_end < window_end THEN
        planned_end := planned_end + selected_cfg.rollup_table_interval;
    END IF;
    IF planned_end > silver.time_bucket(selected_cfg.rollup_table_interval, CURRENT_TIMESTAMP) THEN
        RAISE EXCEPTION 'Expanded backfill range ends in an unfinished or future bucket: %', planned_end
            USING ERRCODE = '22023';
    END IF;

    step_order := 0;
    FOR chain_position IN REVERSE cardinality(chain_ids)..1 LOOP
        SELECT rc.* INTO cfg FROM silver.timeseries_rollup_config rc
        WHERE rc.id = chain_ids[chain_position];
        step_order := step_order + 1;
        config_id := cfg.id;
        source_table := cfg.source_table;
        target_table := cfg.target_table;
        range_start := planned_start;
        range_end := planned_end;
        bucket_seconds := extract(epoch FROM cfg.rollup_table_interval);
        batch_seconds := bucket_seconds * greatest(1::numeric,
            floor(extract(epoch FROM cfg.processing_window) / bucket_seconds));
        -- Construct from numeric seconds instead of interval * float8, keeping
        -- subsecond bucket boundaries exact while rounding processing windows.
        batch_interval := (batch_seconds::text || ' seconds')::interval;
        estimated_batches := ceil(extract(epoch FROM planned_end - planned_start) / batch_seconds)::bigint;
        RETURN NEXT;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION silver._backfill_config_snapshot(INTEGER) IS
'Semantic configuration and relation identities for detecting queued-backfill drift. Includes lineage, numeric metadata and bucket width; excludes worker state and mutable processing policy.';
COMMENT ON FUNCTION silver.plan_rollup_backfill(TEXT, TIMESTAMPTZ, TIMESTAMPTZ) IS
'Read-only parent-first plan from raw source to selected coarsest target. Widens [start,end) to complete selected-target buckets and rejects unfinished output buckets. Includes inactive ancestors, excludes siblings/descendants, and preserves watermarks. Source-history completeness is the operator responsibility.';

GRANT EXECUTE ON FUNCTION silver._backfill_config_snapshot(INTEGER) TO db_ecs_user;
GRANT EXECUTE ON FUNCTION silver.plan_rollup_backfill(TEXT, TIMESTAMPTZ, TIMESTAMPTZ) TO db_ecs_user;
