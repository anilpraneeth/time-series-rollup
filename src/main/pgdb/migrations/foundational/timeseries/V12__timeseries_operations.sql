-- Operational views and maintenance for the version 2 rollup engine.
-- Preserve historical migration checksums and the public result signatures.

CREATE OR REPLACE FUNCTION silver.get_detailed_stats(table_pattern TEXT)
RETURNS TABLE (
    table_name TEXT, total_size BIGINT, index_size BIGINT,
    live_rows BIGINT, dead_rows BIGINT, last_vacuum TIMESTAMPTZ,
    last_analyze TIMESTAMPTZ, avg_query_time FLOAT, cache_hit_ratio FLOAT,
    bloat_ratio FLOAT, write_rate BIGINT, read_rate BIGINT
) LANGUAGE SQL STABLE AS $$
    WITH roots AS (
        SELECT c.oid, format('%I.%I', n.nspname, c.relname) AS full_name
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'p')
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND n.nspname NOT LIKE 'pg_toast%'
          AND (c.relname LIKE table_pattern
               OR format('%I.%I', n.nspname, c.relname) LIKE table_pattern)
    ), members AS (
        SELECT r.oid AS root_oid, r.full_name, tree.relid::oid AS member_oid
        FROM roots r CROSS JOIN LATERAL pg_partition_tree(r.oid) tree
        WHERE tree.isleaf
        UNION ALL
        SELECT r.oid, r.full_name, r.oid
        FROM roots r JOIN pg_class c ON c.oid = r.oid
        WHERE c.relkind = 'r' AND NOT c.relispartition
    )
    SELECT r.full_name,
        COALESCE(SUM(pg_total_relation_size(m.member_oid)), 0)::bigint,
        COALESCE(SUM(pg_indexes_size(m.member_oid)), 0)::bigint,
        COALESCE(SUM(s.n_live_tup), 0)::bigint,
        COALESCE(SUM(s.n_dead_tup), 0)::bigint,
        MAX(GREATEST(s.last_vacuum, s.last_autovacuum)),
        GREATEST(MAX(GREATEST(s.last_analyze, s.last_autoanalyze)),
                 MAX(GREATEST(root_stats.last_analyze, root_stats.last_autoanalyze))),
        NULL::double precision,
        CASE WHEN SUM(io.heap_blks_hit + io.heap_blks_read) > 0
             THEN SUM(io.heap_blks_hit)::double precision /
                  SUM(io.heap_blks_hit + io.heap_blks_read)::double precision
             ELSE NULL::double precision END,
        CASE WHEN SUM(s.n_live_tup) > 0
             THEN SUM(s.n_dead_tup)::double precision / SUM(s.n_live_tup)::double precision
             ELSE NULL::double precision END,
        COALESCE(SUM(s.n_tup_ins + s.n_tup_upd + s.n_tup_del), 0)::bigint,
        COALESCE(SUM(s.seq_scan + COALESCE(s.idx_scan, 0)), 0)::bigint
    FROM roots r
    LEFT JOIN members m ON m.root_oid = r.oid
    LEFT JOIN pg_stat_user_tables s ON s.relid = m.member_oid
    LEFT JOIN pg_statio_user_tables io ON io.relid = m.member_oid
    LEFT JOIN pg_stat_user_tables root_stats ON root_stats.relid = r.oid
    GROUP BY r.oid, r.full_name
    ORDER BY r.full_name;
$$;

COMMENT ON FUNCTION silver.get_detailed_stats(TEXT) IS
'Table statistics, including leaf partitions. Row counts are estimates; write_rate/read_rate are cumulative counters since statistics reset, not rates. bloat_ratio is the dead/live tuple ratio, not measured storage bloat. avg_query_time is NULL because it is not measured. Empty cache statistics return NULL.';

CREATE OR REPLACE FUNCTION silver.get_partition_stats(parent_table_name TEXT)
RETURNS TABLE (
    partition_full_name TEXT, partition_range TEXT, total_size TEXT,
    table_size TEXT, index_size TEXT, row_count NUMERIC, bytes_per_row TEXT
) LANGUAGE plpgsql STABLE AS $$
DECLARE
    parent_oid regclass := to_regclass(parent_table_name);
