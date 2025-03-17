-- V7.2: Time-series table management - Configuration Tables
-- Configuration tables for time-series data management

-- 1. Configuration Tables
CREATE TABLE silver.timeseries_rollup_config (
    id SERIAL PRIMARY KEY,
    source_table TEXT NOT NULL,
    target_table TEXT NOT NULL,
    rollup_table_interval INTERVAL NOT NULL DEFAULT INTERVAL '1 hour',
    look_back_window INTERVAL NOT NULL DEFAULT INTERVAL '1 day',
    max_look_back_window INTERVAL NOT NULL DEFAULT '1 hour'::interval,
    adaptive_mode BOOLEAN DEFAULT true,
    last_aggregation_time TIMESTAMPTZ DEFAULT NULL,
    processing_window INTERVAL DEFAULT INTERVAL '5 minutes',
    status TEXT DEFAULT 'idle',
    worker_id TEXT,
    started_at TIMESTAMPTZ,
    last_processed_time TIMESTAMPTZ,
    avg_processing_time INTERVAL,
    last_processed_rows INTEGER,
    is_active BOOLEAN DEFAULT TRUE,
    chunk_interval INTERVAL DEFAULT INTERVAL '1 day',
    retention_period INTERVAL DEFAULT '30 days'::interval,
    refresh_schedule TEXT DEFAULT '0 * * * *',
    max_parallel_workers INTEGER DEFAULT 1,
    last_optimization_time TIMESTAMPTZ,
    retry_count INTEGER DEFAULT 0,
    last_error_time TIMESTAMPTZ,
    next_retry_time TIMESTAMPTZ,
    max_execution_time INTERVAL DEFAULT INTERVAL '1 hour',
    alert_threshold INTERVAL DEFAULT INTERVAL '30 minutes',
    UNIQUE(source_table, target_table)
);

CREATE TABLE silver.timeseries_dimension_config (
    id SERIAL PRIMARY KEY,
    source_table TEXT NOT NULL,
    dimension_column TEXT NOT NULL,
    description TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(source_table, dimension_column)
);

CREATE TABLE silver.timeseries_refresh_log (
    id BIGSERIAL PRIMARY KEY,
    table_name TEXT NOT NULL,
    start_time TIMESTAMPTZ NOT NULL,
    end_time TIMESTAMPTZ NOT NULL,
    records_processed INTEGER NOT NULL,
    refresh_timestamp TIMESTAMPTZ NOT NULL,
    duration INTERVAL GENERATED ALWAYS AS (end_time - start_time) STORED
);

CREATE TABLE silver.timeseries_error_log (
    id BIGSERIAL PRIMARY KEY,
    source_table TEXT NOT NULL,
    target_table TEXT NOT NULL,
    error_timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    error_message TEXT NOT NULL,
    sql_state TEXT,
    error_detail TEXT,
    error_hint TEXT,
    error_context TEXT,
    attempted_query TEXT
);

-- Create indexes
CREATE INDEX idx_timeseries_refresh_log_timestamp 
    ON silver.timeseries_refresh_log (refresh_timestamp);

CREATE INDEX idx_timeseries_refresh_log_duration 
    ON silver.timeseries_refresh_log (duration DESC);

CREATE INDEX idx_timeseries_error_log_timestamp 
    ON silver.timeseries_error_log (error_timestamp DESC);

-- Add comments
COMMENT ON COLUMN silver.timeseries_refresh_log.duration IS 
'Duration of the rollup operation, automatically calculated as end_time - start_time';

COMMENT ON TABLE silver.timeseries_error_log IS 
'Logs errors that occur during rollup operations, including detailed error information and the attempted query';

COMMENT ON COLUMN silver.timeseries_rollup_config.processing_window IS 
'Size of each incremental chunk to process within the rollup_age window';

COMMENT ON COLUMN silver.timeseries_rollup_config.status IS 
'Current processing status (idle/processing)';

COMMENT ON COLUMN silver.timeseries_rollup_config.worker_id IS 
'ID of the backend process currently processing this config';

COMMENT ON COLUMN silver.timeseries_rollup_config.started_at IS 
'Timestamp when current processing started';

COMMENT ON COLUMN silver.timeseries_rollup_config.last_processed_time IS 
'Timestamp up to which data has been processed';

COMMENT ON COLUMN silver.timeseries_rollup_config.avg_processing_time IS 
'Moving average of processing time per window';

COMMENT ON COLUMN silver.timeseries_rollup_config.last_processed_rows IS 
'Number of rows processed in last window';

-- Grant permissions
GRANT SELECT, INSERT, UPDATE, DELETE ON silver.timeseries_rollup_config TO db_ecs_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON silver.timeseries_refresh_log TO db_ecs_user;
GRANT SELECT, INSERT ON silver.timeseries_error_log TO db_ecs_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON silver.timeseries_dimension_config TO db_ecs_user;

-- Add index for status and worker monitoring
CREATE INDEX idx_timeseries_rollup_config_status 
    ON silver.timeseries_rollup_config (status, started_at)
    WHERE status = 'processing';

-- Add index for retry monitoring
CREATE INDEX idx_timeseries_rollup_retry 
    ON silver.timeseries_rollup_config (next_retry_time)
    WHERE retry_count > 0 AND is_active = TRUE; 