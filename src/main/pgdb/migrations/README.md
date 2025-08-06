# Database Migrations with Flyway

This directory contains database migrations for the Time-Series Rollup System. We use Flyway to manage database migrations across multiple databases and schemas.

## Migration Structure

The migrations are organized into different directories based on their purpose and target database:

```
migrations/
├── foundational/
│   ├── initial-setup/          # Basic database setup
│   │   ├── V1__create_schemas.sql
│   │   ├── V2__setup_extensions.sql
│   │   ├── V3__setup_users.sql
│   │   └── V4__configure_permissions.sql
│   └── timeseries/            # Time-series functionality
│       ├── V5__timeseries_core_functions.sql
│       ├── V6__timeseries_track_tables.sql
│       ├── V7__create_rollup_table.sql
│       ├── V8__perform_rollup.sql
│       ├── V9__timeseries_maintenance.sql
│       └── V10__timeseries_improvements.sql
├── postgres/                  # Postgres-specific migrations
│   ├── V1__setup_pgcron.sql
│   ├── V2__configure_cron_jobs.sql
│   ├── V3__configure_timeseries.sql
│   └── V4__configure_timeseries_maintenance.sql
└── payload-tables/           # Data table definitions (optional)
    └── example-tables/
        ├── V1__create_example_table.sql
        └── V2__configure_example_dimensions.sql
```

## Configuration Files

We maintain separate Flyway configurations for different databases:

1. `flyway-foundational.conf` - Main configuration for timeseries database
2. `flyway-postgres.conf` - Configuration for postgres database (cron jobs)

## Migration Order

The migrations should be executed in the following order:

1. **Postgres Database** (using flyway-postgres.conf):
   ```bash
   flyway -configFiles=src/main/pgdb/flyway-postgres.conf migrate
   ```
   - Sets up pg_cron extension
   - Configures maintenance cron jobs
   - Configures timeseries maintenance jobs

2. **Timeseries Database** (using flyway-foundational.conf):
   ```bash
   # Run foundational and timeseries migrations
   flyway -configFiles=src/main/pgdb/flyway-foundational.conf -locations=filesystem:src/main/pgdb/migrations/foundational/initial-setup,filesystem:src/main/pgdb/migrations/foundational/timeseries migrate

   # Optional: Run payload table migrations (if you have specific tables)
   flyway -configFiles=src/main/pgdb/flyway-foundational.conf -locations=filesystem:src/main/pgdb/migrations/foundational/initial-setup,filesystem:src/main/pgdb/migrations/foundational/timeseries,filesystem:src/main/pgdb/migrations/payload-tables/example-tables migrate
   ```

## Migration Types

1. **Foundational Migrations**
   - Schema creation (raw, silver, gold, partman)
   - Extension setup (pg_partman, ltree, btree_gin, hypopg, pg_cron)
   - User and permission management
   - Basic database configuration

2. **Time-series Migrations**
   - Core time-series functions (time_bucket, first_value, last_value)
   - Configuration tables (rollup_config, dimension_config, error_log, refresh_log)
   - Rollup functionality (create_rollup_table, perform_rollup)
   - Maintenance procedures (optimize_chunk_interval, maintain_timeseries_tables)
   - Monitoring and operations (timeseries_operations_monitor, handle_rollup_retries)

3. **Postgres Migrations**
   - pg_cron extension setup
   - Cron job configuration for maintenance
   - Timeseries maintenance scheduling

4. **Payload Table Migrations** (Optional)
   - Custom table creation for your specific use case
   - Dimension configuration
   - Partitioning setup

## Common Commands

1. **Check Migration Status**
   ```bash
   flyway -configFiles=src/main/pgdb/flyway-foundational.conf info
   ```

2. **Repair Schema History**
   ```bash
   flyway -configFiles=src/main/pgdb/flyway-foundational.conf repair
   ```

3. **Validate Migrations**
   ```bash
   flyway -configFiles=src/main/pgdb/flyway-foundational.conf validate
   ```

4. **Clean Database** (Development only)
   ```bash
   flyway -configFiles=src/main/pgdb/flyway-foundational.conf clean
   ```

## Migration Details

### Foundational Migrations

**V1__create_schemas.sql**
- Creates raw, silver, gold, and partman schemas
- Sets up basic schema structure for data pipeline