BEGIN
    IF parent_oid IS NULL THEN
        RAISE EXCEPTION 'Table % does not exist', parent_table_name USING ERRCODE = '42P01';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = parent_oid AND c.relkind = 'p') THEN
        RAISE EXCEPTION 'Table % is not partitioned', parent_table_name USING ERRCODE = '42809';
    END IF;
    RETURN QUERY
    SELECT format('%I.%I', n.nspname, c.relname),
           pg_get_expr(c.relpartbound, c.oid),
           pg_size_pretty(pg_total_relation_size(c.oid)),
           pg_size_pretty(pg_relation_size(c.oid)),
           pg_size_pretty(pg_indexes_size(c.oid)),
           COALESCE(s.n_live_tup, 0)::numeric,
           CASE WHEN s.n_live_tup > 0
                THEN pg_size_pretty(pg_total_relation_size(c.oid) / s.n_live_tup)
                ELSE 'N/A' END
    FROM pg_partition_tree(parent_oid) tree
    JOIN pg_class c ON c.oid = tree.relid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
    WHERE tree.isleaf AND tree.level > 0
    ORDER BY n.nspname, c.relname;
END;
$$;

COMMENT ON FUNCTION silver.get_partition_stats(TEXT) IS
'Statistics for actual leaf partitions, including nested and default partitions. Catalog relationships determine membership; names are not inferred. row_count is the current statistics estimate.';

CREATE OR REPLACE FUNCTION silver.optimize_chunk_interval(
    table_name TEXT, target_chunk_size BIGINT DEFAULT 268435456
) RETURNS INTERVAL LANGUAGE plpgsql AS $$
DECLARE
    source_oid regclass := to_regclass(table_name);
    source_name text;
    total_bytes numeric;
    estimated_rows numeric;
    recent_rows numeric;
    observed_seconds numeric;
    recommended_seconds numeric;
BEGIN
    IF source_oid IS NULL THEN
        RAISE EXCEPTION 'Table % does not exist', table_name USING ERRCODE = '42P01';
    END IF;
    IF target_chunk_size IS NULL OR target_chunk_size <= 0 THEN
        RAISE EXCEPTION 'target_chunk_size must be positive' USING ERRCODE = '22023';
    END IF;
    SELECT format('%I.%I', n.nspname, c.relname) INTO source_name
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = source_oid;
    SELECT s.total_size, s.live_rows INTO total_bytes, estimated_rows
    FROM silver.get_detailed_stats(source_name) s WHERE s.table_name = source_name;
    IF COALESCE(total_bytes, 0) = 0 OR COALESCE(estimated_rows, 0) = 0 THEN
        RETURN INTERVAL '1 day';
    END IF;
    EXECUTE format(
        'SELECT count(*)::numeric, extract(epoch FROM max(timestamp) - min(timestamp)) '
        'FROM %s WHERE timestamp >= $1 AND timestamp <= $2', source_name)
        INTO recent_rows, observed_seconds
        USING CURRENT_TIMESTAMP - INTERVAL '1 day', CURRENT_TIMESTAMP;
    IF recent_rows < 2 OR COALESCE(observed_seconds, 0) <= 0 THEN
        RETURN INTERVAL '1 day';
    END IF;
    recommended_seconds := target_chunk_size * estimated_rows / total_bytes
                           * observed_seconds / recent_rows;
    IF recommended_seconds < 86400 THEN
        RETURN make_interval(hours => greatest(1, floor(recommended_seconds / 3600)::int));
    END IF;
    RETURN make_interval(days => least(7, floor(recommended_seconds / 86400))::int);
END;
$$;

COMMENT ON FUNCTION silver.optimize_chunk_interval(TEXT, BIGINT) IS
'Advisory partition interval from estimated leaf sizes and the last day of observed rows. Returns a bounded 1-hour to 7-day recommendation, or 1 day when evidence is insufficient. Does not alter a partition set.';

CREATE OR REPLACE FUNCTION silver._validate_rollup_config(specific_target TEXT)
RETURNS TABLE (source_table TEXT, target_table TEXT, is_valid BOOLEAN, validation_message TEXT)
LANGUAGE plpgsql SET search_path = pg_catalog, silver AS $$
DECLARE
    selected_target TEXT := silver._qualified_table_name(specific_target);
    cfg silver.timeseries_rollup_config%ROWTYPE;
    parent_cfg silver.timeseries_rollup_config%ROWTYPE;
    source_oid regclass;
    target_oid regclass;
    issues text[];
    col text;
    metric text;
    source_type oid;
    source_modifier integer;
    actual_type oid;
    actual_modifier integer;
    key_columns text[];
    expected_keys text[];
    attr_name text;
    expected_type oid;
    expected_modifier integer;
