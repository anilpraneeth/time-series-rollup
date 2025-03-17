-- Create required extensions
CREATE EXTENSION IF NOT EXISTS pg_partman;
CREATE EXTENSION IF NOT EXISTS ltree;
CREATE EXTENSION IF NOT EXISTS btree_gin;
CREATE EXTENSION IF NOT EXISTS hypopg;
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Grant usage permissions for extensions
GRANT USAGE ON SCHEMA partman TO datapipelineadmin;
GRANT USAGE ON SCHEMA partman TO db_ecs_user;

-- Grant execute permissions for pg_cron functions
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA cron TO datapipelineadmin;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA cron TO db_ecs_user; 