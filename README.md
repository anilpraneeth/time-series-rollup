# Time Series Rollup

<p align="center"><img src="docs/images/time-series-elephant.png" alt="PostgreSQL time series elephant" width="260"></p>

PostgreSQL time-series aggregation with complete-bucket refreshes, incremental workers, and composable numeric statistics. Run it on PostgreSQL 14+ without extensions, or use pg_partman 5+ for partition management and pg_cron for scheduling.

The reliability update adds a working local installation, database integration tests, safe backfills, bounded retries, and corrected operational statistics. Existing migrations remain unchanged; V11 and V12 introduce the new engine. **Existing rollup targets need recreation and backfill before using the new engine.** See the [upgrade guide](docs/upgrading.md).

## Quick start

From the repository root, with Docker Compose:

```sh
make up
make install-docker
make demo-docker
```

This starts PostgreSQL 16 on `localhost:55432`, installs into the empty `rollup` database, and runs a repeatable example with a late correction. Local development credentials are `rollup` / `rollup`; the port binds to localhost. `make down` stops the service and preserves its data.

With an existing **empty development database** and `psql`:

```sh
export DATABASE_URL='postgresql://localhost/rollup_dev'
make install
make demo
```

The portable installer requires permission to create schemas and the `db_ecs_user` role. It applies everything in one transaction, refuses an existing installation, and does not create AWS IAM roles or Flyway history. See [local development](docs/local-development.md) for setup and testing details.

## Create and refresh a rollup

A source must have `timestamp TIMESTAMPTZ NOT NULL`. Register each grouping column as a dimension; dimensions must be `NOT NULL`. Every remaining source column must be a supported numeric metric (`smallint`, `integer`, `bigint`, `numeric`, `real`, or `double precision`). Use a dedicated numeric source table when incoming payloads contain fields you do not want to group by.

```sql
CREATE TABLE raw.readings (
    timestamp timestamptz NOT NULL,
    device text NOT NULL,
    temperature integer,
    power numeric(12,2)
);
CREATE INDEX ON raw.readings (timestamp);

INSERT INTO silver.timeseries_dimension_config (source_table, dimension_column)
VALUES ('raw.readings', 'device');

SELECT silver.create_rollup_table(
    source_table_name := 'raw.readings',
    target_schema := 'silver',
    target_table_name := 'readings_hourly',
    rollup_table_interval := '1 hour',
    look_back_window := '5 minutes',
    processing_window := '1 day'
);

INSERT INTO raw.readings VALUES
    ('2025-01-01 00:05+00', 'sensor-a', 20, 1.00),
    ('2025-01-01 00:35+00', 'sensor-a', 21, 2.00);

SELECT silver.refresh_rollup(
    'silver.readings_hourly', '2025-01-01 00:00+00', '2025-01-01 01:00+00'
);
SELECT timestamp, device, avg_temperature, count_temperature, rollup_count
FROM silver.readings_hourly;
-- avg_temperature = 20.5, count_temperature = 2, rollup_count = 2
```

Refresh accepts complete bucket boundaries in `[start, end)`, rejects unfinished/future buckets, and returns the number of output groups. It replaces the entire requested range atomically, so reruns incorporate corrections and remove groups deleted from the source. Manual refresh does not move the incremental worker's watermark. Choose bounded ranges for large backfills.

## Rollup levels and numeric precision

Every metric produces `min_`, `max_`, `sum_`, `count_`, and `avg_` columns. Min/max retain the source type. Sum and average use PostgreSQL `numeric`; count and `rollup_count` use `bigint`. Metric counts exclude null values, while `rollup_count` counts original observations. An all-null metric has count zero and null sum/average.

```sql
SELECT silver.create_rollup_table(
    'silver.readings_hourly', 'gold', 'readings_daily', '1 day'
);
```

A derived rollup inherits the source rollup's dimensions and metrics. Its interval must be a larger exact multiple of the source interval. Weighted averages use `sum(sum_metric) / sum(count_metric)`, so sparse buckets and nulls retain their correct weights. Incremental children stop at their parent's completed watermark. For manual backfills, refresh parents before children; propagate historical corrections through every affected level.

Dimension membership is frozen when a rollup is created. Editing the registration table changes future rollups; existing targets retain their original grouping.

## Incremental processing and late data

```sql
SELECT silver.perform_rollup();                       -- all eligible configurations
SELECT silver.perform_rollup('raw.readings');          -- source or target filter

UPDATE silver.timeseries_rollup_config
SET refresh_overlap = '2 hours'
WHERE target_table = 'silver.readings_hourly';
```

The first run starts at the earliest source timestamp. Each call processes one aligned, bounded forward window per eligible configuration, including empty windows, and advances its watermark only after success. `look_back_window` is the lateness delay behind the current time. `processing_window` controls batch size and is rounded down to complete buckets, with a minimum of one bucket.

