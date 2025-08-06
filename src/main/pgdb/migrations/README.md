# Database Migrations with Flyway

This directory contains database migrations for the IoT Metrics Data Pipeline. We use Flyway to manage database migrations across multiple databases and schemas.

## Migration Structure

The migrations are organized into different directories based on their purpose and target database:

```
migrations/
├── foundational/
│   ├── initial-setup/          # Basic database setup
│   │   ├── V1__create_schemas.sql
│   │   ├── V2__setup_iotmetrics_extensions.sql
│   │   ├── V3__setup_iam_user.sql
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
│   └── V3__configure_ess_signals_cron_jobs.sql
└── payload-tables/           # Data table definitions
    ├── ess-signals/
    │   ├── V11__create_ess_signals_table.sql
    │   └── V12__configure_ess_signals_dimensions.sql
    └── ess-summary/
        ├── V1__create_table.sql
        └── V2__configure_ess_summary_dimensions.sql
```

## Configuration Files

We maintain separate Flyway configurations for different databases:

1. `flyway.conf` - Main configuration for iotmetrics database
2. `flyway.postgres.conf` - Configuration for postgres database (cron jobs)

## Migration Order

The migrations should be executed in the following order:

1. **Postgres Database** (using flyway.postgres.conf):
   ```bash
   flyway -configFiles=pgdb/flyway.postgres.conf migrate
   ```
   - Sets up pg_cron extension
   - Configures maintenance cron jobs
   - Configures ESS signals cron jobs

2. **IoTMetrics Database** (using flyway.conf):
   ```bash
   # Run foundational and timeseries migrations
   flyway -configFiles=pgdb/flyway.conf -locations=filesystem:pgdb/migrations/foundational/initial-setup,filesystem:pgdb/migrations/foundational/timeseries migrate

   # Run ESS signals migrations
   flyway -configFiles=pgdb/flyway.conf -locations=filesystem:pgdb/migrations/foundational/initial-setup,filesystem:pgdb/migrations/foundational/timeseries,filesystem:pgdb/migrations/payload-tables/ess-signals migrate

   # Run ESS summary migrations
   flyway -configFiles=pgdb/flyway.conf -locations=filesystem:pgdb/migrations/foundational/initial-setup,filesystem:pgdb/migrations/foundational/timeseries,filesystem:pgdb/migrations/payload-tables/ess-summary migrate
   ```

## Migration Types

1. **Foundational Migrations**
   - Schema creation
   - Extension setup
   - User and permission management

2. **Time-series Migrations**
   - Core time-series functions
   - Table tracking
   - Rollup functionality
   - Maintenance procedures

3. **Payload Table Migrations**
   - ESS signals table creation
   - ESS summary table creation
   - Partitioning setup
   - Dimension configuration

## Common Commands

1. **Check Migration Status**
   ```bash
   flyway -configFiles=pgdb/flyway.conf info
   ```

2. **Repair Schema History**
   ```bash
   flyway -configFiles=pgdb/flyway.conf repair
   ```

3. **Validate Migrations**
   ```bash
   flyway -configFiles=pgdb/flyway.conf validate
   ```

## Best Practices

1. **Version Numbering**
   - Use sequential version numbers (V1, V2, etc.)
   - Keep version numbers unique across all migrations
   - Use descriptive names after version number

2. **Migration Content**
   - Each migration should be atomic and self-contained
   - Include rollback statements where possible
   - Document complex migrations with comments

3. **Testing**
   - Test migrations in development environment first
   - Verify idempotency of migrations
   - Check for dependencies between migrations

## Troubleshooting

1. **Checksum Mismatch**
   ```bash
   flyway -configFiles=pgdb/flyway.conf repair
   ```

2. **Version Conflicts**
   - Ensure version numbers are unique
   - Use repair command if necessary
   - Check migration history table

3. **Database Connections**
   - Verify database URL in config files
   - Check user permissions
   - Ensure target database exists

## Security Considerations

1. Store sensitive configuration (passwords, etc.) securely
2. Use least-privilege database users for migrations
3. Review permissions granted in migrations
4. Audit migration scripts for security implications

## Maintenance

1. Regularly clean up old migrations
2. Monitor migration performance
3. Update documentation when adding new migrations
4. Keep backups before running major migrations 