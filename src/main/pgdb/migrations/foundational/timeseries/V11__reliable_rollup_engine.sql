-- Reliability upgrade. Historical migrations and existing rollup tables remain intact.
-- PostgreSQL 14+ is required for date_bin. Legacy targets must be recreated and
-- backfilled: their rounded averages contain insufficient information to repair.

ALTER TABLE silver.timeseries_rollup_config
    ADD COLUMN engine_version INTEGER NOT NULL DEFAULT 1,
    ADD COLUMN dimension_columns TEXT[],
    ADD COLUMN metric_columns TEXT[],
    ADD COLUMN source_rollup_id INTEGER REFERENCES silver.timeseries_rollup_config(id),
    ADD COLUMN refresh_overlap INTERVAL NOT NULL DEFAULT INTERVAL '0',
    ADD COLUMN max_retries INTEGER NOT NULL DEFAULT 5,
    ADD COLUMN retry_base_delay INTERVAL NOT NULL DEFAULT INTERVAL '1 minute',
    ADD COLUMN retry_max_delay INTERVAL NOT NULL DEFAULT INTERVAL '1 hour';

-- A target must have exactly one writer/configuration. Duplicate legacy targets
-- require operator reconciliation before this migration can be applied.
CREATE UNIQUE INDEX timeseries_rollup_target_unique ON silver.timeseries_rollup_config(target_table);
ALTER TABLE silver.timeseries_rollup_config ADD CONSTRAINT timeseries_retry_limits CHECK (
    max_retries > 0 AND retry_base_delay > INTERVAL '0'
    AND retry_max_delay >= retry_base_delay AND refresh_overlap >= INTERVAL '0'
);

CREATE OR REPLACE FUNCTION silver.time_bucket(bucket_width INTERVAL, ts TIMESTAMPTZ)
RETURNS TIMESTAMPTZ LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog AS $$
BEGIN
    IF NOT isfinite(ts) OR NOT isfinite(bucket_width)
       OR EXTRACT(YEAR FROM bucket_width) <> 0 OR EXTRACT(MONTH FROM bucket_width) <> 0
       OR bucket_width <= INTERVAL '0' THEN
        RAISE EXCEPTION 'Bucket width must be a positive fixed interval and timestamp must be finite'
            USING ERRCODE = '22023';
    END IF;
    -- One UTC Monday origin for all widths, including weeks and fractional seconds.
    RETURN date_bin(bucket_width, ts, TIMESTAMPTZ '2000-01-03 00:00:00+00');
END;
$$;

CREATE FUNCTION silver._qualified_table_name(table_name TEXT)
RETURNS TEXT LANGUAGE plpgsql IMMUTABLE STRICT
SET search_path = pg_catalog AS $$
DECLARE parts TEXT[];
BEGIN
    parts := parse_ident(table_name, true);
    IF cardinality(parts) <> 2 THEN
        RAISE EXCEPTION 'Use a schema-qualified table name: %', table_name USING ERRCODE = '22023';
    END IF;
    RETURN format('%I.%I', parts[1], parts[2]);
END;
$$;

CREATE OR REPLACE FUNCTION silver.create_rollup_table(
    source_table_name TEXT,
    target_schema TEXT,
    target_table_name TEXT,
    rollup_table_interval INTERVAL,
    look_back_window INTERVAL DEFAULT '5 minutes'::interval,
    retention_period INTERVAL DEFAULT '30 days'::interval,
    processing_window INTERVAL DEFAULT '1 hour'::interval,
    initial_status TEXT DEFAULT 'idle',
    is_active BOOLEAN DEFAULT TRUE
) RETURNS VOID LANGUAGE plpgsql SET search_path = pg_catalog, silver SET timezone = 'UTC' AS $$
DECLARE
    source_name TEXT := silver._qualified_table_name(source_table_name);
    target_name TEXT := format('%I.%I', target_schema, target_table_name);
    source_oid REGCLASS;
    parent silver.timeseries_rollup_config%ROWTYPE;
    dims TEXT[] := ARRAY[]::TEXT[];
    metrics TEXT[] := ARRAY[]::TEXT[];
    output_names TEXT[] := ARRAY['timestamp', 'rollup_count', 'last_updated_at'];
    defs TEXT := 'timestamp timestamptz NOT NULL';
    keys TEXT := 'timestamp';
    col RECORD;
    dim TEXT;
    metric TEXT;
    prefix TEXT;
    metric_type TEXT;
    metric_type_oid OID;
    partman_schema TEXT;
    partman_version TEXT;
    created BOOLEAN;
