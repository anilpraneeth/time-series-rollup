-- Enable pg_cron extension in postgres database
CREATE EXTENSION IF NOT EXISTS pg_cron;
GRANT USAGE ON SCHEMA cron TO datapipelineadmin; 