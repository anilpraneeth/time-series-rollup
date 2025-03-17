# Troubleshooting Guide

## Common Issues and Solutions

### 1. Performance Issues

#### Slow Rollup Processing

**Symptoms:**
- Long processing times for rollup operations
- High CPU usage
- Slow query response times

**Solutions:**
1. Check partition sizes:
```sql
SELECT * FROM silver.get_partition_stats('your_table_name');
```

2. Verify indexes:
```sql
SELECT schemaname, tablename, indexname, indexdef
FROM pg_indexes
WHERE tablename = 'your_table_name';
```

3. Adjust look_back_window:
```sql
UPDATE silver.timeseries_rollup_config
SET look_back_window = '3 days'
WHERE source_table_name = 'your_table_name';
```

### 2. Data Consistency Issues

#### Missing Data in Rollup Tables

**Symptoms:**
- Gaps in aggregated data
- Incomplete rollup results
- Missing time periods

**Solutions:**
1. Check error logs:
```sql
SELECT * FROM silver.timeseries_error_log
WHERE rollup_config_id = (
    SELECT id FROM silver.timeseries_rollup_config
    WHERE target_table_name = 'your_table_name'
)
ORDER BY error_time DESC;
```

2. Verify source data:
```sql
SELECT MIN(timestamp), MAX(timestamp), COUNT(*)
FROM raw.your_source_table
WHERE timestamp >= NOW() - INTERVAL '7 days';
```

3. Check refresh logs:
```sql
SELECT * FROM silver.timeseries_refresh_log
WHERE rollup_config_id = (
    SELECT id FROM silver.timeseries_rollup_config
    WHERE target_table_name = 'your_table_name'
)
ORDER BY start_time DESC;
```

### 3. Permission Issues

#### Access Denied Errors

**Symptoms:**
- Permission denied errors
- Unable to create tables
- Unable to execute functions

**Solutions:**
1. Verify user permissions:
```sql
SELECT grantee, privilege_type
FROM information_schema.role_table_grants
WHERE table_schema = 'silver';
```

2. Check role memberships:
```sql
SELECT r.rolname, m.member
FROM pg_roles r
JOIN pg_auth_members m ON r.oid = m.roleid
WHERE r.rolname = 'your_role';
```

3. Grant necessary permissions:
```sql
GRANT USAGE ON SCHEMA silver TO your_role;
GRANT SELECT, INSERT ON silver.timeseries_rollup_config TO your_role;
```

### 4. Partition Management Issues

#### Partition Creation Failures

**Symptoms:**
- Failed partition creation
- Missing partitions
- Partition size issues

**Solutions:**
1. Check partition configuration:
```sql
SELECT * FROM partman.part_config
WHERE parent_table = 'your_table_name';
```

2. Verify partition maintenance:
```sql
SELECT * FROM partman.partition_tables
WHERE parent_table = 'your_table_name';
```

3. Run partition maintenance:
```sql
SELECT partman.maintenance('your_table_name');
```

### 5. Extension Issues

#### Missing or Invalid Extensions

**Symptoms:**
- Function not found errors
- Extension-related errors
- Invalid function calls

**Solutions:**
1. Check installed extensions:
```sql
SELECT * FROM pg_extension;
```

2. Verify extension versions:
```sql
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('pg_partman', 'ltree', 'btree_gin', 'hypopg', 'pg_cron');
```

3. Install missing extensions:
```sql
CREATE EXTENSION IF NOT EXISTS pg_partman;
CREATE EXTENSION IF NOT EXISTS ltree;
CREATE EXTENSION IF NOT EXISTS btree_gin;
CREATE EXTENSION IF NOT EXISTS hypopg;
CREATE EXTENSION IF NOT EXISTS pg_cron;
```

## Diagnostic Tools

### 1. System Health Check

```sql
-- Check system load
SELECT * FROM silver.get_detailed_stats('gold.%');

-- Check partition health
SELECT * FROM silver.get_partition_stats('gold.%');

-- Check error rates
SELECT COUNT(*) as error_count
FROM silver.timeseries_error_log
WHERE error_time >= NOW() - INTERVAL '24 hours';
```

### 2. Performance Analysis

```sql
-- Check slow queries
SELECT query, calls, total_time, mean_time
FROM pg_stat_statements
WHERE query LIKE '%silver.%'
ORDER BY mean_time DESC
LIMIT 10;

-- Check table statistics
SELECT schemaname, relname, n_live_tup, n_dead_tup
FROM pg_stat_user_tables
WHERE schemaname IN ('raw', 'silver', 'gold');
```

## Best Practices

1. **Regular Monitoring**
   - Set up alerts for error conditions
   - Monitor system performance
   - Track data consistency

2. **Maintenance**
   - Regular vacuum operations
   - Index maintenance
   - Statistics updates

3. **Backup and Recovery**
   - Regular backups
   - Test recovery procedures
   - Document recovery steps

4. **Performance Tuning**
   - Monitor query performance
   - Adjust configuration parameters
   - Optimize partition sizes

## Getting Help

If you encounter issues not covered in this guide:

1. Check the error logs
2. Review the configuration
3. Consult the API documentation
4. Check GitHub issues
5. Contact the maintainers 