BEGIN
    IF source_name IS NULL OR target_schema IS NULL OR target_table_name IS NULL
       OR target_schema = '' OR target_table_name = ''
       OR octet_length(target_schema) > 63 OR octet_length(target_table_name) > 63 THEN
        RAISE EXCEPTION 'Source and target names are required and must fit PostgreSQL identifiers';
    END IF;
    source_oid := to_regclass(source_name);
    IF source_oid IS NULL OR NOT EXISTS (
        SELECT FROM pg_class WHERE oid = source_oid AND relkind IN ('r', 'p')
    ) THEN
        RAISE EXCEPTION 'Source table does not exist or is not a table: %', source_name;
    END IF;
    IF to_regnamespace(target_schema) IS NULL THEN
        RAISE EXCEPTION 'Target schema does not exist: %', target_schema;
    END IF;
    IF source_name = target_name OR to_regclass(target_name) IS NOT NULL THEN
        RAISE EXCEPTION 'Target must be a new table distinct from source: %', target_name;
    END IF;
    IF rollup_table_interval IS NULL THEN RAISE EXCEPTION 'Rollup interval is required'; END IF;
    PERFORM silver.time_bucket(rollup_table_interval, now());
    IF look_back_window IS NULL OR NOT isfinite(look_back_window) OR look_back_window < INTERVAL '0'
       OR retention_period IS NULL OR NOT isfinite(retention_period) OR retention_period <= INTERVAL '0'
       OR processing_window IS NULL OR NOT isfinite(processing_window) OR processing_window <= INTERVAL '0'
       OR initial_status IS DISTINCT FROM 'idle' OR is_active IS NULL THEN
        RAISE EXCEPTION 'Require nonnegative look_back_window, positive retention/processing windows, idle status and nonnull is_active';
    END IF;
    IF NOT EXISTS (
        SELECT FROM pg_attribute WHERE attrelid = source_oid AND attname = 'timestamp'
        AND atttypid = 'timestamptz'::regtype AND attnotnull AND NOT attisdropped
    ) THEN
        RAISE EXCEPTION 'Source % requires timestamp TIMESTAMPTZ NOT NULL', source_name;
    END IF;

    SELECT * INTO parent FROM silver.timeseries_rollup_config rc WHERE rc.target_table = source_name;
    IF FOUND THEN
        IF parent.engine_version <> 2 THEN
            RAISE EXCEPTION 'Recreate and backfill legacy source rollup % before chaining', source_name;
        END IF;
        IF rollup_table_interval <= parent.rollup_table_interval
           OR mod(EXTRACT(EPOCH FROM rollup_table_interval), EXTRACT(EPOCH FROM parent.rollup_table_interval)) <> 0 THEN
            RAISE EXCEPTION 'Child interval must be a larger exact multiple of source rollup interval';
        END IF;
        dims := parent.dimension_columns;
        metrics := parent.metric_columns;
    ELSE
        SELECT COALESCE(array_agg(tdc.dimension_column ORDER BY tdc.dimension_column), ARRAY[]::TEXT[])
        INTO dims FROM silver.timeseries_dimension_config tdc
        WHERE silver._qualified_table_name(tdc.source_table) = source_name AND tdc.is_active;
        FOR col IN SELECT a.attname, a.atttypid FROM pg_attribute a
            WHERE a.attrelid = source_oid AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum
        LOOP
            IF col.attname = 'timestamp' OR col.attname = ANY(dims) THEN CONTINUE; END IF;
            IF col.atttypid NOT IN ('smallint'::regtype, 'integer'::regtype, 'bigint'::regtype,
                'numeric'::regtype, 'real'::regtype, 'double precision'::regtype) THEN
                RAISE EXCEPTION 'Column % in % is not a supported numeric metric; register it as a dimension or use a numeric source table', col.attname, source_name;
            END IF;
            metrics := array_append(metrics, col.attname);
        END LOOP;
    END IF;
    IF cardinality(metrics) = 0 THEN RAISE EXCEPTION 'Source must contain at least one numeric metric'; END IF;

    FOREACH dim IN ARRAY dims LOOP
        IF dim = ANY(output_names) THEN RAISE EXCEPTION 'Reserved or duplicate dimension name: %', dim; END IF;
        SELECT format_type(a.atttypid, a.atttypmod) AS typ, a.attnotnull INTO col
        FROM pg_attribute a WHERE a.attrelid = source_oid AND a.attname = dim AND NOT a.attisdropped;
        IF NOT FOUND OR NOT col.attnotnull THEN
            RAISE EXCEPTION 'Dimension % must exist and be NOT NULL in %', dim, source_name;
        END IF;
        defs := defs || format(', %I %s NOT NULL', dim, col.typ);
        keys := keys || format(', %I', dim);
        output_names := array_append(output_names, dim);
    END LOOP;
    FOREACH metric IN ARRAY metrics LOOP
        SELECT format_type(a.atttypid, a.atttypmod), a.atttypid INTO metric_type, metric_type_oid
        FROM pg_attribute a WHERE a.attrelid = source_oid
        AND a.attname = CASE WHEN parent.id IS NULL THEN metric ELSE 'min_' || metric END AND NOT a.attisdropped;
        IF metric_type IS NULL OR metric_type_oid NOT IN ('smallint'::regtype, 'integer'::regtype,
            'bigint'::regtype, 'numeric'::regtype, 'real'::regtype, 'double precision'::regtype) THEN
            RAISE EXCEPTION 'Numeric source metric is missing or changed: %', metric;
        END IF;
        FOREACH prefix IN ARRAY ARRAY['min_', 'max_', 'sum_', 'count_', 'avg_'] LOOP
            IF octet_length(prefix || metric) > 63 OR (prefix || metric) = ANY(output_names) THEN
                RAISE EXCEPTION 'Generated metric column is too long or collides: %', prefix || metric;
            END IF;
            output_names := array_append(output_names, prefix || metric);
            defs := defs || format(', %I %s', prefix || metric,
                CASE WHEN prefix IN ('min_', 'max_') THEN metric_type
                     WHEN prefix = 'count_' THEN 'bigint NOT NULL' ELSE 'numeric' END);
        END LOOP;
    END LOOP;
    EXECUTE format('CREATE TABLE %s (%s, rollup_count bigint NOT NULL, last_updated_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (%s)) PARTITION BY RANGE (timestamp)', target_name, defs, keys);
    EXECUTE format('CREATE INDEX ON %s USING brin (timestamp)', target_name);

    SELECT n.nspname, e.extversion INTO partman_schema, partman_version
    FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'pg_partman';
    IF partman_version IS NOT NULL THEN
        IF split_part(partman_version, '.', 1)::integer < 5 THEN
            RAISE EXCEPTION 'Automatic partition setup requires pg_partman 5+; found %', partman_version;
        END IF;
        EXECUTE format('SELECT %I.create_parent(p_parent_table := $1, p_control := ''timestamp'', p_interval := ''1 day'', p_premake := 4)', partman_schema)
            INTO created USING target_name;
        IF created IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'pg_partman did not register %', target_name; END IF;
        EXECUTE format('UPDATE %I.part_config SET retention = $1, retention_keep_table = false, infinite_time_partitions = true WHERE parent_table = $2', partman_schema)
            USING retention_period::text, target_name;
    ELSE
        -- Portable mode accepts all dates. Partition rotation/retention requires
        -- pg_partman or operator-managed native partitions; no hidden row deletion.
        EXECUTE format('CREATE TABLE %I.%I PARTITION OF %s DEFAULT', target_schema, '_rollup_default_' || md5(target_name), target_name);
    END IF;
    INSERT INTO silver.timeseries_rollup_config (
        source_table, target_table, rollup_table_interval, look_back_window,
        retention_period, processing_window, max_look_back_window, is_active,
        status, chunk_interval, adaptive_mode, engine_version, dimension_columns, metric_columns, source_rollup_id
    ) VALUES (source_name, target_name, rollup_table_interval, look_back_window,
        retention_period, GREATEST(processing_window, rollup_table_interval),
        GREATEST(processing_window, rollup_table_interval), is_active, initial_status,
        INTERVAL '1 day', false, 2, dims, metrics, parent.id);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON %s TO db_ecs_user', target_name);