BEGIN
    FOR cfg IN SELECT rc.* FROM silver.timeseries_rollup_config rc
               WHERE (selected_target IS NULL AND rc.is_active)
                  OR (selected_target IS NOT NULL AND rc.target_table = selected_target)
               ORDER BY rc.id
    LOOP
        issues := ARRAY[]::text[];
        source_oid := NULL;
        target_oid := NULL;
        BEGIN
            source_oid := to_regclass(cfg.source_table);
            target_oid := to_regclass(cfg.target_table);
        EXCEPTION WHEN OTHERS THEN
            issues := array_append(issues, 'Invalid relation name: ' || SQLERRM);
        END;
        IF source_oid IS NULL THEN issues := array_append(issues, 'Source table does not exist'); END IF;
        IF target_oid IS NULL THEN issues := array_append(issues, 'Target table does not exist'); END IF;
        IF source_oid = target_oid THEN issues := array_append(issues, 'Source and target must differ'); END IF;
        IF cfg.engine_version IS DISTINCT FROM 2 THEN
            issues := array_append(issues, 'Legacy rollup: recreate the target with engine version 2 and backfill from retained source data');
        END IF;
        BEGIN
            PERFORM silver.time_bucket(cfg.rollup_table_interval, TIMESTAMPTZ '2000-01-01 00:00:00+00');
        EXCEPTION WHEN OTHERS THEN
            issues := array_append(issues, 'Invalid rollup interval: ' || SQLERRM);
        END;
        IF cfg.processing_window IS NULL OR NOT isfinite(cfg.processing_window) OR cfg.processing_window <= INTERVAL '0' THEN
            issues := array_append(issues, 'processing_window must be finite and positive');
        END IF;
        IF cfg.look_back_window IS NULL OR NOT isfinite(cfg.look_back_window) OR cfg.look_back_window < INTERVAL '0' THEN
            issues := array_append(issues, 'look_back_window must be finite and nonnegative');
        END IF;
        IF cfg.refresh_overlap IS NULL OR NOT isfinite(cfg.refresh_overlap) OR cfg.refresh_overlap < INTERVAL '0'
           OR extract(year FROM cfg.refresh_overlap) <> 0 OR extract(month FROM cfg.refresh_overlap) <> 0 THEN
            issues := array_append(issues, 'refresh_overlap must be a finite, nonnegative fixed interval');
        END IF;
        IF source_oid IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM pg_attribute a WHERE a.attrelid = source_oid AND a.attname = 'timestamp'
              AND a.atttypid = 'timestamptz'::regtype AND a.attnotnull AND a.attnum > 0 AND NOT a.attisdropped
        ) THEN issues := array_append(issues, 'Source requires a NOT NULL timestamp column of type timestamptz'); END IF;
        IF target_oid IS NOT NULL THEN
            IF NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = target_oid AND c.relkind = 'p') THEN
                issues := array_append(issues, 'Target must be a partitioned table');
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM pg_partitioned_table pt JOIN pg_attribute a
                    ON a.attrelid = pt.partrelid AND a.attnum = pt.partattrs[0]
                WHERE pt.partrelid = target_oid AND pt.partstrat = 'r'
                  AND pt.partnatts = 1 AND a.attname = 'timestamp'
            ) THEN issues := array_append(issues, 'Target must use RANGE partitioning on timestamp alone'); END IF;
            IF NOT EXISTS (
                SELECT 1 FROM pg_attribute a WHERE a.attrelid = target_oid AND a.attname = 'timestamp'
                  AND a.atttypid = 'timestamptz'::regtype AND a.attnotnull AND NOT a.attisdropped
            ) THEN issues := array_append(issues, 'Target requires a NOT NULL timestamptz timestamp'); END IF;
        END IF;
        IF cfg.engine_version = 2 AND source_oid IS NOT NULL AND target_oid IS NOT NULL THEN
            IF cfg.dimension_columns IS NULL OR cfg.metric_columns IS NULL THEN
                issues := array_append(issues, 'Frozen dimension_columns and metric_columns are required');
            END IF;
            IF COALESCE(cardinality(cfg.metric_columns), 0) = 0 THEN
                issues := array_append(issues, 'At least one frozen numeric metric is required');
            END IF;
            FOREACH col IN ARRAY COALESCE(cfg.dimension_columns, ARRAY[]::text[]) LOOP
                SELECT a.atttypid, a.atttypmod INTO source_type, source_modifier FROM pg_attribute a
                WHERE a.attrelid = source_oid AND a.attname = col AND a.attnum > 0 AND NOT a.attisdropped AND a.attnotnull;
                SELECT a.atttypid, a.atttypmod INTO actual_type, actual_modifier FROM pg_attribute a
                WHERE a.attrelid = target_oid AND a.attname = col AND a.attnum > 0
                  AND NOT a.attisdropped AND a.attnotnull;
                IF source_type IS NULL OR actual_type IS DISTINCT FROM source_type
                   OR actual_modifier IS DISTINCT FROM source_modifier THEN
                    issues := array_append(issues, format('Dimension %I is missing, nullable, or has a different type', col));
                END IF;
            END LOOP;
            SELECT array_agg(a.attname::text ORDER BY a.attname::text) INTO key_columns
            FROM pg_constraint pc CROSS JOIN LATERAL unnest(pc.conkey) k(attnum)
            JOIN pg_attribute a ON a.attrelid = pc.conrelid AND a.attnum = k.attnum
            WHERE pc.conrelid = target_oid AND pc.contype = 'p';
            SELECT array_agg(k ORDER BY k) INTO expected_keys
            FROM unnest(ARRAY['timestamp']::text[] || COALESCE(cfg.dimension_columns, ARRAY[]::text[])) k;
            IF key_columns IS DISTINCT FROM expected_keys THEN
                issues := array_append(issues, 'Target primary key must contain exactly timestamp and the frozen dimensions');
            END IF;
            FOREACH metric IN ARRAY COALESCE(cfg.metric_columns, ARRAY[]::text[]) LOOP
                SELECT a.atttypid, a.atttypmod INTO source_type, source_modifier FROM pg_attribute a
                WHERE a.attrelid = source_oid AND a.attnum > 0 AND NOT a.attisdropped
                  AND a.attname = CASE WHEN cfg.source_rollup_id IS NULL THEN metric ELSE 'min_' || metric END;
                IF source_type IS NULL OR source_type NOT IN (
                    'smallint'::regtype, 'integer'::regtype, 'bigint'::regtype,
                    'numeric'::regtype, 'real'::regtype, 'double precision'::regtype
                ) THEN
                    issues := array_append(issues, format('Numeric source metric %I is missing or has an unsupported type', metric));
                END IF;
                FOREACH col IN ARRAY ARRAY['min_', 'max_', 'sum_', 'avg_', 'count_'] LOOP
                    attr_name := col || metric;
                    expected_type := CASE WHEN col IN ('min_', 'max_') THEN source_type
                                          WHEN col = 'count_' THEN 'bigint'::regtype
                                          ELSE 'numeric'::regtype END;
                    expected_modifier := CASE WHEN col IN ('min_', 'max_') THEN source_modifier ELSE -1 END;
                    SELECT a.atttypid, a.atttypmod INTO actual_type, actual_modifier FROM pg_attribute a
                    WHERE a.attrelid = target_oid AND a.attname = attr_name
                      AND a.attnum > 0 AND NOT a.attisdropped;
                    IF actual_type IS NULL OR actual_type IS DISTINCT FROM expected_type
                       OR actual_modifier IS DISTINCT FROM expected_modifier THEN
                        issues := array_append(issues, format('Target metric column %I is missing or has an incompatible type', attr_name));
                    END IF;
                    IF cfg.source_rollup_id IS NOT NULL THEN
                        SELECT a.atttypid, a.atttypmod INTO actual_type, actual_modifier FROM pg_attribute a
                        WHERE a.attrelid = source_oid AND a.attname = attr_name
                          AND a.attnum > 0 AND NOT a.attisdropped;
                        IF actual_type IS NULL OR actual_type IS DISTINCT FROM expected_type
                           OR actual_modifier IS DISTINCT FROM expected_modifier THEN
                            issues := array_append(issues, format('Parent metric state %I is missing or has an incompatible type', attr_name));
                        END IF;
                    END IF;
                END LOOP;
            END LOOP;
            IF NOT EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = target_oid
                AND a.attname = 'rollup_count' AND a.atttypid = 'bigint'::regtype AND NOT a.attisdropped) THEN
                issues := array_append(issues, 'Target requires bigint rollup_count');
            END IF;
            IF NOT EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = target_oid
                AND a.attname = 'last_updated_at' AND a.atttypid = 'timestamptz'::regtype AND NOT a.attisdropped) THEN
                issues := array_append(issues, 'Target requires timestamptz last_updated_at');
            END IF;
            IF cfg.source_rollup_id IS NOT NULL THEN
                SELECT rc.* INTO parent_cfg FROM silver.timeseries_rollup_config rc WHERE rc.id = cfg.source_rollup_id;
                IF NOT FOUND OR parent_cfg.target_table <> cfg.source_table OR parent_cfg.engine_version <> 2 THEN
                    issues := array_append(issues, 'source_rollup_id must identify the version 2 configuration producing the source table');
                ELSIF parent_cfg.dimension_columns IS DISTINCT FROM cfg.dimension_columns
                   OR parent_cfg.metric_columns IS DISTINCT FROM cfg.metric_columns THEN
                    issues := array_append(issues, 'Hierarchy dimensions and metrics must match the parent configuration');
                ELSIF extract(epoch FROM parent_cfg.rollup_table_interval) <= 0
                   OR mod(extract(epoch FROM cfg.rollup_table_interval),
                          extract(epoch FROM parent_cfg.rollup_table_interval)) <> 0
                   OR cfg.rollup_table_interval <= parent_cfg.rollup_table_interval THEN
                    issues := array_append(issues, 'Hierarchy interval must be a larger integer multiple of the parent interval');
                END IF;
            END IF;
        END IF;
        RETURN QUERY SELECT cfg.source_table, cfg.target_table, cardinality(issues) = 0,
            CASE WHEN cardinality(issues) = 0 THEN 'Configuration is valid'
                 ELSE array_to_string(issues, '; ') END;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION silver.validate_rollup_config()
