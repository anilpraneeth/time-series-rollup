-- Enable required extensions
CREATE SCHEMA IF NOT EXISTS partman;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_partman') THEN
        CREATE EXTENSION pg_partman WITH SCHEMA partman;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'ltree') THEN
        CREATE EXTENSION ltree;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'btree_gin') THEN
        CREATE EXTENSION btree_gin;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'hypopg') THEN
        CREATE EXTENSION hypopg;
    END IF;
END $$;

-- Grant necessary permissions
GRANT USAGE ON SCHEMA partman TO datapipelineadmin; 