END;
$$;

CREATE FUNCTION silver.refresh_rollup(target_table TEXT, window_start TIMESTAMPTZ, window_end TIMESTAMPTZ)
RETURNS BIGINT LANGUAGE plpgsql SET search_path = pg_catalog, silver SET timezone = 'UTC' AS $$
DECLARE
    cfg silver.timeseries_rollup_config%ROWTYPE;
    source_oid REGCLASS;
    target_oid REGCLASS;
    cols TEXT := 'timestamp';
    expressions TEXT;
    grouping TEXT := '1';
    dim TEXT;
    metric TEXT;
    pos INTEGER := 1;
    affected BIGINT;
    started TIMESTAMPTZ := clock_timestamp();
    validation_error TEXT;
BEGIN
    SELECT * INTO cfg FROM silver.timeseries_rollup_config rc
    WHERE rc.target_table = silver._qualified_table_name(refresh_rollup.target_table) FOR UPDATE NOWAIT;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown rollup target: %', target_table; END IF;
    IF cfg.engine_version <> 2 THEN
        RAISE EXCEPTION 'Legacy rollup % must be recreated and backfilled before processing', cfg.target_table;
    END IF;
    IF cfg.dimension_columns IS NULL OR cfg.metric_columns IS NULL OR cardinality(cfg.metric_columns) = 0 THEN
        RAISE EXCEPTION 'Rollup metadata is incomplete for %', cfg.target_table;
    END IF;
    IF window_start IS NULL OR window_end IS NULL OR NOT isfinite(window_start) OR NOT isfinite(window_end)
       OR window_start >= window_end
       OR silver.time_bucket(cfg.rollup_table_interval, window_start) <> window_start
       OR silver.time_bucket(cfg.rollup_table_interval, window_end) <> window_end
       OR window_end > silver.time_bucket(cfg.rollup_table_interval, clock_timestamp()) THEN
        RAISE EXCEPTION 'Refresh bounds must be increasing, finite, complete bucket boundaries (end is exclusive)' USING ERRCODE = '22023';
    END IF;
    source_oid := to_regclass(silver._qualified_table_name(cfg.source_table));
    target_oid := to_regclass(silver._qualified_table_name(cfg.target_table));
    IF source_oid IS NULL OR target_oid IS NULL OR source_oid = target_oid THEN
        RAISE EXCEPTION 'Source and target must exist and differ for %', cfg.target_table;
    END IF;
    -- V12 provides the targeted catalog validator. Recheck before writing so an
    -- ALTER TABLE cannot silently narrow numeric precision or change grouping.
    SELECT v.validation_message INTO validation_error
    FROM silver._validate_rollup_config(cfg.target_table) v WHERE NOT v.is_valid;
    IF FOUND THEN
        RAISE EXCEPTION 'Invalid rollup structure: %', validation_error USING ERRCODE = '55000';
    END IF;
    expressions := 'silver.time_bucket($3, s.timestamp)';
    FOREACH dim IN ARRAY cfg.dimension_columns LOOP
        cols := cols || format(', %I', dim);
        expressions := expressions || format(', s.%I', dim);
        pos := pos + 1;
        grouping := grouping || ', ' || pos;
    END LOOP;
    FOREACH metric IN ARRAY cfg.metric_columns LOOP
        cols := cols || format(', %I, %I, %I, %I, %I', 'min_' || metric, 'max_' || metric,
            'sum_' || metric, 'count_' || metric, 'avg_' || metric);
        IF cfg.source_rollup_id IS NULL THEN
            expressions := expressions || format(', min(s.%1$I), max(s.%1$I), sum(s.%1$I::numeric), count(s.%1$I), avg(s.%1$I::numeric)', metric);
        ELSE
            expressions := expressions || format(', min(s.%I), max(s.%I), sum(s.%I), sum(s.%I)::bigint, sum(s.%I) / NULLIF(sum(s.%I), 0)',
                'min_' || metric, 'max_' || metric, 'sum_' || metric, 'count_' || metric, 'sum_' || metric, 'count_' || metric);
        END IF;
    END LOOP;
    cols := cols || ', rollup_count, last_updated_at';
    expressions := expressions || CASE WHEN cfg.source_rollup_id IS NULL THEN ', count(*)' ELSE ', sum(s.rollup_count)::bigint' END || ', clock_timestamp()';
    -- Replacing the entire range also removes groups deleted from the source.
    -- Both statements, metadata and logging commit or roll back together.
    EXECUTE format('DELETE FROM %s WHERE timestamp >= $1 AND timestamp < $2', target_oid)
        USING window_start, window_end;
    EXECUTE format('INSERT INTO %s (%s) SELECT %s FROM %s s WHERE s.timestamp >= $1 AND s.timestamp < $2 GROUP BY %s',
        target_oid, cols, expressions, source_oid, grouping)
        USING window_start, window_end, cfg.rollup_table_interval;
    GET DIAGNOSTICS affected = ROW_COUNT;
    INSERT INTO silver.timeseries_refresh_log(table_name, start_time, end_time, records_processed, refresh_timestamp)
        VALUES (cfg.target_table, started, clock_timestamp(), affected, clock_timestamp());
    RETURN affected;
