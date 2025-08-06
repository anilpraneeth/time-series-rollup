-- V7.1: Core time-series functionality for Aurora PostgreSQL
-- Basic time-series functions and performance monitoring

-- 1. Time Bucket and Value Functions
CREATE OR REPLACE FUNCTION silver.time_bucket(
    bucket_width INTERVAL,
    ts TIMESTAMPTZ
) RETURNS TIMESTAMPTZ AS $$
    /*
    Buckets timestamps into fixed-width intervals for time-series aggregation.
    
    Steps:
    1. Takes a bucket width (interval) and timestamp as input
    2. For common intervals (second, minute, hour, day, week, month), uses date_trunc
    3. For custom intervals, calculates epoch and truncates accordingly
    4. Returns the start of the bucket containing the input timestamp
    
    Example: time_bucket('1 hour', '2024-03-15 14:30:00') returns '2024-03-15 14:00:00'
    */
    DECLARE
        epoch_seconds BIGINT;
        bucket_seconds BIGINT;
    BEGIN
        -- Handle common intervals using date_trunc
        CASE 
            WHEN bucket_width = INTERVAL '1 second' THEN RETURN date_trunc('second', ts);
            WHEN bucket_width = INTERVAL '1 minute' THEN RETURN date_trunc('minute', ts);
            WHEN bucket_width = INTERVAL '1 hour' THEN RETURN date_trunc('hour', ts);
            WHEN bucket_width = INTERVAL '1 day' THEN RETURN date_trunc('day', ts);
            WHEN bucket_width = INTERVAL '1 week' THEN RETURN date_trunc('week', ts);
            WHEN bucket_width = INTERVAL '1 month' THEN RETURN date_trunc('month', ts);
            ELSE
                -- For custom intervals, use epoch calculations
                epoch_seconds := EXTRACT(epoch FROM ts)::BIGINT;
                bucket_seconds := EXTRACT(epoch FROM bucket_width)::BIGINT;
                RETURN to_timestamp((epoch_seconds / bucket_seconds) * bucket_seconds);
        END CASE;
    END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION silver.first_value(
    value_column ANYELEMENT, 
    time_column TIMESTAMPTZ
) RETURNS ANYELEMENT AS $$
    /*
    Returns the first value in a time-ordered sequence.
    
    Steps:
    1. Takes a value and its associated timestamp
    2. Orders values by timestamp ascending
    3. Returns the first value in the sequence
    
    Example: first_value(temperature, timestamp) returns earliest temperature reading
    */
    WITH input_data AS (
        SELECT $1 AS value_column, $2 AS time_column
    )
    SELECT value_column
    FROM (
        SELECT 
            value_column, 
            time_column,
            ROW_NUMBER() OVER (ORDER BY time_column ASC) AS rn
        FROM input_data
    ) ranked 
    WHERE rn = 1;
$$ LANGUAGE SQL IMMUTABLE;

CREATE OR REPLACE FUNCTION silver.last_value(
    value_column ANYELEMENT, 
    time_column TIMESTAMPTZ
) RETURNS ANYELEMENT AS $$
    /*
    Returns the last value in a time-ordered sequence.
    
    Steps:
    1. Takes a value and its associated timestamp
    2. Orders values by timestamp descending
    3. Returns the first value in the sequence (last chronologically)
    
    Example: last_value(temperature, timestamp) returns latest temperature reading
    */
    WITH input_data AS (
        SELECT $1 AS value_column, $2 AS time_column
    )
    SELECT value_column
    FROM (
        SELECT 
            value_column, 
            time_column,
            ROW_NUMBER() OVER (ORDER BY time_column DESC) AS rn
        FROM input_data
    ) ranked 
    WHERE rn = 1;
$$ LANGUAGE SQL IMMUTABLE;

-- 2. Enhanced Performance Monitoring
CREATE OR REPLACE FUNCTION silver.get_detailed_stats(
    table_pattern TEXT
) RETURNS TABLE (
    table_name TEXT,
    total_size BIGINT,
    index_size BIGINT,
    live_rows BIGINT,
    dead_rows BIGINT,
    last_vacuum TIMESTAMPTZ,
    last_analyze TIMESTAMPTZ,
    avg_query_time FLOAT,
    cache_hit_ratio FLOAT,
    bloat_ratio FLOAT,
    write_rate BIGINT,
    read_rate BIGINT
) AS $$
    /*
    Returns detailed performance statistics for tables matching a pattern.
    
    Metrics:
    - Table and index sizes
    - Row counts (live and dead)
    - Maintenance timestamps
    - Cache performance
    - I/O rates
    
    Example: get_detailed_stats('%_timeseries') for all timeseries tables
    */
    BEGIN
        RETURN QUERY
            WITH table_stats AS (
                SELECT 
                    schemaname || '.' || relname as full_name,
                    pg_total_relation_size(relid) as total_size,
                    pg_indexes_size(relid) as index_size,
                    n_live_tup,
                    n_dead_tup,
                    last_vacuum,
                    last_analyze,
                    n_tup_ins + n_tup_upd + n_tup_del as writes,
                    seq_scan + idx_scan as reads
                FROM pg_stat_user_tables
                WHERE relname LIKE table_pattern
            ),
            io_stats AS (
                SELECT 
                    schemaname || '.' || relname as full_name,
                    CASE 
                        WHEN blks_hit + blks_read > 0 
                        THEN blks_hit::float / (blks_hit + blks_read) 
                        ELSE 0 
                    END as cache_ratio
                FROM pg_statio_user_tables
                WHERE relname LIKE table_pattern
            )
            SELECT 
                ts.full_name,
                ts.total_size,
                ts.index_size,
                ts.n_live_tup,
                ts.n_dead_tup,
                ts.last_vacuum,
                ts.last_analyze,
                0.0::float as avg_query_time,  -- Would need custom logging for this
                io.cache_ratio,
                CASE 
                    WHEN ts.n_live_tup > 0 
                    THEN (ts.n_dead_tup::float / ts.n_live_tup)
                    ELSE 0 
                END as bloat_ratio,
                ts.writes,
                ts.reads
            FROM table_stats ts
            LEFT JOIN io_stats io ON ts.full_name = io.full_name;
    END;
$$ LANGUAGE plpgsql;

-- Grant permissions for core functions
GRANT EXECUTE ON FUNCTION silver.time_bucket(INTERVAL, TIMESTAMPTZ) TO db_ecs_user;
GRANT EXECUTE ON FUNCTION silver.first_value(ANYELEMENT, TIMESTAMPTZ) TO db_ecs_user;
GRANT EXECUTE ON FUNCTION silver.last_value(ANYELEMENT, TIMESTAMPTZ) TO db_ecs_user;
GRANT EXECUTE ON FUNCTION silver.get_detailed_stats(TEXT) TO db_ecs_user;

-- Add usage examples as comments
COMMENT ON FUNCTION silver.time_bucket(INTERVAL, TIMESTAMPTZ) IS 
'Optimized time bucket function for efficient time-series aggregation.
Example: SELECT silver.time_bucket(''1 hour''::interval, timestamp_column) FROM table;';

COMMENT ON FUNCTION silver.get_detailed_stats(TEXT) IS 
'Returns detailed performance statistics for tables matching the pattern.
Example: SELECT * FROM silver.get_detailed_stats(''%_timeseries'');'; 