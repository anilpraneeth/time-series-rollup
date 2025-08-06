-- Schedule maintenance jobs
SELECT cron.schedule('CLEANUP', '0 0 * * *', $$DELETE FROM cron.job_run_details WHERE end_time < now() - interval '7 days'$$);
SELECT cron.schedule('MAINTAIN', '*/15 * * * *', $$CALL partman.run_maintenance_proc()$$);
UPDATE cron.job SET database = 'iotmetrics', username = 'datapipelineadmin'
WHERE command NOT LIKE 'DELETE%'; 

-- Add cron job for retry handling
SELECT cron.schedule('*/5 * * * *', $$SELECT silver.handle_rollup_retries()$$);