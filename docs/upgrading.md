# Upgrading an existing installation

V11 and V12 preserve the original V1–V10 migration files and add new definitions. This is a behavior-changing engine upgrade, not an automatic conversion of historical aggregates. V13 and V14 add historical backfill planning and durable jobs without changing existing tables or worker behavior.

## From V12 to V14

Existing engine-version-2 targets do not need rebuilding. For a Flyway-managed installation, apply V13 and V14 using the existing foundational migration configuration and history. For a directly SQL-managed installation already at V12, apply the new migrations once:

```sh
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 --single-transaction \
  -f src/main/pgdb/migrations/foundational/timeseries/V13__backfill_planning.sql \
  -f src/main/pgdb/migrations/foundational/timeseries/V14__resumable_backfill_jobs.sql
```

The new functions run with caller privileges. The migration grants `db_ecs_user` access to the new job tables, identity sequence, view, and functions. Existing data, logs, watermarks, retry state, and monitoring consumers remain intact. Backfill execution is opt-in: call or schedule `silver.run_rollup_backfills`, which is separate from the incremental worker. See [historical backfills](backfills.md) for planning and recovery.

The remaining sections apply to upgrading the historical V1–V10 engine.

## Before applying migrations

1. Back up the database and test the upgrade on a copy.
2. Pause worker and maintenance schedules. Confirm no worker transactions remain open.
3. Verify PostgreSQL 14+; automatic partition registration requires pg_partman 5+.
4. Reconcile duplicate target configurations. V11 enforces one configuration per target:

   ```sql
   SELECT target_table, count(*)
   FROM silver.timeseries_rollup_config
   GROUP BY target_table HAVING count(*) > 1;
   ```

5. Check your use of `silver.time_bucket`. Its new definition uses fixed UTC buckets with a common Monday origin; calendar months/years are rejected. Rebuild dependent stored aggregates where bucket semantics change.

## Apply using the existing migration system

For a Flyway-managed installation, keep its existing history table and credentials. From the repository root:

```sh
flyway -configFiles=src/main/pgdb/flyway-foundational.conf validate
flyway -configFiles=src/main/pgdb/flyway-foundational.conf migrate
```

Set `FLYWAY_URL`, `FLYWAY_USER`, and `FLYWAY_PASSWORD` for the intended database. Do not use `repair` to hide checksum differences. The portable installer is for empty databases and deliberately refuses upgrades; it does not create Flyway history.

For an installation managed directly with SQL that already has V1–V10, apply each new migration once, recording the version in your existing deployment process:

```sh
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 --single-transaction \
  -f src/main/pgdb/migrations/foundational/timeseries/V11__reliable_rollup_engine.sql \
  -f src/main/pgdb/migrations/foundational/timeseries/V12__timeseries_operations.sql \
  -f src/main/pgdb/migrations/foundational/timeseries/V13__backfill_planning.sql \
  -f src/main/pgdb/migrations/foundational/timeseries/V14__resumable_backfill_jobs.sql
```

Fresh portable installs already include these versions; never rerun them there.

## Rebuild legacy targets alongside existing tables

Existing configurations receive `engine_version = 1`. Their tables and data remain intact. The new worker will log an actionable error for them instead of attempting to treat their old rows as composable state. Deactivate old configurations while rebuilding:

```sql
UPDATE silver.timeseries_rollup_config
SET is_active = false
WHERE engine_version = 1;
```

Create new targets under new names with `silver.create_rollup_table`. Numeric statistics now retain sum and non-null count, and integer averages use `numeric`. Existing rounded averages cannot supply missing precision. Backfill from retained original source observations using bounded, complete-bucket calls to `silver.refresh_rollup`.

New raw sources require `timestamp TIMESTAMPTZ NOT NULL`, non-null configured dimensions, and supported numeric metrics for every remaining column. The legacy mode/text/JSON array aggregation behavior is not carried forward. Decide which nonnumeric fields are dimensions or populate a dedicated numeric source table. Derived rollups inherit their parent's dimensions and numeric state automatically.

Recreate rollup chains from finest to coarsest. Validate target results against raw observations, switch consumers to the new tables, then re-enable schedules. Manual refresh does not change the worker watermark: allow incremental catch-up or deliberately set `last_processed_time` to an exclusive bucket boundary **only after independently verifying every preceding bucket has been populated**. The default first worker run starts at the earliest retained source timestamp.

No old target is dropped by the migrations. Removing old data/configurations is an operator decision after verification and consumer cutover. If original observations have already expired, exact reconstruction may be impossible; retain the legacy tables as historical data rather than inventing numeric state.

## Operational differences

- `look_back_window` means a lateness delay, not initial history depth.
- Empty windows advance progress; new source data older than the watermark requires overlap or explicit refresh.
- Work is distributed by locked configuration rows; table writes, logs, and watermark commit together.
- Retry failures remain recorded, regular runs honor backoff, and exhausted jobs require an explicit reset.
- The monitor's success rate includes zero-row successes and recent error log entries. Historical error records may include events beyond worker attempts, so interpret the rate as logged outcomes.
- `processing_window` controls deterministic batches. Adaptive/max-execution fields retained from V6 are not enforced by this engine.
- Portable default partitions do not enforce retention. Existing pg_partman partition registrations are retained.
