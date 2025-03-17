-- Test schema creation
SELECT schema_name 
FROM information_schema.schemata 
WHERE schema_name IN ('raw', 'silver', 'gold', 'partman');

-- Test extension creation
SELECT extname 
FROM pg_extension 
WHERE extname IN ('pg_partman', 'ltree', 'btree_gin', 'hypopg', 'pg_cron');

-- Test user creation
SELECT rolname 
FROM pg_roles 
WHERE rolname IN ('datapipelineadmin', 'db_ecs_user');

-- Test function creation
SELECT routine_name, routine_schema
FROM information_schema.routines
WHERE routine_schema = 'silver'
ORDER BY routine_name;

-- Test table creation
SELECT table_name, table_schema
FROM information_schema.tables
WHERE table_schema = 'silver'
ORDER BY table_name; 