`refresh_overlap` recomputes recent buckets to capture late arrivals, including when already caught up. Its effective size is capped to one processing window in addition to the forward window. Older corrections require `refresh_rollup`. Index the source timestamp to support range scans. Keep worker transactions short; locks last until the caller commits or rolls back.

Bucketing uses fixed UTC durations anchored at Monday, `2000-01-03 00:00:00+00`. Subsecond and pre-epoch timestamps work; weeks start on Monday. Calendar months/years, zero, negative intervals, and infinite timestamps are rejected. A day is 24 hours, independent of daylight saving time.

## Failures, retries, and monitoring

Workers use `FOR UPDATE SKIP LOCKED` to distribute configurations. A failed refresh rolls back its target changes and watermark while retaining an error log and retry state. One failing configuration does not abort the rest of the worker call.

```sql
SELECT * FROM silver.timeseries_operations_monitor;
SELECT * FROM silver.validate_rollup_config();
SELECT * FROM silver.timeseries_error_log ORDER BY error_timestamp DESC LIMIT 20;

SELECT silver.handle_rollup_retries();
-- After correcting the underlying problem, re-enable exhausted retries:
SELECT silver.reset_rollup_retry('silver.readings_hourly');
```

Defaults allow five consecutive failed attempts, with a one-minute initial retry delay and exponential backoff capped at one hour. Both the regular worker and retry handler honor due times and retry limits. Exhausted configurations remain visible as failures until explicitly reset. A successful worker refresh resets its failure count.

The monitor includes recent successes and errors, inactive configurations, lag, and retry exhaustion. A successful zero-row refresh counts as success. Refresh log `records_processed` measures output groups, not source rows. Operation status is transactional: another session cannot observe an uncommitted worker claim through this view; use `pg_stat_activity` and `pg_locks` for live execution.

## Partitions and scheduling

Targets use native range partitioning. Without pg_partman, a default partition accepts all dates; automatic partition rotation and retention are **not** enabled. `retention_period` is metadata in this mode. With pg_partman 5+ installed before target creation, creation registers daily partitions and retention. Historical data may land in its default partition; move it into regular partitions using pg_partman's documented procedures before relying on retention or creating overlapping partitions.

```sql
SELECT * FROM silver.get_partition_stats('silver.readings_hourly');
SELECT * FROM silver.get_detailed_stats('%readings%');
SELECT silver.maintain_timeseries_tables();
```

Maintenance analyzes target tables and calls pg_partman maintenance for registered parents when available. Chunk size recommendations are advisory and do not change existing partition boundaries. Vacuum must be run by PostgreSQL autovacuum or as a standalone command. `avg_query_time` is null because no query timing source is installed; read/write statistics are cumulative counters, not rates.

Optional pg_cron scheduling, executed in the database that hosts the extension:

```sql
SELECT cron.schedule_in_database(
    'rollup-worker', '* * * * *', 'SELECT silver.perform_rollup()', 'rollup'
);
SELECT cron.schedule_in_database(
    'rollup-maintenance', '0 * * * *',
    'SELECT silver.maintain_timeseries_tables()', 'rollup'
);
```

Use the actual application database name and a job owner with the necessary permissions. The worker already handles due retries. Legacy PostgreSQL scheduling migrations contain deployment-specific database names and example jobs; review them before running. The [migration guide](src/main/pgdb/migrations/README.md) describes Flyway and the safe schedule generator.

## Development and verification

```sh
make test             # disposable local PostgreSQL; requires initdb, pg_ctl, psql
make test-docker      # disposable Docker test database
python3 -m unittest discover -s tests -p 'test_*.py' -v
make shell-check
```

`make test` deliberately ignores `DATABASE_URL`. Set `TEST_DATABASE_URL` only to an empty, disposable test database. CI runs database checks on PostgreSQL 14, 16, and 17 and runs the Python generator tests separately. See [engine design](docs/engine-design.md) for transaction guarantees and boundaries.

## Repository layout

- `src/main/pgdb/migrations/foundational/`: historical setup and append-only engine migrations.
- `src/main/pgdb/migrations/postgres/`: deployment-specific scheduling and manifest generator.
- `scripts/`: portable installer, demo launcher, and disposable test runner.
- `examples/quickstart.sql`: runnable example with a late correction.
- `tests/`: SQL integration, concurrent worker, portable setup, and generator tests.
- `docs/`: development, design, and upgrade guidance.

The SQL functions execute with the caller's privileges. `db_ecs_user` receives writer and sequence privileges but does not gain schema-creation privileges through a security-definer function. Use a schema owner to create rollup tables. Existing configuration fields for adaptive sizing and execution-time limits remain for compatibility; the new worker uses bounded deterministic windows. Configure a session/job `statement_timeout` when a wall-clock limit is needed.

Licensed under [MIT](LICENSE). Contributions should add migrations for database changes, include focused regression coverage, and update the examples when behavior changes.
