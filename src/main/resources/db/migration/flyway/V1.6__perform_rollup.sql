-- Create the consolidated perform_rollup function
CREATE OR REPLACE FUNCTION silver.perform_rollup(
    specific_table TEXT DEFAULT NULL
) RETURNS VOID AS $$
    DECLARE
        config_record RECORD;
        cutoff_time TIMESTAMPTZ;
        start_time TIMESTAMPTZ;
        end_time TIMESTAMPTZ;
        rows_processed INTEGER;
        sql_template TEXT;
        column_list TEXT := '';
        source_schema TEXT;
        source_table TEXT;
        target_schema TEXT;
        target_table TEXT;
        col_info RECORD;
        non_numeric_col_info RECORD;
        group_by_clause TEXT;
        dimension_columns TEXT[] := '{}';
        dimension_col_exists BOOLEAN;
        dimension_col TEXT;
        target_columns TEXT[];
        select_list TEXT[];
        processed_columns TEXT[];
        error_occurred BOOLEAN;
        debug_msg TEXT;
        update_columns TEXT[];
        update_clause TEXT;
        current_rollup_age INTERVAL;
        processing_delay INTERVAL;
        batch_start_time TIMESTAMPTZ;
        optimal_window INTERVAL;
        current_load INTEGER;
        rows_updated INTEGER;
        current_ts TIMESTAMPTZ;
        execution_start_time TIMESTAMPTZ;
    BEGIN
        execution_start_time := clock_timestamp();
        RAISE NOTICE 'Starting rollup process at % with specific_table=%', execution_start_time, specific_table;
        
        current_ts := clock_timestamp();
        
        FOR config_record IN 
            SELECT * FROM silver.timeseries_rollup_config rc
            WHERE rc.is_active = TRUE
                AND (specific_table IS NULL OR rc.source_table = specific_table)
                AND (rc.status = 'idle' 
                     OR (rc.status = 'processing' 
                         AND rc.started_at < current_ts - rc.alert_threshold))
            ORDER BY rc.last_processed_time NULLS FIRST
        LOOP
            RAISE NOTICE 'Processing configuration: id=%, source=%, target=%, interval=%', 
                config_record.id, config_record.source_table, config_record.target_table, config_record.rollup_table_interval;
            
            error_occurred := FALSE;
            batch_start_time := clock_timestamp();
            
            BEGIN
                -- Check max execution time
                IF config_record.started_at IS NOT NULL AND 
                   config_record.started_at < current_ts - config_record.max_execution_time THEN
                    RAISE EXCEPTION 'Task exceeded maximum execution time of %', config_record.max_execution_time;
                END IF;

                -- Try to acquire this task with optimistic locking
                UPDATE silver.timeseries_rollup_config trc
                SET status = 'processing',
                    worker_id = pg_backend_pid()::text,
                    started_at = current_ts
                WHERE trc.id = config_record.id
                    AND (trc.status = 'idle' 
                         OR (trc.status = 'processing' 
                             AND trc.started_at < current_ts - config_record.alert_threshold))
                RETURNING * INTO config_record;
                
                IF NOT FOUND THEN
                    RAISE NOTICE 'Task % already being processed by another worker, skipping', config_record.id;
                    CONTINUE;
                END IF;

                -- Calculate processing range with adaptive window
                IF config_record.last_processed_time IS NULL THEN
                    -- First run: Start from look_back_window but process in chunks
                    start_time := current_ts - config_record.look_back_window;
                    
                    -- For first run, use a smaller window to avoid overwhelming the system
                    optimal_window := LEAST(
                        config_record.processing_window,
                        INTERVAL '1 hour'
                    );
                ELSE
                    start_time := config_record.last_processed_time;
                    optimal_window := config_record.processing_window;
                    
                    -- Adjust window based on system load
                    SELECT COUNT(*) INTO current_load 
                    FROM pg_stat_activity 
                    WHERE state = 'active'
                    AND pid != pg_backend_pid()
                    AND query NOT LIKE '%pg_stat_activity%';
                    
                    IF current_load > 5 THEN  -- High load
                        optimal_window := optimal_window * 0.5;
                    ELSIF current_load < 2 THEN  -- Low load
                        optimal_window := LEAST(
                            optimal_window * 1.5,
                            config_record.max_look_back_window
                        );
                    END IF;
                END IF;

                -- Calculate end time with safety buffer
                end_time := LEAST(
                    current_ts - CASE 
                        WHEN config_record.rollup_table_interval <= INTERVAL '1 second' THEN 
                            INTERVAL '30 seconds'  -- For 1s rollups (reduced from 2 minutes)
                        WHEN config_record.rollup_table_interval = INTERVAL '1 minute' THEN
                            INTERVAL '1 minute'    -- For 1m rollups (reduced from 3 minutes)
                        ELSE 
                            config_record.rollup_table_interval  -- For larger intervals (reduced from 2x)
                        END,
                    start_time + optimal_window
                );

                -- Skip if no data to process
                IF start_time >= end_time THEN
                    UPDATE silver.timeseries_rollup_config
                    SET status = 'idle',
                        worker_id = NULL,
                        started_at = NULL
                    WHERE id = config_record.id
                    AND worker_id = pg_backend_pid()::text;
                    CONTINUE;
                END IF;

                -- Initialize for this iteration
                source_schema := split_part(config_record.source_table, '.', 1);
                source_table := split_part(config_record.source_table, '.', 2);
                target_schema := split_part(config_record.target_table, '.', 1);
                target_table := split_part(config_record.target_table, '.', 2);
                
                target_columns := ARRAY[]::TEXT[];
                select_list := ARRAY[]::TEXT[];
                processed_columns := ARRAY['timestamp', 'last_updated_at', 'rollup_count']::TEXT[];
                
                -- Add timestamp
                target_columns := array_append(target_columns, 'timestamp');
                select_list := array_append(select_list, 
                    format('silver.time_bucket(%L, timestamp)', config_record.rollup_table_interval));
                
                -- Process dimension columns
                FOR dimension_col IN 
                    SELECT tdc.dimension_column as dimension_col
                    FROM silver.timeseries_dimension_config tdc
                    WHERE tdc.source_table = config_record.source_table
                      AND tdc.is_active = TRUE
                LOOP
                    BEGIN
                        EXECUTE format('
                            SELECT EXISTS (
                                SELECT 1 
                                FROM information_schema.columns 
                                WHERE table_schema = %L 
                                    AND table_name = %L 
                                    AND column_name = %L
                            )',
                            source_schema,
                            source_table,
                            dimension_col
                        ) INTO dimension_col_exists;
                        
                        IF dimension_col_exists THEN
                            dimension_columns := array_append(dimension_columns, dimension_col);
                            target_columns := array_append(target_columns, dimension_col);
                            select_list := array_append(select_list, quote_ident(dimension_col));
                            processed_columns := array_append(processed_columns, dimension_col);
                        END IF;
                    EXCEPTION WHEN OTHERS THEN
                        INSERT INTO silver.timeseries_error_log (
                            source_table, 
                            target_table, 
                            error_message, 
                            sql_state,
                            error_detail, 
                            error_hint, 
                            error_context
                        ) VALUES (
                            config_record.source_table,
                            config_record.target_table,
                            format('Error checking dimension column %s: %s', dimension_col, SQLERRM),
                            SQLSTATE,
                            COALESCE(SQLERRM, 'No detail'),
                            'Check if the column exists and is accessible',
                            'During dimension column processing'
                        );
                        error_occurred := TRUE;
                        CONTINUE;
                    END;
                END LOOP;
                
                -- Build GROUP BY clause
                IF array_length(dimension_columns, 1) > 0 THEN
                    SELECT string_agg(quote_ident(col), ', ') INTO group_by_clause
                    FROM unnest(dimension_columns) AS col;
                    group_by_clause := format('silver.time_bucket(%L, timestamp), %s',
                        config_record.rollup_table_interval,
                        group_by_clause);
                ELSE
                    group_by_clause := format('silver.time_bucket(%L, timestamp)',
                        config_record.rollup_table_interval);
                END IF;

                -- Process numeric columns
                FOR col_info IN 
                    SELECT 
                        s.column_name, 
                        s.data_type 
                    FROM information_schema.columns s
                    WHERE s.table_schema = source_schema
                        AND s.table_name = source_table
                        AND s.column_name NOT IN ('timestamp', 'last_updated_at', 'rollup_count')
                        AND s.column_name != ANY(dimension_columns)
                        AND s.data_type IN ('integer', 'numeric', 'real', 'double precision')
                        AND s.column_name NOT LIKE 'min_%'
                        AND s.column_name NOT LIKE 'max_%'
                        AND s.column_name NOT LIKE 'avg_%'
                    ORDER BY s.ordinal_position
                LOOP
                    BEGIN
                        IF EXISTS (
                            SELECT 1 
                            FROM information_schema.columns 
                            WHERE table_schema = target_schema
                            AND table_name = target_table
                            AND column_name IN (
                                'min_' || col_info.column_name,
                                'max_' || col_info.column_name,
                                'avg_' || col_info.column_name
                            )
                        ) THEN
                            target_columns := array_append(target_columns, 'min_' || col_info.column_name);
                            select_list := array_append(select_list, 
                                format('MIN(%I)', col_info.column_name));
                            
                            target_columns := array_append(target_columns, 'max_' || col_info.column_name);
                            select_list := array_append(select_list, 
                                format('MAX(%I)', col_info.column_name));
                            
                            target_columns := array_append(target_columns, 'avg_' || col_info.column_name);
                            select_list := array_append(select_list, 
                                format('AVG(%I)', col_info.column_name));
                            
                            processed_columns := array_append(processed_columns, col_info.column_name);
                        END IF;
                    EXCEPTION WHEN OTHERS THEN
                        INSERT INTO silver.timeseries_error_log (
                            source_table, 
                            target_table, 
                            error_message, 
                            sql_state,
                            error_detail, 
                            error_hint, 
                            error_context
                        ) VALUES (
                            config_record.source_table,
                            config_record.target_table,
                            format('Error processing numeric column %s: %s', col_info.column_name, SQLERRM),
                            SQLSTATE,
                            COALESCE(SQLERRM, 'No detail'),
                            'Check if statistical columns exist and are accessible',
                            'During numeric column processing'
                        );
                        error_occurred := TRUE;
                        CONTINUE;
                    END;
                END LOOP;

                -- Process non-numeric columns
                FOR non_numeric_col_info IN 
                    SELECT 
                        s.column_name, 
                        s.data_type 
                    FROM information_schema.columns s
                    WHERE s.table_schema = source_schema
                        AND s.table_name = source_table
                        AND s.column_name NOT IN ('timestamp', 'last_updated_at', 'rollup_count')
                        AND s.column_name != ALL(processed_columns)
                        AND s.data_type NOT IN ('integer', 'numeric', 'real', 'double precision')
                    ORDER BY s.ordinal_position
                LOOP
                    BEGIN
                        IF EXISTS (
                            SELECT 1 
                            FROM information_schema.columns 
                            WHERE table_schema = target_schema
                            AND table_name = target_table
                            AND column_name = non_numeric_col_info.column_name
                        ) THEN
                            target_columns := array_append(target_columns, non_numeric_col_info.column_name);
                            IF non_numeric_col_info.data_type = 'jsonb' THEN
                                select_list := array_append(select_list, 
                                    format('array_agg(%I)', non_numeric_col_info.column_name));
                            ELSE
                                select_list := array_append(select_list, 
                                    format('MODE() WITHIN GROUP (ORDER BY %I)', non_numeric_col_info.column_name));
                            END IF;
                        END IF;
                    EXCEPTION WHEN OTHERS THEN
                        INSERT INTO silver.timeseries_error_log (
                            source_table, 
                            target_table, 
                            error_message, 
                            sql_state,
                            error_detail, 
                            error_hint, 
                            error_context
                        ) VALUES (
                            config_record.source_table,
                            config_record.target_table,
                            format('Error processing non-numeric column %s: %s', non_numeric_col_info.column_name, SQLERRM),
                            SQLSTATE,
                            COALESCE(SQLERRM, 'No detail'),
                            'Check if column exists and is accessible',
                            'During non-numeric column processing'
                        );
                        error_occurred := TRUE;
                        CONTINUE;
                    END;
                END LOOP;

                -- Add system columns
                target_columns := array_append(target_columns, 'rollup_count');
                select_list := array_append(select_list, 'COUNT(*)');
                target_columns := array_append(target_columns, 'last_updated_at');
                select_list := array_append(select_list, 'NOW()');

                -- Create update clause for ON CONFLICT DO UPDATE
                update_columns := ARRAY[]::TEXT[];
                FOR col_info IN 
                    SELECT column_name 
                    FROM unnest(target_columns) AS column_name
                    WHERE column_name NOT IN ('timestamp') 
                      AND column_name != ANY(dimension_columns)
                LOOP
                    update_columns := array_append(update_columns, 
                        format('%I = EXCLUDED.%I', col_info.column_name, col_info.column_name));
                END LOOP;
                
                IF array_length(update_columns, 1) > 0 THEN
                    update_clause := 'DO UPDATE SET ' || array_to_string(update_columns, ', ');
                ELSE
                    update_clause := 'DO NOTHING';
                END IF;

                -- Execute rollup with ON CONFLICT handling
                sql_template := format('
                    INSERT INTO %I.%I (%s)
                    SELECT %s
                    FROM %I.%I
                    WHERE timestamp >= %L AND timestamp < %L
                    GROUP BY %s
                    ON CONFLICT (timestamp%s) %s
                    RETURNING 1',
                    target_schema, target_table,
                    array_to_string(target_columns, ', '),
                    array_to_string(select_list, ', '),
                    source_schema, source_table,
                    start_time,
                    end_time,
                    group_by_clause,
                    CASE WHEN array_length(dimension_columns, 1) > 0 
                         THEN ', ' || array_to_string(dimension_columns, ', ')
                         ELSE '' END,
                    update_clause
                );

                EXECUTE sql_template INTO rows_processed;

                -- Ensure rows_processed is not null
                IF rows_processed IS NULL THEN
                    rows_processed := 0;
                END IF;

                IF NOT error_occurred THEN
                    -- Log success
                    PERFORM silver.log_rollup_success(
                        config_record.target_table,
                        batch_start_time,
                        clock_timestamp(),
                        rows_processed
                    );

                    -- Update progress with optimistic locking
                    UPDATE silver.timeseries_rollup_config
                    SET status = 'idle',
                        last_processed_time = end_time,
                        avg_processing_time = (
                            COALESCE(avg_processing_time, INTERVAL '0') * 0.7 + 
                            (clock_timestamp() - batch_start_time) * 0.3
                        ),
                        last_processed_rows = rows_processed,
                        worker_id = NULL,
                        started_at = NULL,
                        -- Reset retry-related fields on success
                        retry_count = 0,
                        last_error_time = NULL,
                        next_retry_time = NULL,
                        -- Update processing window based on success
                        processing_window = CASE 
                            WHEN rows_processed > 1000000 THEN optimal_window * 0.8  -- Too many rows
                            WHEN rows_processed < 100000 THEN LEAST(optimal_window * 1.2, max_look_back_window)  -- Too few rows
                            ELSE optimal_window
                        END
                    WHERE id = config_record.id
                    AND worker_id = pg_backend_pid()::text;
                    
                    GET DIAGNOSTICS rows_updated = ROW_COUNT;
                    IF rows_updated = 0 THEN
                        RAISE NOTICE 'Concurrent update detected for task %, continuing', config_record.id;
                    ELSE
                        RAISE NOTICE 'Successfully updated progress for task %. New last_processed_time: %', 
                            config_record.id, end_time;
                    END IF;
                END IF;

            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING 'Error executing rollup query for task %: %', config_record.id, SQLERRM;
                
                -- Log error and update retry information
                INSERT INTO silver.timeseries_error_log (
                    source_table, 
                    target_table, 
                    error_message, 
                    sql_state,
                    error_detail, 
                    error_hint, 
                    error_context, 
                    attempted_query
                ) VALUES (
                    config_record.source_table,
                    config_record.target_table,
                    format('Error executing rollup query: %s', SQLERRM),
                    SQLSTATE,
                    COALESCE(SQLERRM, 'No detail'),
                    'Check the query syntax and table permissions',
                    'During main rollup query execution',
                    sql_template
                );
                
                -- Update retry information
                UPDATE silver.timeseries_rollup_config
                SET status = 'idle',
                    worker_id = NULL,
                    started_at = NULL,
                    retry_count = COALESCE(retry_count, 0) + 1,
                    last_error_time = current_ts,
                    next_retry_time = current_ts + (INTERVAL '5 minutes' * POWER(2, COALESCE(retry_count, 0)))
                WHERE id = config_record.id
                AND worker_id = pg_backend_pid()::text;
                
                RAISE NOTICE 'Updated retry information for task % after error', config_record.id;
                
                error_occurred := TRUE;
            END;
            
            -- Check execution time against alert threshold
            IF clock_timestamp() - execution_start_time > config_record.alert_threshold THEN
                RAISE WARNING 'Task % execution time (%) exceeded alert threshold (%)', 
                    config_record.id, 
                    clock_timestamp() - execution_start_time,
                    config_record.alert_threshold;
            END IF;
            
            RAISE NOTICE 'Completed processing for task % in % seconds', 
                config_record.id, 
                EXTRACT(EPOCH FROM (clock_timestamp() - batch_start_time));
        END LOOP;
        
        RAISE NOTICE 'Rollup process completed at %', clock_timestamp();
    END;
$$ LANGUAGE plpgsql;

-- Grant permissions
GRANT EXECUTE ON FUNCTION silver.perform_rollup(TEXT) TO db_ecs_user;

-- Add comments
COMMENT ON FUNCTION silver.perform_rollup(TEXT) IS 
'Performs time-series data aggregation based on configured rollup settings.
Features:
1. Consistent success logging
2. Execution time monitoring
3. Retry mechanism with exponential backoff
4. Alert threshold monitoring
5. Adaptive processing windows
6. System load consideration
7. Comprehensive error handling

Example: 
SELECT silver.perform_rollup();  -- Process all tables
SELECT silver.perform_rollup(''schema.specific_table'');  -- Process specific table'; 