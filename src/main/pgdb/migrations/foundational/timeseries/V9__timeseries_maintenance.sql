-- V7.3: Time-series maintenance and validation
-- Maintenance functions, validation, and scheduled jobs

-- 1. Smart Partition Management
CREATE OR REPLACE FUNCTION silver.optimize_chunk_interval(
    table_name TEXT,
    target_chunk_size BIGINT DEFAULT 268435456  -- 256MB default
) RETURNS INTERVAL AS $$
    /*
    Calculates optimal chunk interval for time-series partitions.
    
    Steps:
    1. Gets current table statistics (size, row count)
    2. Calculates data ingestion rate
    3. Determines optimal interval based on:
       - Target chunk size (default 256MB)
       - Average row size
       - Data ingestion rate
    4. Rounds to nearest standard interval
    
    Example: optimize_chunk_interval('schema.table', 268435456)
    */
    DECLARE
        current_size BIGINT;
        row_count BIGINT;
        avg_row_size FLOAT;
        optimal_interval INTERVAL;
        sample_interval INTERVAL;
        data_rate FLOAT;
    BEGIN
        -- Get current statistics
        SELECT 
            pg_total_relation_size(relid) as total_size,
            n_live_tup,
            pg_total_relation_size(relid)::float / NULLIF(n_live_tup, 0)
        INTO current_size, row_count, avg_row_size
        FROM pg_stat_user_tables
        WHERE schemaname || '.' || relname = table_name;

        -- Calculate data ingestion rate (rows per hour)
        EXECUTE format('
            SELECT 
                CASE 
                    WHEN extract(epoch from (MAX(timestamp) - MIN(timestamp))) > 0 
                    THEN COUNT(*)::float / extract(epoch from (MAX(timestamp) - MIN(timestamp))) * 3600
                    ELSE 1000 -- default assumption if not enough data
                END
            FROM %I.%I 
            WHERE timestamp >= NOW() - INTERVAL ''1 day''',
            split_part(table_name, '.', 1),
            split_part(table_name, '.', 2)
        ) INTO data_rate;

        -- Calculate optimal interval
        IF row_count > 0 AND avg_row_size > 0 AND data_rate > 0 THEN
            optimal_interval := ((target_chunk_size::float / avg_row_size) / data_rate * '1 hour'::interval)::interval;
            
            -- Round to nearest standard interval
            CASE 
                WHEN optimal_interval < '1 hour'::interval THEN 
                    optimal_interval := '1 hour'::interval;
                WHEN optimal_interval < '1 day'::interval THEN 
                    optimal_interval := (extract(epoch from optimal_interval)::bigint / 3600) * '1 hour'::interval;
                WHEN optimal_interval < '1 week'::interval THEN 
                    optimal_interval := (extract(epoch from optimal_interval)::bigint / 86400) * '1 day'::interval;
                ELSE 
                    optimal_interval := '1 week'::interval;
            END CASE;
        ELSE
            optimal_interval := '1 day'::interval;  -- Default if no data
        END IF;

        RETURN optimal_interval;
    END;
$$ LANGUAGE plpgsql;

-- 2. Partition Statistics
CREATE OR REPLACE FUNCTION silver.get_partition_stats(
    parent_table_name TEXT
) RETURNS TABLE (
    partition_full_name TEXT,
    partition_range TEXT,
    total_size TEXT,
    table_size TEXT,
    index_size TEXT,
    row_count NUMERIC,
    bytes_per_row TEXT
) AS $$
    /*
    Returns detailed statistics for table partitions.
    
    Metrics:
    - Partition name and range
    - Total size (including indexes)
    - Table size
    - Index size
    - Row count
    - Average bytes per row
    
    Example: get_partition_stats('schema.partitioned_table')
    */
    DECLARE
        schema_name TEXT;
        table_name TEXT;
    BEGIN
        schema_name := split_part(parent_table_name, '.', 1);
        table_name := split_part(parent_table_name, '.', 2);
        table_name := table_name || '_%';
        
        RETURN QUERY
            WITH partition_sizes AS (
                SELECT
                    n.nspname AS schema_name,
                    c.relname AS partition_name,
                    pg_total_relation_size(c.oid) AS total_size_bytes,
                    pg_relation_size(c.oid) AS table_size_bytes,
                    pg_indexes_size(c.oid) AS index_size_bytes
                FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE c.relname LIKE table_name
                    AND n.nspname = schema_name
            ),
            partition_ranges AS (
                SELECT
                    n.nspname AS schema_name,
                    c.relname AS partition_name,
                    pg_get_expr(c.relpartbound, c.oid) AS partition_range
                FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE c.relispartition
                    AND n.nspname = schema_name
                    AND c.relname LIKE table_name
            ),
            partition_rows AS (
                SELECT
                    schemaname AS schema_name,
                    relname AS partition_name,
                    n_live_tup AS row_count
                FROM pg_stat_user_tables
                WHERE relname LIKE table_name
                    AND schemaname = schema_name
            )
            SELECT
                ps.schema_name || '.' || ps.partition_name AS partition_full_name,
                pr.partition_range,
                pg_size_pretty(ps.total_size_bytes) AS total_size,
                pg_size_pretty(ps.table_size_bytes) AS table_size,
                pg_size_pretty(ps.index_size_bytes) AS index_size,
                ROUND(COALESCE(pr2.row_count::numeric, 0), 0) AS row_count,
                CASE 
                    WHEN COALESCE(pr2.row_count, 0) > 0 
                    THEN pg_size_pretty(ps.total_size_bytes / NULLIF(pr2.row_count, 0)) 
                    ELSE 'N/A' 
                END AS bytes_per_row
            FROM partition_sizes ps
            LEFT JOIN partition_ranges pr 
                ON ps.schema_name = pr.schema_name 
                AND ps.partition_name = pr.partition_name
            LEFT JOIN partition_rows pr2 
                ON ps.schema_name = pr2.schema_name 
                AND ps.partition_name = pr2.partition_name
            ORDER BY ps.partition_name;
    END;
$$ LANGUAGE plpgsql;

-- 3. Maintenance Function
CREATE OR REPLACE FUNCTION silver.maintain_timeseries_tables(
    target_table_name TEXT DEFAULT NULL
) 
RETURNS void AS $$
    /*
    Performs maintenance operations on time-series tables.
    
    Parameters:
    - target_table_name: Optional. If provided, only maintain the specified table.
                        If NULL, maintain all active tables in the configuration.
    
    Steps:
    1. For each active rollup configuration:
       a. Checks if optimization is needed (daily)
       b. Calculates optimal chunk interval based on:
          - Current table size
          - Row count and size
          - Data ingestion rate
       c. Updates configuration if interval needs changing
       d. Logs maintenance operations
    
    Optimization Criteria:
    - Targets 256MB chunk size by default
    - Considers data ingestion rate
    - Rounds to nearest standard interval
    
    Example: 
    - Called daily by cron job: SELECT silver.maintain_timeseries_tables();
    - For specific table: SELECT silver.maintain_timeseries_tables('silver.ess_signals_1s');
    */
    DECLARE
        config_record RECORD;
        current_interval INTERVAL;
        optimal_interval INTERVAL;
    BEGIN
        -- Process each active rollup configuration
        FOR config_record IN 
            SELECT * FROM silver.timeseries_rollup_config 
            WHERE is_active = TRUE 
                AND (last_optimization_time IS NULL OR 
                     last_optimization_time < NOW() - INTERVAL '1 day')
                AND (target_table_name IS NULL OR target_table = target_table_name)
        LOOP
            -- Check if chunk interval needs optimization
            optimal_interval := silver.optimize_chunk_interval(config_record.target_table);
            
            IF optimal_interval <> config_record.chunk_interval THEN
                -- Update configuration with new interval
                UPDATE silver.timeseries_rollup_config
                SET chunk_interval = optimal_interval,
                    last_optimization_time = NOW()
                WHERE source_table = config_record.source_table
                    AND target_table = config_record.target_table;
                
                -- Log the change
                INSERT INTO silver.timeseries_refresh_log (
                    table_name,
                    start_time,
                    end_time,
                    records_processed,
                    refresh_timestamp
                ) VALUES (
                    config_record.target_table,
                    NOW(),
                    NOW(),
                    0,
                    NOW()
                );
            END IF;
        END LOOP;
    END;
$$ LANGUAGE plpgsql;

-- 4. Configuration Validation
CREATE OR REPLACE FUNCTION silver.validate_rollup_config()
RETURNS TABLE (
    source_table TEXT,
    target_table TEXT,
    is_valid BOOLEAN,
    validation_message TEXT
) AS $$
    DECLARE
        config_record RECORD;
        source_schema TEXT;
        source_table_name TEXT;
        target_schema TEXT;
        target_table_name TEXT;
        target_exists BOOLEAN;
        has_timestamp BOOLEAN;
        dimension_exists BOOLEAN;
        dimension_col TEXT;
        missing_columns TEXT[] := '{}';
    BEGIN
        FOR config_record IN 
            SELECT * FROM silver.timeseries_rollup_config 
            WHERE is_active = TRUE
        LOOP
            source_schema := split_part(config_record.source_table, '.', 1);
            source_table_name := split_part(config_record.source_table, '.', 2);
            target_schema := split_part(config_record.target_table, '.', 1);
            target_table_name := split_part(config_record.target_table, '.', 2);

            -- Check if target table exists
            SELECT EXISTS (
                SELECT 1 
                FROM information_schema.tables 
                WHERE table_schema = target_schema 
                AND table_name = target_table_name
            ) INTO target_exists;

            -- Check if source table has timestamp column
            SELECT EXISTS (
                SELECT 1 
                FROM information_schema.columns 
                WHERE table_schema = source_schema 
                AND table_name = source_table_name 
                AND column_name = 'timestamp'
            ) INTO has_timestamp;

            IF NOT target_exists THEN
                RETURN QUERY SELECT 
                    config_record.source_table,
                    config_record.target_table,
                    FALSE,
                    'Target table does not exist';
                CONTINUE;
            END IF;

            IF NOT has_timestamp THEN
                RETURN QUERY SELECT 
                    config_record.source_table,
                    config_record.target_table,
                    FALSE,
                    'Source table missing required timestamp column';
                CONTINUE;
            END IF;

            -- Validate dimension columns from timeseries_dimension_config
            FOR dimension_col IN 
                SELECT dimension_column
                FROM silver.timeseries_dimension_config
                WHERE source_table = config_record.source_table
                AND is_active = TRUE
            LOOP
                SELECT EXISTS (
                    SELECT 1 
                    FROM information_schema.columns 
                    WHERE table_schema = source_schema 
                    AND table_name = source_table_name 
                    AND column_name = dimension_col
                ) INTO dimension_exists;

                IF dimension_exists THEN
                    SELECT EXISTS (
                        SELECT 1 
                        FROM information_schema.columns 
                        WHERE table_schema = target_schema 
                        AND table_name = target_table_name 
                        AND column_name = dimension_col
                    ) INTO dimension_exists;

                    IF NOT dimension_exists THEN
                        missing_columns := array_append(missing_columns, dimension_col);
                    END IF;
                END IF;
            END LOOP;

            IF array_length(missing_columns, 1) > 0 THEN
                RETURN QUERY SELECT 
                    config_record.source_table,
                    config_record.target_table,
                    FALSE,
                    'Missing dimension columns in target table: ' || array_to_string(missing_columns, ', ');
                CONTINUE;
            END IF;

            -- If we get here, everything is valid
            RETURN QUERY SELECT 
                config_record.source_table,
                config_record.target_table,
                TRUE,
                'Configuration is valid';
        END LOOP;
    END;
$$ LANGUAGE plpgsql;

-- Grant permissions
GRANT EXECUTE ON FUNCTION silver.optimize_chunk_interval(TEXT, BIGINT) TO db_ecs_user;
GRANT EXECUTE ON FUNCTION silver.get_partition_stats(TEXT) TO db_ecs_user;
GRANT EXECUTE ON FUNCTION silver.maintain_timeseries_tables(TEXT) TO db_ecs_user;
GRANT EXECUTE ON FUNCTION silver.validate_rollup_config() TO db_ecs_user;

-- Add usage examples as comments
COMMENT ON FUNCTION silver.get_partition_stats(TEXT) IS
'Returns partition statistics for any partitioned table.
Example: SELECT * FROM silver.get_partition_stats(''schema.table_name'');'; 