RETURNS TABLE (source_table TEXT, target_table TEXT, is_valid BOOLEAN, validation_message TEXT)
LANGUAGE SQL SET search_path = pg_catalog, silver AS $$
    SELECT v.source_table, v.target_table, v.is_valid, v.validation_message
    FROM silver._validate_rollup_config(NULL) v;
$$;

COMMENT ON FUNCTION silver._validate_rollup_config(TEXT) IS
'Internal structural validation. A target limits catalog checks to that configuration, including inactive targets used for manual refresh. NULL validates all active configurations.';

CREATE OR REPLACE FUNCTION silver.maintain_timeseries_tables(target_table_name TEXT DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SET timezone = 'UTC' AS $$
DECLARE
    cfg record;
    relation_oid regclass;
    relation_name text;
    extension_schema text;
    registered boolean;
BEGIN
    SELECT n.nspname INTO extension_schema FROM pg_extension e
    JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'pg_partman';
    FOR cfg IN SELECT rc.* FROM silver.timeseries_rollup_config rc
        WHERE rc.is_active AND (target_table_name IS NULL OR rc.target_table = target_table_name)
        ORDER BY rc.id
    LOOP
        IF NOT pg_try_advisory_xact_lock(hashtext('silver.timeseries.maintenance'), cfg.id) THEN CONTINUE; END IF;
        relation_oid := to_regclass(cfg.target_table);
        IF relation_oid IS NULL THEN
            RAISE EXCEPTION 'Rollup target % does not exist', cfg.target_table USING ERRCODE = '42P01';
        END IF;
        SELECT format('%I.%I', n.nspname, c.relname) INTO relation_name
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.oid = relation_oid;
        IF extension_schema IS NOT NULL THEN
            EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.part_config WHERE parent_table = $1)', extension_schema)
                INTO registered USING relation_name;
            IF registered THEN
                EXECUTE format('SELECT %I.run_maintenance(p_parent_table := $1)', extension_schema) USING relation_name;
            END IF;
        END IF;
        EXECUTE format('ANALYZE %s', relation_name);
        UPDATE silver.timeseries_rollup_config rc SET last_optimization_time = clock_timestamp() WHERE rc.id = cfg.id;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION silver.maintain_timeseries_tables(TEXT) IS
