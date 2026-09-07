\set ON_ERROR_STOP on
BEGIN;
SET TIME ZONE 'UTC';
CREATE FUNCTION pg_temp.assert_true(condition boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF condition IS DISTINCT FROM true THEN RAISE EXCEPTION 'Assertion failed: %', message; END IF; END;
$$;

-- Subsecond, pre-epoch, UTC/week alignment and explicit invalid inputs.
SELECT pg_temp.assert_true(silver.time_bucket('250 milliseconds', '1969-12-31 23:59:59.999+00') = '1969-12-31 23:59:59.750+00', 'negative epoch fractions');
SELECT pg_temp.assert_true(silver.time_bucket('1 week', '2024-03-17 23:00+00') = '2024-03-11 00:00+00', 'Monday UTC weeks');
SET TIME ZONE 'America/New_York';
SELECT pg_temp.assert_true(silver.time_bucket('1 day', '2024-03-10 22:30-04') = '2024-03-11 00:00+00', 'DST does not move UTC buckets');
SET TIME ZONE 'UTC';
DO $$
DECLARE width interval;
BEGIN
    FOREACH width IN ARRAY ARRAY[interval '0', interval '-1 second', interval '1 month'] LOOP
        BEGIN
            PERFORM silver.time_bucket(width, now());
            RAISE EXCEPTION 'Invalid interval accepted';
        EXCEPTION WHEN invalid_parameter_value THEN NULL;
        END;
    END LOOP;
END;
$$;

CREATE TABLE raw.test_readings (
    timestamp timestamptz NOT NULL, site text NOT NULL, device integer NOT NULL,
    value integer, counter bigint, small smallint, decimal_value numeric(12,2), float_value double precision
);
INSERT INTO silver.timeseries_dimension_config(source_table, dimension_column) VALUES
    ('raw.test_readings', 'site'), ('raw.test_readings', 'device');
INSERT INTO raw.test_readings VALUES
    ('2024-01-01 00:00:05+00', 'a', 1, 1, 10000000000, 1, 1.10, 1.5),
    ('2024-01-01 00:00:25+00', 'a', 1, 2, 10000000002, 2, 2.20, 2.5),
    ('2024-01-01 00:00:45+00', 'a', 1, NULL, NULL, NULL, NULL, NULL),
    ('2024-01-01 00:01:15+00', 'a', 1, 10, 10000000004, 3, 3.30, 3.5),
    ('2024-01-01 00:00:15+00', 'b', 2, 7, 4, 4, 4.40, 4.5);
SELECT silver.create_rollup_table('raw.test_readings','silver','test_minute','1 minute','0','30 days','90 seconds');
SELECT pg_temp.assert_true(silver.refresh_rollup('silver.test_minute','2024-01-01 00:00+00','2024-01-01 00:02+00') = 3, 'accurate affected group count');
SELECT pg_temp.assert_true((SELECT avg_value = 1.5 AND count_value = 2 AND rollup_count = 3
    AND avg_counter = 10000000001 AND avg_small = 1.5 AND avg_decimal_value = 1.65 AND avg_float_value = 2
    FROM silver.test_minute WHERE timestamp = '2024-01-01 00:00+00' AND site = 'a'), 'fractional numeric averages, null metric counts and raw counts');
SELECT pg_temp.assert_true((SELECT records_processed FROM silver.timeseries_refresh_log WHERE table_name = 'silver.test_minute' ORDER BY id DESC LIMIT 1) = 3, 'logged output count');

-- Composable state weights by each metric's count, not number of buckets or rows.
SELECT silver.create_rollup_table('silver.test_minute','gold','test_five_minute','5 minutes');
SELECT silver.refresh_rollup('gold.test_five_minute','2024-01-01 00:00+00','2024-01-01 00:05+00');
SELECT pg_temp.assert_true((SELECT min_value = 1 AND max_value = 10 AND sum_value = 13 AND count_value = 3
    AND abs(avg_value - 13::numeric / 3) < 0.00000001 AND rollup_count = 4
    FROM gold.test_five_minute WHERE site = 'a'), 'weighted hierarchy and null handling');
DO $$
BEGIN
    BEGIN
        PERFORM silver.create_rollup_table('silver.test_minute','gold','test_bad_interval','90 seconds');
        RAISE EXCEPTION 'Nonmultiple interval accepted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE 'Child interval must%' THEN RAISE; END IF;
    END;
END;
$$;

-- Full replacement is repeatable and removes groups deleted from source.
SELECT silver.refresh_rollup('silver.test_minute','2024-01-01 00:00+00','2024-01-01 00:02+00');
SELECT pg_temp.assert_true((SELECT count(*) FROM silver.test_minute) = 3, 'idempotent refresh');
DELETE FROM raw.test_readings WHERE site = 'b';
UPDATE raw.test_readings SET value = 3 WHERE value = 2;
SELECT silver.refresh_rollup('silver.test_minute','2024-01-01 00:00+00','2024-01-01 00:02+00');
SELECT pg_temp.assert_true((SELECT count(*) FROM silver.test_minute) = 2, 'deleted group removed');
SELECT pg_temp.assert_true((SELECT avg_value FROM silver.test_minute WHERE timestamp = '2024-01-01 00:00+00') = 2, 'late correction replaces average');
SELECT pg_temp.assert_true((SELECT last_processed_time IS NULL FROM silver.timeseries_rollup_config WHERE target_table = 'silver.test_minute'), 'manual backfill does not advance watermark');
DO $$
BEGIN
    BEGIN
        PERFORM silver.refresh_rollup('silver.test_minute','2024-01-01 00:00:01+00','2024-01-01 00:02+00');
        RAISE EXCEPTION 'Partial bucket accepted';
    EXCEPTION WHEN invalid_parameter_value THEN NULL;
    END;
END;
$$;

-- A failed replacement must roll back its DELETE and preserve previous results.
ALTER TABLE silver.test_minute ADD CONSTRAINT test_nonnegative_average CHECK (avg_value >= 0);
UPDATE raw.test_readings SET value = -10 WHERE value = 1;
DO $$
BEGIN
    BEGIN
        PERFORM silver.refresh_rollup('silver.test_minute','2024-01-01 00:00+00','2024-01-01 00:02+00');
        RAISE EXCEPTION 'Invalid aggregate passed target constraint';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END;
$$;
SELECT pg_temp.assert_true((SELECT count(*) FROM silver.test_minute) = 2
    AND (SELECT avg_value FROM silver.test_minute WHERE timestamp = '2024-01-01 00:00+00') = 2,
    'insert failure rolls back the preceding range deletion');
UPDATE raw.test_readings SET value = 1 WHERE value = -10;
ALTER TABLE silver.test_minute DROP CONSTRAINT test_nonnegative_average;

-- Missing source metadata fails before writing and is visible to the worker.
ALTER TABLE raw.test_readings RENAME COLUMN value TO missing_value;
DO $$
BEGIN
    BEGIN
        PERFORM silver.refresh_rollup('silver.test_minute','2024-01-01 00:00+00','2024-01-01 00:02+00');
        RAISE EXCEPTION 'Missing metric accepted';
    EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL;
    END;
END;
$$;
SELECT pg_temp.assert_true((SELECT count(*) FROM silver.test_minute) = 2, 'failed refresh is atomic');
UPDATE silver.timeseries_rollup_config SET max_retries = 2 WHERE target_table = 'silver.test_minute';
SELECT silver.perform_rollup('raw.test_readings');
SELECT pg_temp.assert_true((SELECT retry_count = 1 AND status = 'error' AND next_retry_time > now()
    AND worker_id IS NULL AND last_processed_time IS NULL FROM silver.timeseries_rollup_config WHERE target_table = 'silver.test_minute'), 'failure persists and schedules retry');
SELECT silver.perform_rollup('raw.test_readings');
SELECT pg_temp.assert_true((SELECT retry_count FROM silver.timeseries_rollup_config WHERE target_table = 'silver.test_minute') = 1, 'normal scheduler honors retry backoff');
UPDATE silver.timeseries_rollup_config SET next_retry_time = now() - interval '1 second' WHERE target_table = 'silver.test_minute';
SELECT silver.handle_rollup_retries();
SELECT pg_temp.assert_true((SELECT retry_count = 2 AND status = 'error' AND next_retry_time IS NULL
    FROM silver.timeseries_rollup_config WHERE target_table = 'silver.test_minute'), 'retry failure remains failed and stops at limit');
SELECT silver.handle_rollup_retries();
SELECT pg_temp.assert_true((SELECT count(*) FROM silver.timeseries_error_log WHERE target_table = 'silver.test_minute') = 2, 'exhausted retries do not rerun');
ALTER TABLE raw.test_readings RENAME COLUMN missing_value TO value;
SELECT silver.reset_rollup_retry('silver.test_minute');
SELECT silver.perform_rollup('raw.test_readings');
SELECT pg_temp.assert_true((SELECT last_processed_time = '2024-01-01 00:01+00' AND retry_count = 0 AND status = 'idle'
    FROM silver.timeseries_rollup_config WHERE target_table = 'silver.test_minute'), 'initial worker starts at earliest data and aligns window');
SELECT silver.perform_rollup('raw.test_readings');
SELECT silver.perform_rollup('raw.test_readings');
SELECT pg_temp.assert_true((SELECT last_processed_time = '2024-01-01 00:03+00' AND last_processed_rows = 0
    FROM silver.timeseries_rollup_config WHERE target_table = 'silver.test_minute'), 'empty windows advance monotonically');

-- No dimensions, unrelated configurations, frozen dimensions and all-null metrics.
CREATE TABLE raw.test_plain(timestamp timestamptz NOT NULL, value numeric);
INSERT INTO raw.test_plain VALUES ('2024-01-01 00:00:01+00', NULL), ('2024-01-01 00:00:02+00', NULL);
SELECT silver.create_rollup_table('raw.test_plain','silver','test_plain_hour','1 hour','0');
SELECT silver.perform_rollup();
SELECT pg_temp.assert_true((SELECT count_value = 0 AND avg_value IS NULL AND sum_value IS NULL AND rollup_count = 2
    FROM silver.test_plain_hour), 'dimensionless and null-only metric rollups');
UPDATE silver.timeseries_dimension_config SET is_active = false WHERE source_table = 'raw.test_readings';
SELECT silver.refresh_rollup('silver.test_minute','2024-01-01 00:00+00','2024-01-01 00:02+00');
SELECT pg_temp.assert_true((SELECT cardinality(dimension_columns) FROM silver.timeseries_rollup_config
    WHERE target_table = 'silver.test_minute') = 2, 'registered metadata is frozen');
SELECT pg_temp.assert_true((SELECT last_processed_time IS NULL FROM silver.timeseries_rollup_config
    WHERE target_table = 'gold.test_five_minute'), 'child waits for a complete parent interval');
SELECT silver.perform_rollup('raw.test_readings');
SELECT silver.perform_rollup('gold.test_five_minute');
SELECT pg_temp.assert_true((SELECT last_processed_time = '2024-01-01 00:05+00'
    FROM silver.timeseries_rollup_config WHERE target_table = 'gold.test_five_minute'), 'child advances after parent completes its interval');
SELECT pg_temp.assert_true((SELECT sum_value = 14 AND count_value = 3 AND rollup_count = 4
    FROM gold.test_five_minute WHERE site = 'a'), 'scheduled hierarchy incorporates corrected parent values');

-- Late data overlap works even when the forward watermark is caught up.
CREATE TABLE raw.test_late(timestamp timestamptz NOT NULL, value integer);
INSERT INTO raw.test_late SELECT silver.time_bucket('1 hour', now()) - interval '30 minutes', 1;
SELECT silver.create_rollup_table('raw.test_late','silver','test_late_hour','1 hour','0');
SELECT silver.perform_rollup('raw.test_late');
INSERT INTO raw.test_late SELECT silver.time_bucket('1 hour', now()) - interval '20 minutes', 3;
UPDATE silver.timeseries_rollup_config SET refresh_overlap = interval '1 hour' WHERE target_table = 'silver.test_late_hour';
SELECT silver.perform_rollup('raw.test_late');
SELECT pg_temp.assert_true((SELECT avg_value = 2 AND rollup_count = 2 FROM silver.test_late_hour), 'overlap catches late arrivals while caught up');

-- Quoted identifiers cannot escape generated SQL and reserved metric names work.
CREATE TABLE raw."Quoted table"(timestamp timestamptz NOT NULL, "device name" text NOT NULL, "select" integer);
INSERT INTO silver.timeseries_dimension_config(source_table, dimension_column) VALUES ('raw."Quoted table"', 'device name');
INSERT INTO raw."Quoted table" VALUES ('2024-01-01+00', 'x', 7);
SELECT silver.create_rollup_table('raw."Quoted table"','silver','Quoted rollup','1 hour');
SELECT silver.refresh_rollup('silver."Quoted rollup"','2024-01-01+00','2024-01-01 01:00+00');
SELECT pg_temp.assert_true((SELECT "avg_select" = 7 AND "device name" = 'x' FROM silver."Quoted rollup"), 'quoted identifiers');

-- Runtime role has the sequence permissions needed for refresh/error logs.
SET LOCAL ROLE db_ecs_user;
SELECT silver.refresh_rollup('silver.test_plain_hour','2024-01-01+00','2024-01-01 01:00+00');
RESET ROLE;
ROLLBACK;
