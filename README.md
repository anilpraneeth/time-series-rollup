# Time Series Rollup System

<div align="center">
  <img src="docs/images/time-series-elephant.png" alt="Time Series Rollup System - PostgreSQL Elephant with Time Series Visualization" width="300px">
  <p><em>Enterprise-grade time-series data management with PostgreSQL</em></p>
</div>

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Python](https://img.shields.io/badge/Python-3.8+-blue.svg)](https://www.python.org/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-12+-blue.svg)](https://www.postgresql.org/)
[![Maintenance](https://img.shields.io/badge/Maintained%3F-yes-green.svg)](https://github.com/anilpraneeth/time-series-rollup/graphs/commit-activity)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](http://makeapullrequest.com)

A production-ready PostgreSQL-based system for managing and aggregating time-series data with exponential rollup strategies, adaptive processing windows, comprehensive monitoring, and robust error handling. This system is specifically designed for AWS RDS or Aurora PostgreSQL as an alternative to pg_timeseries and pg_timescaledb, which are not supported in these environments.

## Table of Contents
- [Quick Start](#quick-start)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [System Architecture](#system-architecture)
- [Configuration](#configuration)
- [Usage](#usage)
- [Monitoring & Maintenance](#monitoring--maintenance)
- [Permissions](#permissions)
- [Contributing](#contributing)
- [Roadmap](#roadmap)
- [License](#license)
- [Acknowledgments](#acknowledgments)

## Quick Start

1. **Install Required Extensions**
```sql
CREATE EXTENSION IF NOT EXISTS pg_partman;
CREATE EXTENSION IF NOT EXISTS ltree;
CREATE EXTENSION IF NOT EXISTS btree_gin;
CREATE EXTENSION IF NOT EXISTS hypopg;
CREATE EXTENSION IF NOT EXISTS pg_cron;
```

2. **Run the Installation**
```bash
# Using Flyway (Recommended)
flyway -configFiles=src/main/pgdb/flyway.conf migrate

# OR using direct SQL
psql -U your_user -d your_database -f src/main/pgdb/migrations/foundational/timeseries/V5__timeseries_core_functions.sql
```

3. **Create Your First Rollup Table**
```sql
SELECT silver.create_rollup_table(
    source_table_name := 'your_source_table',
    target_table_name := 'your_target_table',
    rollup_interval := '1 hour',
    look_back_window := '7 days'
);
```

4. **Start Processing**
```sql
SELECT silver.perform_rollup('your_table_name');
```

## Features

- **Exponential Rollup**: Efficiently aggregates time-series data at different time intervals
- **Adaptive Processing**: Automatically adjusts processing windows based on system load and performance
- **Smart Partition Management**: Optimizes chunk intervals based on data ingestion rates and target sizes
- **Comprehensive Monitoring**: Built-in monitoring views and performance tracking
- **Retry Mechanism**: Exponential backoff retry with configurable thresholds
- **Concurrent Processing**: Safe handling of multiple rollup operations with optimistic locking
- **Error Handling**: Comprehensive error logging and recovery mechanisms
- **Performance Optimization**: Automatic partition optimization and maintenance procedures
- **Required Extensions**:
  - pg_partman (for partitioning)
  - ltree (for hierarchical data)
  - btree_gin (for GIN index support)
  - hypopg (for hypothetical indexes)
  - pg_cron (for scheduled tasks)

## Prerequisites

- PostgreSQL 12 or higher (specifically AWS RDS PostgreSQL 12+ or Aurora PostgreSQL 12+)
- Python 3.8 or higher (if using Python components)
- Required PostgreSQL extensions (all available in AWS RDS/Aurora):
  - pg_partman
  - ltree
  - btree_gin
  - hypopg
  - pg_cron

## Installation

The system can be installed using two methods:

### Method 1: Flyway Migration (Recommended)
```bash
# Run foundational and timeseries migrations
flyway -configFiles=src/main/pgdb/flyway.conf -locations=filesystem:src/main/pgdb/migrations/foundational/initial-setup,filesystem:src/main/pgdb/migrations/foundational/timeseries migrate
```

### Method 2: Direct SQL Installation
```bash
psql -U your_user -d your_database -f src/main/pgdb/migrations/foundational/timeseries/V5__timeseries_core_functions.sql
```

The migrations are located in the `src/main/pgdb/migrations` directory.

## System Architecture

The system is built with several key components:

1. **Schema Structure**:
   - raw (for raw data)
   - silver (for processed data)
   - gold (for aggregated data)
   - partman (for partitioning)

2. **Core Components**:
   - Time Bucket Functions: Efficient timestamp bucketing
   - Value Functions: First/last value aggregation
   - Rollup Management: Table creation and processing
   - Error Handling: Comprehensive error tracking
   - Performance Monitoring: System health tracking
   - Maintenance Functions: Automated optimization

3. **Monitoring & Operations**:
   - `timeseries_operations_monitor`: Real-time operation monitoring
   - `handle_rollup_retries()`: Automated retry mechanism
   - `optimize_chunk_interval()`: Smart partition optimization
   - `maintain_timeseries_tables()`: Automated maintenance

## Configuration

The system uses several configuration tables:

- `timeseries_rollup_config`: Main configuration for rollup operations
- `timeseries_dimension_config`: Manages dimension columns
- `timeseries_refresh_log`: Tracks successful operations
- `timeseries_error_log`: Records error information

## Usage

### Creating a Rollup Table

```sql
SELECT silver.create_rollup_table(
    source_table_name := 'your_source_table',
    target_table_name := 'your_target_table',
    rollup_interval := '1 hour',
    look_back_window := '7 days'
);
```

### Running Rollups

```sql
SELECT silver.perform_rollup('your_table_name');
```

### Monitoring Operations

```sql
-- Get real-time operation status
SELECT * FROM silver.timeseries_operations_monitor;

-- Get detailed statistics
SELECT * FROM silver.get_detailed_stats('your_table_pattern');

-- Check partition statistics
SELECT * FROM silver.get_partition_stats('your_table_name');
```

### Automated Maintenance

```sql
-- Optimize chunk intervals
SELECT silver.optimize_chunk_interval('your_table_name');

-- Run maintenance procedures
SELECT silver.maintain_timeseries_tables('your_table_name');

-- Handle retries
SELECT silver.handle_rollup_retries();
```

## Monitoring & Maintenance

### Real-time Monitoring
The system provides comprehensive monitoring through:

1. **Operations Monitor View**: `silver.timeseries_operations_monitor`
   - Health status (OK, WARNING, ALERT)
   - Processing status and worker information
   - Error tracking and retry counts
   - Performance metrics

2. **Performance Tracking**:
   - Average processing duration
   - Success rates
   - Records processed per operation
   - System load balancing

3. **Error Management**:
   - Comprehensive error logging
   - Exponential backoff retry mechanism
   - Alert thresholds for long-running operations
   - Detailed error context and SQL state

### Automated Maintenance
The system includes several maintenance functions:

1. **Smart Partition Management**:
   - `optimize_chunk_interval()`: Calculates optimal partition sizes
   - `get_partition_stats()`: Detailed partition statistics
   - Automatic partition optimization based on data ingestion rates

2. **Table Maintenance**:
   - `maintain_timeseries_tables()`: Automated maintenance procedures
   - Index optimization
   - Statistics updates
   - Performance monitoring

3. **Retry Mechanism**:
   - `handle_rollup_retries()`: Processes failed operations
   - Exponential backoff strategy
   - Configurable retry limits and thresholds

## Permissions

The system sets up the following permissions:
- `datapipelineadmin`: Usage on cron and partman schemas
- `db_ecs_user`: Usage and SELECT on all schemas

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Built with PostgreSQL
- Inspired by time-series data management best practices
- Designed specifically for AWS RDS and Aurora PostgreSQL environments

## Roadmap

### Current Version (1.1.0)
- ✅ Basic rollup functionality
- ✅ Partition management
- ✅ Error handling and logging
- ✅ Performance monitoring
- ✅ Real-time operations monitoring
- ✅ Automated retry mechanism
- ✅ Smart partition optimization
- ✅ Comprehensive maintenance procedures

### Planned Features
- 🔄 Real-time rollup processing
- 🔄 Advanced compression algorithms
- 🔄 Machine learning-based window optimization
- 🔄 Distributed processing support
- 🔄 Enhanced monitoring dashboard
- 🔄 Automated maintenance procedures
- 🔄 Cloud-native deployment templates

### Future Considerations
- 📅 Integration with other time-series databases
- 📅 Support for additional cloud providers
- 📅 Enhanced security features
- 📅 Advanced analytics capabilities
- 📅 Custom aggregation functions
- 📅 Automated backup and recovery

## Documentation

For detailed documentation, please visit our [Wiki](https://github.com/anilpraneeth/time-series-rollup/wiki).

Key documentation sections:
- [Architecture Overview](https://github.com/anilpraneeth/time-series-rollup/wiki/Architecture)
- [Configuration Guide](https://github.com/anilpraneeth/time-series-rollup/wiki/Configuration)
- [API Reference](https://github.com/anilpraneeth/time-series-rollup/wiki/API-Reference)
- [Troubleshooting](https://github.com/anilpraneeth/time-series-rollup/wiki/Troubleshooting) 