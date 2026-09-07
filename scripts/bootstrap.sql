-- Executed inside install.sh's single transaction, before historical migrations.
-- This installer intentionally does not create Flyway history or AWS IAM roles.
SELECT pg_advisory_xact_lock(hashtext('time-series-rollup:portable-install'));

DO $bootstrap$
BEGIN
    IF current_setting('server_version_num')::integer < 140000 THEN
        RAISE EXCEPTION 'Time Series Rollup requires PostgreSQL 14 or newer';
    END IF;

    IF to_regclass('silver.timeseries_rollup_config') IS NOT NULL THEN
        RAISE EXCEPTION 'Time Series Rollup is already installed; use versioned migrations to upgrade';
    END IF;

    -- Extension-owned objects are allowed; application tables and functions are not.
    IF EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND n.nspname !~ '^pg_toast|^pg_temp_'
          AND NOT EXISTS (
              SELECT 1 FROM pg_depend d
              WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e'
          )
    ) OR EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND n.nspname !~ '^pg_toast|^pg_temp_'
          AND NOT EXISTS (
              SELECT 1 FROM pg_depend d
              WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e'
          )
    ) THEN
        RAISE EXCEPTION 'Portable installation requires an empty database; existing application objects were found';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'db_ecs_user') THEN
        CREATE ROLE db_ecs_user NOLOGIN;
    END IF;
END
$bootstrap$;

\ir ../src/main/pgdb/migrations/foundational/initial-setup/V1__create_schemas.sql

GRANT USAGE ON SCHEMA raw, silver, gold, raw_archive, silver_archive, gold_archive TO db_ecs_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA raw, silver, gold
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO db_ecs_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA raw_archive, silver_archive, gold_archive
    GRANT SELECT ON TABLES TO db_ecs_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA raw, silver, gold
    GRANT USAGE, SELECT ON SEQUENCES TO db_ecs_user;
