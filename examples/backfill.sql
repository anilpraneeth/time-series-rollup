\set ON_ERROR_STOP on
\pset null '(null)'
SET TIME ZONE 'UTC';

-- Repeatable development fixture. This file owns only demo_backfill_* tables,
-- their configurations, and their backfill jobs. Use psql autocommit: each
-- run_rollup_backfills SELECT must commit independently.
BEGIN;
DELETE FROM silver.timeseries_backfill_jobs
WHERE target_table IN ('silver.demo_backfill_minute', 'silver.demo_backfill_hour', 'gold.demo_backfill_day');
DELETE FROM silver.timeseries_rollup_config WHERE target_table = 'gold.demo_backfill_day';
DELETE FROM silver.timeseries_rollup_config WHERE target_table = 'silver.demo_backfill_hour';
DELETE FROM silver.timeseries_rollup_config WHERE target_table = 'silver.demo_backfill_minute';
DELETE FROM silver.timeseries_dimension_config WHERE source_table = 'raw.demo_backfill_readings';
DROP TABLE IF EXISTS gold.demo_backfill_day;
DROP TABLE IF EXISTS silver.demo_backfill_hour;
DROP TABLE IF EXISTS silver.demo_backfill_minute;
DROP TABLE IF EXISTS raw.demo_backfill_readings;

CREATE TABLE raw.demo_backfill_readings (
    timestamp timestamptz NOT NULL,
    device text NOT NULL,
    reading numeric,
    PRIMARY KEY (timestamp, device)
);
INSERT INTO silver.timeseries_dimension_config(source_table, dimension_column)
VALUES ('raw.demo_backfill_readings', 'device');
INSERT INTO raw.demo_backfill_readings VALUES
    ('2025-01-01 10:17:00+00', 'sensor-a', 10),
    ('2025-01-01 10:17:30+00', 'sensor-a', 20),
    ('2025-01-01 11:05:00+00', 'sensor-a', 60),
    ('2025-01-01 11:20:00+00', 'sensor-b', 5);

SELECT silver.create_rollup_table(
    'raw.demo_backfill_readings', 'silver', 'demo_backfill_minute', '1 minute',
    processing_window := '12 hours', is_active := false
);
SELECT silver.create_rollup_table(
    'silver.demo_backfill_minute', 'silver', 'demo_backfill_hour', '1 hour',
    processing_window := '1 day', is_active := false
);
SELECT silver.create_rollup_table(
    'silver.demo_backfill_hour', 'gold', 'demo_backfill_day', '1 day',
    processing_window := '1 day', is_active := false
);
SELECT silver.refresh_rollup('silver.demo_backfill_minute', '2025-01-01+00', '2025-01-02+00');
SELECT silver.refresh_rollup('silver.demo_backfill_hour', '2025-01-01+00', '2025-01-02+00');
SELECT silver.refresh_rollup('gold.demo_backfill_day', '2025-01-01+00', '2025-01-02+00');
COMMIT;

-- Initial sensor-a weighted mean is (10 + 20 + 60) / 3 = 30.
SELECT timestamp, device, avg_reading, count_reading FROM gold.demo_backfill_day ORDER BY device;

-- Correct one raw observation and remove a group. Existing rollups stay stale
-- until the backfill replaces their complete buckets.
UPDATE raw.demo_backfill_readings SET reading = 50
WHERE timestamp = '2025-01-01 10:17:30+00' AND device = 'sensor-a';
DELETE FROM raw.demo_backfill_readings WHERE device = 'sensor-b';

-- Daily output is the coarsest desired repair: all three levels will be rebuilt.
-- The nonaligned request widens to the full day at every level.
SELECT * FROM silver.plan_rollup_backfill(
    'gold.demo_backfill_day', '2025-01-01 10:17+00', '2025-01-01 11:42+00'
);
SELECT silver.enqueue_rollup_backfill(
    'gold.demo_backfill_day', '2025-01-01 10:17+00', '2025-01-01 11:42+00'
) AS demo_backfill_job \gset

-- Two minute-level batches, one hourly batch, and one daily batch.
-- Each command commits separately in psql's default autocommit mode.
SELECT silver.run_rollup_backfills(1, :demo_backfill_job);
SELECT id, status, current_target, next_start, progress_percent
FROM silver.timeseries_backfill_monitor WHERE id = :demo_backfill_job;
SELECT silver.run_rollup_backfills(1, :demo_backfill_job);
SELECT silver.run_rollup_backfills(1, :demo_backfill_job);
SELECT silver.run_rollup_backfills(1, :demo_backfill_job);

SELECT id, status, completed_batches, estimated_batches, progress_percent
FROM silver.timeseries_backfill_monitor WHERE id = :demo_backfill_job;
-- sensor-a now has mean 40; the deleted sensor-b group is gone at every level.
SELECT timestamp, device, avg_reading, count_reading FROM gold.demo_backfill_day ORDER BY device;
SELECT target_table, last_processed_time
FROM silver.timeseries_rollup_config
WHERE target_table IN ('silver.demo_backfill_minute', 'silver.demo_backfill_hour', 'gold.demo_backfill_day')
ORDER BY id;
-- All scheduled watermarks remain NULL because only manual backfills ran.

DO $verify$
BEGIN
    IF (SELECT count(*) FROM gold.demo_backfill_day) <> 1
       OR NOT EXISTS (SELECT 1 FROM gold.demo_backfill_day
           WHERE device = 'sensor-a' AND avg_reading = 40 AND count_reading = 3)
       OR EXISTS (SELECT 1 FROM silver.demo_backfill_minute WHERE device = 'sensor-b')
       OR EXISTS (SELECT 1 FROM silver.demo_backfill_hour WHERE device = 'sensor-b')
       OR EXISTS (SELECT 1 FROM silver.timeseries_rollup_config
           WHERE target_table IN ('silver.demo_backfill_minute', 'silver.demo_backfill_hour', 'gold.demo_backfill_day')
             AND last_processed_time IS NOT NULL)
       OR NOT EXISTS (SELECT 1 FROM silver.timeseries_backfill_monitor
           WHERE target_table = 'gold.demo_backfill_day' AND status = 'completed'
             AND completed_batches = 4 AND progress_percent = 100) THEN
        RAISE EXCEPTION 'Backfill example did not preserve expected values and progress';
    END IF;
END;
$verify$;
