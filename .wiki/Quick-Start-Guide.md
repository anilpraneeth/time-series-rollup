# Quick Start Guide

This guide will help you get the Time Series Rollup System up and running quickly.

## Prerequisites

1. **Database Requirements**
   - PostgreSQL 12 or higher (AWS RDS/Aurora)
   - Sufficient storage for your time-series data
   - Appropriate IAM roles and permissions

2. **Required Extensions**
   ```sql
   -- Check if extensions are available
   SELECT name, default_version, installed_version
   FROM pg_available_extensions
   WHERE name IN ('pg_partman', 'ltree', 'btree_gin', 'hypopg', 'pg_cron');
   ```

## Installation

### Method 1: Using Flyway (Recommended)

1. **Clone the Repository**
   ```bash
   git clone https://github.com/anilpraneeth/time-series-rollup.git
   cd time-series-rollup
   ```

2. **Configure Flyway**
   ```bash
   # Create flyway.conf
   cat > flyway.conf << EOF
   flyway.url=jdbc:postgresql://your-host:5432/your-database
   flyway.user=your-user
   flyway.password=your-password
   flyway.schemas=raw,silver,gold,partman
   EOF
   ```

3. **Run Migrations**
   ```bash
   flyway migrate
   ```

### Method 2: Direct SQL Installation

1. **Install Extensions**
   ```sql
   CREATE EXTENSION IF NOT EXISTS pg_partman;
   CREATE EXTENSION IF NOT EXISTS ltree;
   CREATE EXTENSION IF NOT EXISTS btree_gin;
   CREATE EXTENSION IF NOT EXISTS hypopg;
   CREATE EXTENSION IF NOT EXISTS pg_cron;
   ```

2. **Run Installation Script**
   ```bash
   psql -U your_user -d your_database -f pgdb/migrations/foundational/timeseries/V1__init.sql
   ```

## Basic Usage

### 1. Create Your First Rollup Table

```sql
-- Create a rollup table for hourly metrics
SELECT silver.create_rollup_table(
    source_table_name := 'raw.metrics',
    target_table_name := 'gold.metrics_hourly',
    rollup_interval := '1 hour',
    look_back_window := '7 days'
);

-- Add dimension configuration
INSERT INTO silver.timeseries_dimension_config (
    rollup_config_id,
    dimension_name,
    dimension_type,
    aggregation_type
) VALUES (
    currval('silver.timeseries_rollup_config_id_seq'),
    'metric_name',
    'text',
    'group_by'
);
```

### 2. Start Processing

```sql
-- Run the rollup
SELECT silver.perform_rollup('gold.metrics_hourly');

-- Check the results
SELECT * FROM silver.get_detailed_stats('gold.metrics_hourly');
```

### 3. Monitor Performance

```sql
-- Check partition statistics
SELECT * FROM silver.get_partition_stats('gold.metrics_hourly');

-- Monitor error logs
SELECT * FROM silver.timeseries_error_log
WHERE error_time >= NOW() - INTERVAL '24 hours';
```

## Next Steps

1. **Review the Documentation**
   - [Architecture Overview](Architecture)
   - [Configuration Guide](Configuration)
   - [API Reference](API-Reference)

2. **Configure Monitoring**
   - Set up alerts for errors
   - Monitor system performance
   - Track data consistency

3. **Optimize Performance**
   - Adjust partition sizes
   - Fine-tune rollup intervals
   - Monitor resource usage

## Common Issues

If you encounter any issues:

1. Check the [Troubleshooting Guide](Troubleshooting)
2. Review the [FAQ](FAQ)
3. Check [Known Issues](Known-Issues)
4. [Contact](Contact) the maintainers

## Additional Resources

- [Configuration Guide](Configuration) - Detailed configuration options
- [API Reference](API-Reference) - Complete function documentation
- [Troubleshooting Guide](Troubleshooting) - Common issues and solutions 