**V2__setup_extensions.sql**
- Installs required PostgreSQL extensions
- pg_partman for partitioning
- ltree for hierarchical data
- btree_gin for GIN index support
- hypopg for hypothetical indexes
- pg_cron for scheduled tasks

**V3__setup_users.sql**
- Creates database users with appropriate permissions
- Sets up user roles for different access levels

**V4__configure_permissions.sql**
- Configures permissions for all schemas
- Sets up user access controls

### Timeseries Migrations

**V5__timeseries_core_functions.sql**
- Core time-series functions (time_bucket, first_value, last_value)
- Performance monitoring functions
- Basic utility functions

**V6__timeseries_track_tables.sql**
- Configuration tables for rollup operations
- Error logging and refresh tracking tables
- Dimension configuration management

**V7__create_rollup_table.sql**
- Function to create rollup tables
- Handles dimension columns and aggregations
- Sets up partitioning and indexing

**V8__perform_rollup.sql**
- Main rollup execution function
- Adaptive processing windows
- Concurrent execution handling
- Error recovery and retry mechanisms

**V9__timeseries_maintenance.sql**
- Maintenance functions for tables
- Partition optimization
- Statistics updates
- Performance monitoring

**V10__timeseries_improvements.sql**
- Real-time operations monitoring
- Automated retry mechanism
- Enhanced error handling
- Performance optimizations

### Postgres Migrations

**V1__setup_pgcron.sql**
- Installs and configures pg_cron extension
- Sets up cron job infrastructure

**V2__configure_cron_jobs.sql**
- Configures basic maintenance cron jobs
- Sets up scheduled tasks

**V3__configure_timeseries.sql**
- Configures timeseries-specific cron jobs
- Sets up rollup processing schedules

**V4__configure_timeseries_maintenance.sql**
- Configures maintenance cron jobs for timeseries tables
- Provides example maintenance scheduling

## Best Practices

1. **Version Numbering**
   - Use sequential version numbers (V1, V2, etc.)
   - Keep version numbers unique across all migrations
   - Use descriptive names after version number

2. **Migration Content**
   - Each migration should be atomic and self-contained
   - Include rollback statements where possible
   - Document complex migrations with comments
   - Test migrations in development environment first

3. **Testing**
   - Test migrations in development environment first
   - Verify idempotency of migrations
   - Check for dependencies between migrations
   - Validate migration scripts before production

4. **Configuration**
   - Use environment-specific configuration files
   - Store sensitive configuration securely
   - Use least-privilege database users for migrations

## Troubleshooting

1. **Checksum Mismatch**
   ```bash
   flyway -configFiles=src/main/pgdb/flyway-foundational.conf repair
   ```

2. **Version Conflicts**
   - Ensure version numbers are unique
   - Use repair command if necessary
   - Check migration history table

3. **Database Connections**
   - Verify database URL in config files
   - Check user permissions
   - Ensure target database exists

4. **Extension Issues**
   - Verify PostgreSQL extensions are available
   - Check extension permissions
   - Ensure compatible PostgreSQL version

## Security Considerations

1. Store sensitive configuration (passwords, etc.) securely
2. Use least-privilege database users for migrations
3. Review permissions granted in migrations
4. Audit migration scripts for security implications
5. Use environment variables for sensitive data

## Maintenance

1. Regularly clean up old migrations
2. Monitor migration performance
3. Update documentation when adding new migrations
4. Keep backups before running major migrations
5. Test migrations in staging environment

## Customization

To customize this system for your specific use case:

1. **Add Payload Tables**: Create your own table migrations in `payload-tables/`
2. **Modify Maintenance**: Update cron job configurations in postgres migrations
3. **Extend Functions**: Add custom functions to timeseries migrations
4. **Configure Dimensions**: Set up dimension columns for your data model

## Quick Start

```bash
# 1. Set up postgres database (for cron jobs)
flyway -configFiles=src/main/pgdb/flyway-postgres.conf migrate

# 2. Set up main database with timeseries functionality
flyway -configFiles=src/main/pgdb/flyway-foundational.conf migrate

# 3. Verify installation
psql -d your_database -c "SELECT silver.get_detailed_stats('%');"
``` 