-- Configure timeseries maintenance cron jobs
-- This file demonstrates how to set up automated maintenance for timeseries tables

-- Example: Schedule maintenance for a timeseries table
SELECT cron.schedule(
    'maintain_example_timeseries_table_5m',
    '0 0 * * *',  -- Run daily at midnight
    $$SELECT silver.maintain_timeseries_tables('silver.example_timeseries_table_5m')$$
);

SELECT cron.schedule(
    'maintain_example_timeseries_table_1m',
    '0 0 * * *',  -- Run daily at midnight
    $$SELECT silver.maintain_timeseries_tables('silver.example_timeseries_table_1m')$$
);

-- Example: Update existing cron jobs for a table
UPDATE cron.job 
SET database = 'iotmetrics',
    command = 'SELECT silver.maintain_timeseries_tables(''silver.example_timeseries_table_5m'')'
WHERE jobname = 'maintain_example_timeseries_table_1s';

UPDATE cron.job 
SET database = 'iotmetrics',
    command = 'SELECT silver.maintain_timeseries_tables(''silver.example_timeseries_table_1m'')'
WHERE jobname = 'maintain_example_timeseries_table_1m';

-- Note: Replace 'example_timeseries_table' with your actual table names
-- and adjust the schedule as needed for your use case 
