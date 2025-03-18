# Time Series Rollup System

<div align="center">
  <img src="docs/images/time-series-elephant.png" alt="Time Series Rollup System - PostgreSQL Elephant with Time Series Visualization" width="300px">
  <p><em>Efficient time-series data management with PostgreSQL</em></p>
</div>

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Python](https://img.shields.io/badge/Python-3.8+-blue.svg)](https://www.python.org/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-12+-blue.svg)](https://www.postgresql.org/)
[![Maintenance](https://img.shields.io/badge/Maintained%3F-yes-green.svg)](https://github.com/anilpraneeth/time-series-rollup/graphs/commit-activity)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](http://makeapullrequest.com)

A robust PostgreSQL-based system for managing and aggregating time-series data with exponential rollup strategies, adaptive processing windows, and comprehensive error handling. This system is specifically designed for AWS RDS or Aurora PostgreSQL as an alternative to pg_timeseries and pg_timescaledb, which are not supported in these environments.

## Table of Contents
- [Quick Start](#quick-start)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [System Architecture](#system-architecture)
- [Configuration](#configuration)
- [Usage](#usage)
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
flyway migrate

# OR using direct SQL
psql -U your_user -d your_database -f pgdb/migrations/foundational/timeseries/V1__init.sql
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
- **Dimension Support**: Flexible dimension-based aggregation
- **Error Handling**: Comprehensive error logging and retry mechanisms
- **Performance Monitoring**: Built-in monitoring and optimization tools
- **Concurrent Processing**: Safe handling of multiple rollup operations
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

### Method 1: Direct SQL Installation
```bash
psql -U your_user -d your_database -f pgdb/migrations/foundational/timeseries/V1__init.sql
```

### Method 2: Flyway Migration (Recommended)
1. Ensure you have Flyway installed and configured with your database credentials
2. Run the migrations:
```bash
flyway migrate
```

The migrations are located in the `src/main/resources/db/migration` directory.

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

### Monitoring

```sql
-- Get detailed statistics
SELECT * FROM silver.get_detailed_stats('your_table_pattern');

-- Check partition statistics
SELECT * FROM silver.get_partition_stats('your_table_name');
```

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

### Current Version (1.0.0)
- ✅ Basic rollup functionality
- ✅ Partition management
- ✅ Error handling and logging
- ✅ Performance monitoring

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