'Analyze active rollup targets and maintain registered pg_partman sets using their existing partition/retention policies. Does not rewrite partition intervals or log maintenance as a successful rollup. Without pg_partman, native partition maintenance remains the operator responsibility. Invoke VACUUM separately outside a transaction.';

CREATE OR REPLACE VIEW silver.timeseries_operations_monitor AS
WITH successful_runs AS (
    SELECT rl.table_name, count(*) AS successes, avg(rl.duration) AS avg_duration
    FROM silver.timeseries_refresh_log rl
    WHERE rl.refresh_timestamp > CURRENT_TIMESTAMP - INTERVAL '24 hours'
    GROUP BY rl.table_name
), failures AS (
    SELECT el.source_table, el.target_table, count(*) AS errors
    FROM silver.timeseries_error_log el
    WHERE el.error_timestamp > CURRENT_TIMESTAMP - INTERVAL '24 hours'
    GROUP BY el.source_table, el.target_table
), latest_errors AS (
    SELECT DISTINCT ON (el.source_table, el.target_table)
        el.source_table, el.target_table, el.error_message
    FROM silver.timeseries_error_log el
    ORDER BY el.source_table, el.target_table, el.error_timestamp DESC, el.id DESC
)
SELECT rc.id, rc.source_table, rc.target_table, rc.status, rc.started_at,
       rc.last_processed_time, rc.last_processed_rows, rc.retry_count,
       rc.last_error_time, rc.next_retry_time,
       CASE WHEN NOT rc.is_active THEN 'INACTIVE'
            WHEN rc.engine_version <> 2 THEN 'UPGRADE REQUIRED'
            WHEN rc.status = 'processing' AND rc.started_at < CURRENT_TIMESTAMP - rc.alert_threshold THEN 'ALERT'
            WHEN rc.retry_count >= rc.max_retries AND rc.retry_count > 0 THEN 'ALERT'
            WHEN rc.retry_count > 0 THEN 'WARNING'
            WHEN rc.status = 'processing' THEN 'RUNNING'
            ELSE 'OK' END AS health_status,
       le.error_message AS latest_error, sr.avg_duration,
       (100.0 * COALESCE(sr.successes, 0)::double precision /
           NULLIF(COALESCE(sr.successes, 0) + COALESCE(f.errors, 0), 0))::double precision AS success_rate,
       rc.is_active, rc.engine_version,
       CASE WHEN rc.last_processed_time IS NOT NULL
            THEN greatest(INTERVAL '0', CURRENT_TIMESTAMP - rc.last_processed_time) END AS processing_lag,
       COALESCE(sr.successes, 0)::bigint AS recent_successes,
       COALESCE(f.errors, 0)::bigint AS recent_errors,
       (COALESCE(sr.successes, 0) + COALESCE(f.errors, 0))::bigint AS recent_attempts
