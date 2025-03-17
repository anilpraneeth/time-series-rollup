# API Reference

## Overview

This document provides detailed information about the functions and procedures available in the Time Series Rollup System.

## Core Functions

### Table Management

#### create_rollup_table

Creates a new rollup table with specified configuration.

```sql
CREATE OR REPLACE FUNCTION silver.create_rollup_table(
    source_table_name TEXT,
    target_table_name TEXT,
    rollup_interval INTERVAL,
    look_back_window INTERVAL
) RETURNS void
```

**Parameters:**
- `source_table_name`: Name of the source table
- `target_table_name`: Name of the target rollup table
- `rollup_interval`: Time interval for rollup
- `look_back_window`: How far back to look for data

**Example:**
```sql
SELECT silver.create_rollup_table(
    'raw.metrics',
    'gold.metrics_hourly',
    '1 hour',
    '7 days'
);
```

#### perform_rollup

Executes the rollup process for a specified table.

```sql
CREATE OR REPLACE FUNCTION silver.perform_rollup(
    table_name TEXT
) RETURNS void
```

**Parameters:**
- `table_name`: Name of the table to process

**Example:**
```sql
SELECT silver.perform_rollup('gold.metrics_hourly');
```

### Monitoring Functions

#### get_detailed_stats

Retrieves detailed statistics about rollup operations.

```sql
CREATE OR REPLACE FUNCTION silver.get_detailed_stats(
    table_pattern TEXT
) RETURNS TABLE (
    table_name TEXT,
    last_rollup TIMESTAMP WITH TIME ZONE,
    rows_processed BIGINT,
    processing_time INTERVAL,
    error_count INTEGER
)
```

**Parameters:**
- `table_pattern`: Pattern to match table names

**Example:**
```sql
SELECT * FROM silver.get_detailed_stats('gold.metrics_%');
```

#### get_partition_stats

Retrieves statistics about table partitions.

```sql
CREATE OR REPLACE FUNCTION silver.get_partition_stats(
    table_name TEXT
) RETURNS TABLE (
    partition_name TEXT,
    start_time TIMESTAMP WITH TIME ZONE,
    end_time TIMESTAMP WITH TIME ZONE,
    row_count BIGINT,
    size_bytes BIGINT
)
```

**Parameters:**
- `table_name`: Name of the table

**Example:**
```sql
SELECT * FROM silver.get_partition_stats('gold.metrics_hourly');
```

### Utility Functions

#### time_bucket

Creates time-based buckets for aggregation.

```sql
CREATE OR REPLACE FUNCTION silver.time_bucket(
    bucket_width INTERVAL,
    ts TIMESTAMP WITH TIME ZONE
) RETURNS TIMESTAMP WITH TIME ZONE
```

**Parameters:**
- `bucket_width`: Width of the time bucket
- `ts`: Timestamp to bucket

**Example:**
```sql
SELECT silver.time_bucket('1 hour', timestamp_column);
```

#### first_value

Gets the first value in a time window.

```sql
CREATE OR REPLACE FUNCTION silver.first_value(
    value ANYELEMENT,
    ts TIMESTAMP WITH TIME ZONE
) RETURNS ANYELEMENT
```

**Parameters:**
- `value`: Value to aggregate
- `ts`: Timestamp of the value

**Example:**
```sql
SELECT silver.first_value(metric_value, timestamp_column);
```

#### last_value

Gets the last value in a time window.

```sql
CREATE OR REPLACE FUNCTION silver.last_value(
    value ANYELEMENT,
    ts TIMESTAMP WITH TIME ZONE
) RETURNS ANYELEMENT
```

**Parameters:**
- `value`: Value to aggregate
- `ts`: Timestamp of the value

**Example:**
```sql
SELECT silver.last_value(metric_value, timestamp_column);
```

## Error Handling

### Common Error Codes

- `TSR001`: Invalid table name
- `TSR002`: Invalid time interval
- `TSR003`: Table already exists
- `TSR004`: Insufficient permissions
- `TSR005`: Processing error

### Error Handling Functions

#### log_error

Logs an error to the error log.

```sql
CREATE OR REPLACE FUNCTION silver.log_error(
    config_id INTEGER,
    error_message TEXT,
    error_details JSONB DEFAULT NULL
) RETURNS void
```

**Parameters:**
- `config_id`: ID of the rollup configuration
- `error_message`: Error message
- `error_details`: Additional error details (optional)

## Best Practices

1. **Function Usage**
   - Always use fully qualified function names
   - Check return values for errors
   - Use appropriate error handling

2. **Performance**
   - Use appropriate time intervals
   - Monitor function execution times
   - Use indexes effectively

3. **Security**
   - Use appropriate permissions
   - Validate input parameters
   - Handle sensitive data appropriately

4. **Maintenance**
   - Regular monitoring of function performance
   - Update statistics regularly
   - Monitor error logs 