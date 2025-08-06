-- Template variable: table_name

SELECT cron.schedule(
    'maintain_{table_name}_5m',
    '0 0 * * *',  -- Run daily at midnight
    $$SELECT silver.maintain_timeseries_tables('silver.{table_name}_5m')$$
);

SELECT cron.schedule(
    'maintain_{table_name}_1m',
    '0 0 * * *',  -- Run daily at midnight
    $$SELECT silver.maintain_timeseries_tables('silver.{table_name}_1m')$$
);

-- Update existing cron jobs for table

UPDATE cron.job 
SET database = 'iotmetrics',
    command = 'SELECT silver.maintain_timeseries_tables(''silver.{table_name}_5m'')'
WHERE jobname = 'maintain_{table_name}_1s';

UPDATE cron.job 
SET database = 'iotmetrics',
    command = 'SELECT silver.maintain_timeseries_tables(''silver.{table_name}_1m'')'
WHERE jobname = 'maintain_{table_name}_1m'; 