FROM silver.timeseries_rollup_config rc
LEFT JOIN successful_runs sr ON sr.table_name = rc.target_table
LEFT JOIN failures f ON f.source_table = rc.source_table AND f.target_table = rc.target_table
LEFT JOIN latest_errors le ON le.source_table = rc.source_table AND le.target_table = rc.target_table;

COMMENT ON VIEW silver.timeseries_operations_monitor IS
'Committed rollup state, latest error, and 24-hour logged outcomes. success_rate counts all successful refresh entries (including zero-row runs) against successful entries plus error entries. Legacy diagnostic errors may not correspond one-to-one with execution attempts. Uncommitted in-flight worker state is not visible in this view; inspect pg_stat_activity for live transactions. processing_lag is wall time since the committed watermark.';

CREATE INDEX IF NOT EXISTS idx_timeseries_refresh_log_target_time
    ON silver.timeseries_refresh_log (table_name, refresh_timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_timeseries_error_log_target_time
    ON silver.timeseries_error_log (source_table, target_table, error_timestamp DESC, id DESC);

GRANT EXECUTE ON FUNCTION silver.get_detailed_stats(TEXT) TO db_ecs_user;
GRANT EXECUTE ON FUNCTION silver.get_partition_stats(TEXT) TO db_ecs_user;
GRANT EXECUTE ON FUNCTION silver.optimize_chunk_interval(TEXT, BIGINT) TO db_ecs_user;
GRANT EXECUTE ON FUNCTION silver._validate_rollup_config(TEXT) TO db_ecs_user;
GRANT EXECUTE ON FUNCTION silver.validate_rollup_config() TO db_ecs_user;
GRANT EXECUTE ON FUNCTION silver.maintain_timeseries_tables(TEXT) TO db_ecs_user;
GRANT SELECT ON silver.timeseries_operations_monitor TO db_ecs_user;

COMMENT ON FUNCTION silver.first_value(ANYELEMENT, TIMESTAMPTZ) IS
'Legacy scalar compatibility helper: returns its single input value. This is not an aggregate and is not used by the rollup engine.';
COMMENT ON FUNCTION silver.last_value(ANYELEMENT, TIMESTAMPTZ) IS
'Legacy scalar compatibility helper: returns its single input value. This is not an aggregate and is not used by the rollup engine.';
