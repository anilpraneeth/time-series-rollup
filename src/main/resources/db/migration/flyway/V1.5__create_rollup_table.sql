-- V7.3.1: Time-series function for table management

-- 1. Table Creation Function
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
) RETURNS VOID AS $$
    /*
    Creates a new rollup table for time-series aggregation with appropriate structure.
    
    Parameters:
    - source_table_name: Name of the source table (including schema)
    - target_schema: Schema for the target rollup table
    - target_table_name: Name of the target rollup table
    - rollup_table_interval: Time interval for data aggregation
    - look_back_window: How far behind real-time to start rollup (default: 5 minutes)
    - retention_period: How long to keep rolled up data (default: 30 days)
    - processing_window: Initial window size for processing chunks (default: 1 hour)
    - initial_status: Initial status of the rollup config (default: 'idle')
    - is_active: Whether the rollup should be active immediately (default: true)
    
    Steps:
    1. Identifies dimension columns from source
    2. Builds primary key using timestamp and dimension columns
    3. Generates column definitions:
       - Keeps timestamp and dimension columns as-is
       - Creates min/max/avg variants for numeric columns
       - Preserves non-numeric columns
    4. Creates partitioned table by timestamp range
    5. Sets up optimal chunk interval using pg_partman
    6. Creates appropriate indexes (BRIN for timestamp, btree for lookups)
    7. Registers configuration in timeseries_rollup_config
    8. Sets up permissions
    */
    DECLARE
        column_definitions TEXT;
        partition_range INTERVAL := '1 month';
        dimension_columns TEXT[] := '{}';
        primary_key_columns TEXT;
        dimension_col_exists BOOLEAN;
        dimension_col TEXT;
        col_info RECORD;
    BEGIN
        -- Check dimension columns and build list
        FOR dimension_col IN 
            SELECT dimension_column
            FROM silver.timeseries_dimension_config tdc
            WHERE tdc.source_table = source_table_name
              AND tdc.is_active = TRUE
        LOOP
            EXECUTE format('
                SELECT EXISTS (
                    SELECT 1 
                    FROM information_schema.columns 
                    WHERE table_schema = %L 
                        AND table_name = %L 
                        AND column_name = %L
                )',
                split_part(source_table_name, '.', 1),
                split_part(source_table_name, '.', 2),
                dimension_col
            ) INTO dimension_col_exists;
            
            IF dimension_col_exists THEN
                dimension_columns := array_append(dimension_columns, dimension_col);
            END IF;
        END LOOP;
        
        -- Build primary key
        IF array_length(dimension_columns, 1) > 0 THEN
            SELECT string_agg(quote_ident(col), ', ') INTO primary_key_columns
            FROM unnest(dimension_columns) AS col;
            primary_key_columns := 'timestamp, ' || primary_key_columns;
        ELSE
            primary_key_columns := 'timestamp';
        END IF;
        
        -- Generate column definitions
        WITH source_columns AS (
            SELECT column_name, data_type
            FROM information_schema.columns
            WHERE table_schema = split_part(source_table_name, '.', 1)
                AND table_name = split_part(source_table_name, '.', 2)
                AND column_name NOT IN ('last_updated_at', 'rollup_count')
        ),
        column_list AS (
            SELECT 
                CASE 
                    WHEN column_name = 'timestamp' THEN 
                        column_name || ' ' || data_type || ' NOT NULL'
                    WHEN column_name = ANY(dimension_columns) THEN 
                        column_name || ' ' || data_type || ' NOT NULL'
                    WHEN data_type IN ('integer', 'numeric', 'real', 'double precision') 
                         AND column_name NOT LIKE 'min_%' 
                         AND column_name NOT LIKE 'max_%'
                         AND column_name NOT LIKE 'avg_%'
                         AND column_name NOT IN ('rollup_count') THEN
                        'min_' || column_name || ' ' || data_type || ' NULL, ' ||
                        'max_' || column_name || ' ' || data_type || ' NULL, ' ||
                        'avg_' || column_name || ' ' || data_type || ' NULL'
                    WHEN data_type = 'jsonb' THEN
                        column_name || ' jsonb[] NULL'
                    ELSE
                        column_name || ' ' || data_type || ' NULL'
                END as column_def
            FROM source_columns
        )
        SELECT string_agg(column_def, ', ')
        INTO column_definitions
        FROM column_list;

        -- Create target table
        EXECUTE format('
            CREATE TABLE %I.%I (
                %s,
                rollup_count INTEGER DEFAULT 1,
                last_updated_at TIMESTAMPTZ DEFAULT NOW(),
                PRIMARY KEY (%s)
            ) PARTITION BY RANGE (timestamp)',
            target_schema, target_table_name, column_definitions, primary_key_columns
        );

        -- Set up partitioning
        partition_range := silver.optimize_chunk_interval(source_table_name);

        EXECUTE format('
            SELECT partman.create_parent(
                p_parent_table := %L,
                p_control := ''timestamp'',
                p_interval := %L::text,
                p_premake := 2
            )',
            target_schema || '.' || target_table_name,
            partition_range
        );

        -- Configure retention
        EXECUTE format('
            UPDATE partman.part_config 
            SET retention = %L,
                retention_keep_table = false,
                infinite_time_partitions = true
            WHERE parent_table = %L',
            retention_period,
            target_schema || '.' || target_table_name
        );

        -- Create indexes
        EXECUTE format('
            CREATE INDEX idx_%I_timestamp_brin 
            ON %I.%I USING brin (timestamp) 
            WITH (pages_per_range = 128)',
            target_table_name, target_schema, target_table_name
        );

        IF array_length(dimension_columns, 1) > 0 THEN
            EXECUTE format('
                CREATE INDEX idx_%I_lookup 
                ON %I.%I USING btree (%s, timestamp DESC)',
                target_table_name, target_schema, target_table_name,
                array_to_string(dimension_columns, ', ')
            );
        END IF;

        -- Set high statistics for timestamp column to improve query planning
        EXECUTE format('
            ALTER TABLE %I.%I ALTER COLUMN timestamp SET STATISTICS 1000;
            ANALYZE %I.%I',
            target_schema, target_table_name,
            target_schema, target_table_name
        );

        -- Create GIN indexes for JSONB array columns
        FOR col_info IN 
            SELECT column_name
            FROM information_schema.columns
            WHERE table_schema = target_schema
                AND table_name = target_table_name
                AND data_type = 'jsonb[]'
        LOOP
            EXECUTE format('
                CREATE INDEX idx_%I_%I_gin 
                ON %I.%I USING gin (%I)',
                target_table_name, col_info.column_name,
                target_schema, target_table_name,
                col_info.column_name
            );
        END LOOP;

        -- Register configuration
        INSERT INTO silver.timeseries_rollup_config 
            (source_table, target_table, rollup_table_interval, look_back_window, chunk_interval, 
             retention_period, is_active, status, worker_id, started_at, 
             last_optimization_time, avg_processing_time, last_processed_rows, last_processed_time,
             processing_window)
        VALUES 
            (source_table_name, 
             target_schema || '.' || target_table_name, 
             rollup_table_interval, 
             look_back_window,
             partition_range,
             retention_period,
             is_active,
             initial_status,
             NULL,
             NULL,
             NULL,
             NULL,
             0,
             NULL,
             processing_window);

        -- Grant permissions
        EXECUTE format('
            GRANT SELECT, INSERT, UPDATE, DELETE ON %I.%I TO db_ecs_user',
            target_schema, target_table_name
        );
    END;
