# Database migrations

Foundational migrations V1–V10 are historical deployment artifacts. V11 adds the reliable numeric rollup engine; V12 replaces operational statistics, validation, and maintenance. V13 adds dependency-aware backfill planning; V14 adds resumable jobs and progress monitoring. Never edit or regenerate a migration already applied to a database.

## Choose an installation path

- **Fresh local or portable PostgreSQL 14+**: run `make install` from the repository root with `DATABASE_URL` set to an empty database. This applies the portable bootstrap and V5–V14 atomically, without extension or AWS dependencies and without Flyway history.
- **Existing Flyway deployment**: keep its existing history table and run the foundational configuration below. Read the [upgrade guide](../../../../docs/upgrading.md) before V11, because legacy rollup tables need recreation and backfill.
- **Fresh AWS-specific Flyway deployment**: review `foundational/initial-setup` first. These historical migrations assume `datapipelineadmin`, the RDS `rds_iam` role, and available pg_partman, ltree, btree_gin, and hypopg extensions. V3 creates `db_ecs_user`; it must not already exist. This path is distinct from the extension-free portable bootstrap.

From the repository root, configure the target through `FLYWAY_URL`, `FLYWAY_USER`, and `FLYWAY_PASSWORD`, then:

```sh
flyway -configFiles=src/main/pgdb/flyway-foundational.conf validate
flyway -configFiles=src/main/pgdb/flyway-foundational.conf migrate
flyway -configFiles=src/main/pgdb/flyway-foundational.conf info
```

Do not baseline an existing schema or repair checksums merely to get past an error. Review its real migration state and preserve its migration history. Never delete historical migrations as cleanup.

## Structure

```text
foundational/initial-setup/  V1–V4: historical schemas, AWS roles, extensions, permissions
foundational/timeseries/    V5–V10: original engine
                           V11: complete-bucket refresh and incremental numeric engine
                           V12: monitoring, validation, and maintenance
                           V13–V14: dependency-aware plans and resumable backfill jobs
postgres/                  V1–V4: historical deployment-specific pg_cron setup
                           generate_migration.py: safe manifest-driven schedule generator
```

Foundational and postgres migrations have separate Flyway history tables. Run foundational setup before enabling schedules. The old postgres migrations contain the `iotmetrics` database name and example tables; review and customize through new migrations for the actual deployment. Do not run the old Flyway-only Docker wrapper as if it provisions a PostgreSQL server; the root Compose file provides the local database workflow.

## Generate a new maintenance schedule migration

A manifest directory contains JSON files whose top-level value is an array:

```json
[{"ProtoDefName": "telemetry.Readings"}]
```

Generate a **new** migration file, from any working directory:

```sh
python3 src/main/pgdb/migrations/postgres/generate_migration.py \
  --manifests /path/to/manifests \
  --output /path/to/V5__schedule_actual_tables.sql \
  --database rollup \
  --intervals 1m,5m
```

The generator validates manifest structure and identifiers, rejects name collisions and excessive identifier lengths, sorts output deterministically, safely quotes SQL literals, and routes each named job to its database with `cron.schedule_in_database`. It does not connect to a database or run generated SQL. Existing output files are refused unless `--force` is explicitly supplied; use `--force` only for an unapplied draft.

The default schedule is `0 0 * * *`. Use `--schedule` to change it; pg_cron validates the schedule syntax when SQL is executed. Review generated jobs and actual table names before applying through the postgres migration stream.

## Verification

Run `make test` and the Python unittest suite from the repository root. See the [root README](../../../../README.md) for the current API and [local development](../../../../docs/local-development.md) for disposable PostgreSQL tests.
