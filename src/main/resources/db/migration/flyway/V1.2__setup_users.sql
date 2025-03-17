-- Create users if they don't exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'datapipelineadmin') THEN
        CREATE USER datapipelineadmin WITH PASSWORD 'CHANGE_ME';
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'db_ecs_user') THEN
        CREATE USER db_ecs_user WITH PASSWORD 'CHANGE_ME';
    END IF;
END
$$;

-- Grant necessary permissions
GRANT CONNECT ON DATABASE postgres TO datapipelineadmin;
GRANT CONNECT ON DATABASE postgres TO db_ecs_user;

-- Grant schema permissions
GRANT USAGE ON ALL SCHEMAS IN DATABASE postgres TO datapipelineadmin;
GRANT USAGE ON ALL SCHEMAS IN DATABASE postgres TO db_ecs_user;

-- Grant table permissions
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA raw TO datapipelineadmin;
GRANT SELECT ON ALL TABLES IN SCHEMA raw TO db_ecs_user;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA silver TO datapipelineadmin;
GRANT SELECT ON ALL TABLES IN SCHEMA silver TO db_ecs_user;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA gold TO datapipelineadmin;
GRANT SELECT ON ALL TABLES IN SCHEMA gold TO db_ecs_user; 