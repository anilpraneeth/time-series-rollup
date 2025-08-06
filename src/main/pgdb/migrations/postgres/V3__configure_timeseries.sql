-- V8.1: Configure cron jobs for ESS signals rollups

-- Schedule maintenance jobs for ESS signals rollups
SELECT cron.schedule(
    'timeseries_rollup',
    '* * * * *',  -- Run every minute
    $$SELECT silver.perform_rollup()$$
);

-- Update existing cron jobs for ESS signals
UPDATE cron.job 
SET database = 'iotmetrics',
    command = 'SELECT silver.perform_rollup()'
WHERE jobname = 'timeseries_rollup';