$$ LANGUAGE plpgsql;

-- Grant permissions
GRANT EXECUTE ON FUNCTION silver.create_rollup_table(TEXT, TEXT, TEXT, INTERVAL, INTERVAL, INTERVAL, INTERVAL, TEXT, BOOLEAN) TO db_ecs_user;

-- Add usage examples as comments
COMMENT ON FUNCTION silver.create_rollup_table(TEXT, TEXT, TEXT, INTERVAL, INTERVAL, INTERVAL, INTERVAL, TEXT, BOOLEAN) IS
'Creates a new rollup table with appropriate structure for any time-series source table.
Example: 
-- First configure dimension columns
INSERT INTO silver.timeseries_dimension_config (source_table, dimension_column, description)
VALUES 
    (''schema.source_table'', ''company_name'', ''Company identifier''),
    (''schema.source_table'', ''site_name'', ''Site location''),
    (''schema.source_table'', ''device_id'', ''Device identifier'');

-- Then create rollup table with default settings
SELECT silver.create_rollup_table(
    ''schema.source_table'', 
    ''schema'', 
    ''target_table'', 
    ''15 minutes''::interval
);

-- Or with custom settings
SELECT silver.create_rollup_table(
    source_table_name := ''schema.source_table'',
    target_schema := ''schema'',
    target_table_name := ''target_table'',
    rollup_table_interval := ''15 minutes''::interval,
    look_back_window := ''10 minutes''::interval,
    retention_period := ''60 days''::interval,
    processing_window := ''2 hours''::interval,
    initial_status := ''pending'',
    is_active := false
);'; 