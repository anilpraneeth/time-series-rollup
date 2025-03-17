# Configuration Guide

## Overview

The Time Series Rollup System uses several configuration tables to manage its operations. This guide explains how to configure and manage these settings.

## Configuration Tables

### timeseries_rollup_config

Main configuration table for rollup operations.

```sql
CREATE TABLE silver.timeseries_rollup_config (
    id SERIAL PRIMARY KEY,
    source_table_name TEXT NOT NULL,
    target_table_name TEXT NOT NULL,
    rollup_interval INTERVAL NOT NULL,
    look_back_window INTERVAL NOT NULL,
    enabled BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
```

#### Key Parameters
- `source_table_name`: Name of the source table
- `target_table_name`: Name of the target rollup table
- `rollup_interval`: Time interval for rollup (e.g., '1 hour', '1 day')
- `look_back_window`: How far back to look for data
- `enabled`: Whether the rollup is active

### timeseries_dimension_config

Manages dimension columns for aggregation.

```sql
CREATE TABLE silver.timeseries_dimension_config (
    id SERIAL PRIMARY KEY,
    rollup_config_id INTEGER REFERENCES silver.timeseries_rollup_config(id),
    dimension_name TEXT NOT NULL,
    dimension_type TEXT NOT NULL,
    aggregation_type TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
```

#### Key Parameters
- `rollup_config_id`: Reference to rollup configuration
- `dimension_name`: Name of the dimension column
- `dimension_type`: Data type of the dimension
- `aggregation_type`: Type of aggregation to perform

### timeseries_refresh_log

Tracks successful operations.

```sql
CREATE TABLE silver.timeseries_refresh_log (
    id SERIAL PRIMARY KEY,
    rollup_config_id INTEGER REFERENCES silver.timeseries_rollup_config(id),
    start_time TIMESTAMP WITH TIME ZONE NOT NULL,
    end_time TIMESTAMP WITH TIME ZONE NOT NULL,
    rows_processed BIGINT NOT NULL,
    status TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
```

### timeseries_error_log

Records error information.

```sql
CREATE TABLE silver.timeseries_error_log (
    id SERIAL PRIMARY KEY,
    rollup_config_id INTEGER REFERENCES silver.timeseries_rollup_config(id),
    error_time TIMESTAMP WITH TIME ZONE NOT NULL,
    error_message TEXT NOT NULL,
    error_details JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
```

## Configuration Examples

### Basic Rollup Configuration

```sql
-- Create a new rollup configuration
INSERT INTO silver.timeseries_rollup_config (
    source_table_name,
    target_table_name,
    rollup_interval,
    look_back_window
) VALUES (
    'raw.metrics',
    'gold.metrics_hourly',
    '1 hour',
    '7 days'
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

### Advanced Configuration

```sql
-- Configure multiple dimensions
INSERT INTO silver.timeseries_dimension_config (
    rollup_config_id,
    dimension_name,
    dimension_type,
    aggregation_type
) VALUES 
    (1, 'metric_name', 'text', 'group_by'),
    (1, 'host', 'text', 'group_by'),
    (1, 'region', 'text', 'group_by');

-- Configure value aggregations
INSERT INTO silver.timeseries_dimension_config (
    rollup_config_id,
    dimension_name,
    dimension_type,
    aggregation_type
) VALUES 
    (1, 'value', 'numeric', 'avg'),
    (1, 'value', 'numeric', 'max'),
    (1, 'value', 'numeric', 'min');
```

## Monitoring Configuration

### Check Active Configurations

```sql
SELECT 
    rc.source_table_name,
    rc.target_table_name,
    rc.rollup_interval,
    rc.look_back_window,
    COUNT(dc.id) as dimension_count
FROM silver.timeseries_rollup_config rc
LEFT JOIN silver.timeseries_dimension_config dc 
    ON rc.id = dc.rollup_config_id
WHERE rc.enabled = true
GROUP BY rc.id;
```

### View Recent Errors

```sql
SELECT 
    rc.source_table_name,
    el.error_time,
    el.error_message
FROM silver.timeseries_error_log el
JOIN silver.timeseries_rollup_config rc 
    ON el.rollup_config_id = rc.id
ORDER BY el.error_time DESC
LIMIT 10;
```

## Best Practices

1. **Naming Conventions**
   - Use descriptive table names
   - Include time interval in target table names
   - Follow consistent schema naming

2. **Performance Tuning**
   - Adjust look_back_window based on data volume
   - Monitor partition sizes
   - Regular maintenance of configuration tables

3. **Error Handling**
   - Monitor error logs regularly
   - Set up alerts for critical errors
   - Implement retry mechanisms

4. **Security**
   - Regular audit of configurations
   - Principle of least privilege
   - Secure credential management 