END;
$$;

CREATE OR REPLACE FUNCTION silver.perform_rollup(specific_table TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SET search_path = pg_catalog, silver SET timezone = 'UTC' AS $$
DECLARE
    cfg silver.timeseries_rollup_config%ROWTYPE;
    selected_name TEXT := silver._qualified_table_name(specific_table);
    cutoff TIMESTAMPTZ;
    batch_start TIMESTAMPTZ;
    batch_end TIMESTAMPTZ;
    refresh_start TIMESTAMPTZ;
    earliest TIMESTAMPTZ;
    parent_watermark TIMESTAMPTZ;
    started TIMESTAMPTZ;
    affected BIGINT;
    error_detail TEXT;
    error_hint TEXT;
    error_context TEXT;
BEGIN
    -- Row locks survive the inner exception subtransaction; competing workers skip
    -- claimed jobs. Locks release at caller commit/rollback, including disconnects.
    FOR cfg IN SELECT rc.* FROM silver.timeseries_rollup_config rc
        WHERE rc.is_active
          AND (specific_table IS NULL OR rc.source_table = selected_name OR rc.target_table = selected_name)
          AND COALESCE(rc.retry_count, 0) < rc.max_retries
          AND (rc.next_retry_time IS NULL OR rc.next_retry_time <= clock_timestamp())
        ORDER BY rc.id FOR UPDATE SKIP LOCKED
    LOOP
        started := clock_timestamp();
        BEGIN
            IF cfg.engine_version <> 2 THEN
                RAISE EXCEPTION 'Legacy rollup % must be recreated and backfilled before processing', cfg.target_table;
            END IF;
            PERFORM silver.time_bucket(cfg.rollup_table_interval, started);
            IF cfg.processing_window IS NULL OR cfg.processing_window <= INTERVAL '0'
               OR NOT isfinite(cfg.processing_window) OR cfg.look_back_window IS NULL
               OR cfg.look_back_window < INTERVAL '0' OR NOT isfinite(cfg.look_back_window)
               OR NOT isfinite(cfg.refresh_overlap)
               OR EXTRACT(YEAR FROM cfg.refresh_overlap) <> 0 OR EXTRACT(MONTH FROM cfg.refresh_overlap) <> 0 THEN
                RAISE EXCEPTION 'Invalid processing window, lateness delay or refresh overlap';
            END IF;
            UPDATE silver.timeseries_rollup_config SET status = 'processing', worker_id = pg_backend_pid()::text,
                started_at = started WHERE id = cfg.id;
            cutoff := silver.time_bucket(cfg.rollup_table_interval, started - cfg.look_back_window);
            IF cfg.source_rollup_id IS NOT NULL THEN
                SELECT rc.last_processed_time INTO parent_watermark FROM silver.timeseries_rollup_config rc WHERE rc.id = cfg.source_rollup_id;
                IF parent_watermark IS NULL THEN
                    UPDATE silver.timeseries_rollup_config SET status = 'idle', worker_id = NULL, started_at = NULL WHERE id = cfg.id;
                    CONTINUE;
                END IF;
                cutoff := LEAST(cutoff, silver.time_bucket(cfg.rollup_table_interval, parent_watermark));
            END IF;
            IF cfg.last_processed_time IS NULL THEN
                EXECUTE format('SELECT min(timestamp) FROM %s', silver._qualified_table_name(cfg.source_table)) INTO earliest;
                IF earliest IS NULL THEN
                    UPDATE silver.timeseries_rollup_config SET status = 'idle', worker_id = NULL, started_at = NULL WHERE id = cfg.id;
                    CONTINUE;
                END IF;
                batch_start := silver.time_bucket(cfg.rollup_table_interval, earliest);
            ELSE
                batch_start := silver.time_bucket(cfg.rollup_table_interval, cfg.last_processed_time);
            END IF;
            batch_end := LEAST(cutoff, silver.time_bucket(cfg.rollup_table_interval,
                batch_start + GREATEST(cfg.processing_window, cfg.rollup_table_interval)));
            refresh_start := batch_start;
            IF cfg.last_processed_time IS NOT NULL AND cfg.refresh_overlap > INTERVAL '0' THEN
                -- Overlap is bounded to one processing window in addition to the
                -- forward window, so a large configured overlap cannot unbound work.
                refresh_start := silver.time_bucket(cfg.rollup_table_interval,
                    LEAST(batch_start, cutoff) - LEAST(cfg.refresh_overlap, GREATEST(cfg.processing_window, cfg.rollup_table_interval)));
            END IF;
            IF refresh_start >= batch_end THEN
                UPDATE silver.timeseries_rollup_config SET status = 'idle', worker_id = NULL, started_at = NULL WHERE id = cfg.id;
                CONTINUE;
            END IF;
            affected := silver.refresh_rollup(cfg.target_table, refresh_start, batch_end);
            UPDATE silver.timeseries_rollup_config SET status = 'idle', worker_id = NULL, started_at = NULL,
                last_processed_time = GREATEST(COALESCE(cfg.last_processed_time, batch_end), batch_end),
                last_aggregation_time = clock_timestamp(), last_processed_rows = affected,
                avg_processing_time = CASE WHEN cfg.avg_processing_time IS NULL THEN clock_timestamp() - started
                    ELSE cfg.avg_processing_time * 0.7 + (clock_timestamp() - started) * 0.3 END,
                retry_count = 0, next_retry_time = NULL, last_error_time = NULL WHERE id = cfg.id;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS error_detail = PG_EXCEPTION_DETAIL, error_hint = PG_EXCEPTION_HINT,
                error_context = PG_EXCEPTION_CONTEXT;
            INSERT INTO silver.timeseries_error_log(source_table, target_table, error_message, sql_state,
                error_detail, error_hint, error_context)
                VALUES (cfg.source_table, cfg.target_table, SQLERRM, SQLSTATE, error_detail, error_hint, error_context);
            UPDATE silver.timeseries_rollup_config SET status = 'error', worker_id = NULL, started_at = NULL,
                retry_count = COALESCE(cfg.retry_count, 0) + 1, last_error_time = clock_timestamp(),
                next_retry_time = CASE WHEN COALESCE(cfg.retry_count, 0) + 1 >= cfg.max_retries THEN NULL
                    ELSE clock_timestamp() + LEAST(cfg.retry_max_delay,
                        cfg.retry_base_delay * power(2::double precision, LEAST(COALESCE(cfg.retry_count, 0), 30))) END
                WHERE id = cfg.id;
            RAISE WARNING 'Rollup % failed: %', cfg.target_table, SQLERRM;
        END;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION silver.handle_rollup_retries()
RETURNS VOID LANGUAGE plpgsql SET search_path = pg_catalog, silver AS $$
DECLARE job RECORD;
BEGIN
    FOR job IN SELECT rc.target_table FROM silver.timeseries_rollup_config rc
        WHERE rc.is_active AND rc.retry_count > 0 AND rc.retry_count < rc.max_retries
        AND rc.next_retry_time <= clock_timestamp() ORDER BY rc.id FOR UPDATE SKIP LOCKED
    LOOP
        PERFORM silver.perform_rollup(job.target_table);
    END LOOP;
END;
$$;

CREATE FUNCTION silver.reset_rollup_retry(target_table TEXT)
RETURNS VOID LANGUAGE plpgsql SET search_path = pg_catalog, silver AS $$
BEGIN
    UPDATE silver.timeseries_rollup_config rc SET retry_count = 0, next_retry_time = NULL,
        last_error_time = NULL, status = 'idle', worker_id = NULL, started_at = NULL
    WHERE rc.target_table = silver._qualified_table_name(reset_rollup_retry.target_table);
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown rollup target: %', target_table; END IF;
END;
$$;

-- Functions remain SECURITY INVOKER. The writer role needs table/sequence access;
-- creating a new rollup requires a schema owner, not an implicit privilege escalation.
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA silver TO db_ecs_user;
GRANT EXECUTE ON FUNCTION silver.refresh_rollup(TEXT, TIMESTAMPTZ, TIMESTAMPTZ) TO db_ecs_user;
GRANT EXECUTE ON FUNCTION silver.reset_rollup_retry(TEXT) TO db_ecs_user;
COMMENT ON FUNCTION silver.time_bucket(INTERVAL, TIMESTAMPTZ) IS
'Fixed-width UTC buckets anchored to Monday 2000-01-03; supports subsecond/negative-epoch timestamps, rejects calendar months and nonpositive widths.';
COMMENT ON FUNCTION silver.refresh_rollup(TEXT, TIMESTAMPTZ, TIMESTAMPTZ) IS
'Atomically replaces complete buckets in [start,end), logs output row count, and returns it. Explicit backfills do not move the incremental watermark.';
COMMENT ON COLUMN silver.timeseries_rollup_config.look_back_window IS 'Lateness delay: the worker processes only buckets ending before now() minus this interval.';
COMMENT ON COLUMN silver.timeseries_rollup_config.refresh_overlap IS 'Recompute recent buckets for late data. Effective overlap is capped to one processing window.';
COMMENT ON COLUMN silver.timeseries_rollup_config.engine_version IS '1 = legacy, requires recreation/backfill; 2 = complete-bucket, composable numeric state.';
