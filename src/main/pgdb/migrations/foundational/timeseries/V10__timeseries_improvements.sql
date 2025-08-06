-- V11: Time-series system improvements
-- Adding monitoring, retry mechanism, and enhanced logging

-- 1. Create monitoring view for operations
CREATE VIEW silver.timeseries_operations_monitor AS
WITH latest_errors AS (
    SELECT 
        source_table,
        target_table,
        error_timestamp,
        error_message,
        ROW_NUMBER() OVER (PARTITION BY source_table, target_table ORDER BY error_timestamp DESC) as rn
    FROM silver.timeseries_error_log
)
SELECT 
    rc.id,
    rc.source_table,
    rc.target_table,
    rc.status,
    rc.started_at,
    rc.last_processed_time,
    rc.last_processed_rows,
    rc.retry_count,
    rc.last_error_time,
    rc.next_retry_time,
    CASE 
        WHEN rc.status = 'processing' AND rc.started_at < NOW() - rc.alert_threshold THEN 'ALERT'
        WHEN rc.retry_count > 3 THEN 'WARNING'
        WHEN rc.status = 'processing' THEN 'RUNNING'
        ELSE 'OK'
    END as health_status,
    le.error_message as latest_error,
    rl.avg_duration,
    rl.success_rate
FROM silver.timeseries_rollup_config rc
LEFT JOIN latest_errors le ON 
    le.source_table = rc.source_table 
    AND le.target_table = rc.target_table 
    AND le.rn = 1
LEFT JOIN (
    SELECT 
        table_name,
        AVG(duration) as avg_duration,
        COUNT(CASE WHEN records_processed > 0 THEN 1 END)::float / 
            NULLIF(COUNT(*), 0) * 100 as success_rate
    FROM silver.timeseries_refresh_log
    WHERE refresh_timestamp > NOW() - INTERVAL '24 hours'
    GROUP BY table_name
) rl ON rl.table_name = rc.target_table;

-- 2. Create function to handle retries
CREATE OR REPLACE FUNCTION silver.handle_rollup_retries() RETURNS void AS $$
DECLARE
    retry_record RECORD;
BEGIN
    FOR retry_record IN 
        SELECT *
        FROM silver.timeseries_rollup_config
        WHERE retry_count > 0 
          AND next_retry_time <= NOW()
          AND is_active = TRUE
    LOOP
        -- Reset status for retry
        UPDATE silver.timeseries_rollup_config
        SET status = 'idle',
            worker_id = NULL,
            started_at = NULL
        WHERE id = retry_record.id;
        
        -- Attempt rollup
        BEGIN
            PERFORM silver.perform_rollup(retry_record.source_table);
            
            -- If successful, reset retry count
            UPDATE silver.timeseries_rollup_config
            SET retry_count = 0,
                last_error_time = NULL,
                next_retry_time = NULL
            WHERE id = retry_record.id;
        EXCEPTION WHEN OTHERS THEN
            -- Increment retry count and set next retry with exponential backoff
            UPDATE silver.timeseries_rollup_config
            SET retry_count = retry_count + 1,
                last_error_time = NOW(),
                next_retry_time = NOW() + (INTERVAL '5 minutes' * POWER(2, retry_count))
            WHERE id = retry_record.id;
            
            -- Log the retry attempt
            INSERT INTO silver.timeseries_error_log (
                source_table,
                target_table,
                error_message,
                sql_state,
                error_detail,
                error_context
            ) VALUES (
                retry_record.source_table,
                retry_record.target_table,
                'Retry attempt failed: ' || SQLERRM,
                SQLSTATE,
                'Retry count: ' || (retry_record.retry_count + 1)::text,
                'During retry processing'
            );
        END;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- 3. Modify perform_rollup to include consistent refresh logging
CREATE OR REPLACE FUNCTION silver.log_rollup_success(
    p_table_name TEXT,
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ,
    p_records_processed INTEGER
) RETURNS void AS $$
BEGIN
    INSERT INTO silver.timeseries_refresh_log (
        table_name,
        start_time,
        end_time,
        records_processed,
        refresh_timestamp
    ) VALUES (
        p_table_name,
        p_start_time,
        p_end_time,
        p_records_processed,
        NOW()
    );
END;
$$ LANGUAGE plpgsql;

-- Grant permissions
GRANT SELECT ON silver.timeseries_operations_monitor TO db_ecs_user;
GRANT EXECUTE ON FUNCTION silver.handle_rollup_retries() TO db_ecs_user;
GRANT EXECUTE ON FUNCTION silver.log_rollup_success(TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INTEGER) TO db_ecs_user;


-- Add comments
COMMENT ON VIEW silver.timeseries_operations_monitor IS 
'Provides a comprehensive view of timeseries operations including health status, errors, and performance metrics';

COMMENT ON FUNCTION silver.handle_rollup_retries() IS
'Processes failed rollups with exponential backoff retry mechanism';

COMMENT ON FUNCTION silver.log_rollup_success(TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INTEGER) IS
'Helper function to consistently log successful rollup operations'; 