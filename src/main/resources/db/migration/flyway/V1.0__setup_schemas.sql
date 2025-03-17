-- Create required schemas if they don't exist
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS silver;
CREATE SCHEMA IF NOT EXISTS gold;
CREATE SCHEMA IF NOT EXISTS partman;

-- Grant usage permissions
GRANT USAGE ON SCHEMA raw TO datapipelineadmin;
GRANT USAGE ON SCHEMA silver TO datapipelineadmin;
GRANT USAGE ON SCHEMA gold TO datapipelineadmin;
GRANT USAGE ON SCHEMA partman TO datapipelineadmin;

GRANT USAGE ON SCHEMA raw TO db_ecs_user;
GRANT USAGE ON SCHEMA silver TO db_ecs_user;
GRANT USAGE ON SCHEMA gold TO db_ecs_user;
GRANT USAGE ON SCHEMA partman TO db_ecs_user; 