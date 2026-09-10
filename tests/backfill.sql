\set ON_ERROR_STOP on
BEGIN;
SET TIME ZONE 'UTC';

CREATE FUNCTION pg_temp.assert_true(condition boolean, message text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF condition IS DISTINCT FROM true THEN RAISE EXCEPTION 'Assertion failed: %', message; END IF;
END;
$$;

CREATE FUNCTION pg_temp.assert_raises(command text, expected_state text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE observed_state text;
BEGIN
    BEGIN
        EXECUTE command;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS observed_state = RETURNED_SQLSTATE;
        IF observed_state <> expected_state THEN RAISE; END IF;
        RETURN;
    END;
    RAISE EXCEPTION 'Expected SQLSTATE % for: %', expected_state, command;
END;
$$;

CREATE SCHEMA backfill_test;
CREATE TABLE backfill_test.readings (
    timestamp timestamptz NOT NULL, sensor text NOT NULL, value numeric, temperature numeric
);
INSERT INTO silver.timeseries_dimension_config (source_table, dimension_column)
VALUES ('backfill_test.readings', 'sensor');
INSERT INTO backfill_test.readings VALUES
    ('2024-01-01 00:00:05+00', 'a', 1, NULL),
    ('2024-01-01 00:00:25+00', 'a', 3, 10),
    ('2024-01-01 00:01:15+00', 'a', 10, 30),
    ('2024-01-01 12:01:15+00', 'a', 100, NULL),
    ('2024-01-01 23:55:15+00', 'a', NULL, 90),
    ('2024-01-01 02:00:00+00', 'deleted', 7, 70),
    ('2024-01-01 15:00:00+00', 'nulls', NULL, NULL),
    ('2024-01-02 01:00:00+00', 'outside', 999, 999);

SELECT silver.create_rollup_table('backfill_test.readings', 'backfill_test', 'minute', '1 minute', '0', '30 days', '12 hours');
SELECT silver.create_rollup_table('backfill_test.minute', 'backfill_test', 'hour', '1 hour', '0', '30 days', '1 day');
SELECT silver.create_rollup_table('backfill_test.hour', 'backfill_test', 'day', '1 day', '0', '30 days', '1 day');
SELECT silver.create_rollup_table('backfill_test.minute', 'backfill_test', 'sibling', '5 minutes');
SELECT silver.create_rollup_table('backfill_test.day', 'backfill_test', 'descendant', '1 week');

-- Historical repair must not disturb any scheduler's forward progress.
UPDATE silver.timeseries_rollup_config
SET last_processed_time = '2025-01-01 00:00:00+00'::timestamptz + id * interval '1 day'
WHERE target_table LIKE 'backfill_test.%';
CREATE TEMP TABLE saved_watermarks AS
SELECT id, last_processed_time FROM silver.timeseries_rollup_config
WHERE target_table LIKE 'backfill_test.%';

-- A partial-day request covers the whole selected day at every ancestor.
-- Sparse data never shrinks the requested coverage or changes batch estimates.
CREATE TEMP TABLE planned_steps AS
SELECT * FROM silver.plan_rollup_backfill('backfill_test.day', '2024-01-01 00:14:23+00', '2024-01-01 23:02:17+00');
SELECT pg_temp.assert_true(
    (SELECT array_agg(target_table ORDER BY step_order) FROM planned_steps)
        = ARRAY['backfill_test.minute', 'backfill_test.hour', 'backfill_test.day']
    AND (SELECT array_agg(step_order ORDER BY step_order) FROM planned_steps) = ARRAY[1, 2, 3],
    'planner orders only the requested target and its ancestors');
SELECT pg_temp.assert_true(
    (SELECT bool_and(range_start = '2024-01-01 00:00:00+00' AND range_end = '2024-01-02 00:00:00+00') FROM planned_steps)
    AND (SELECT array_agg(estimated_batches ORDER BY step_order) FROM planned_steps) = ARRAY[2, 1, 1]::bigint[]
    AND (SELECT array_agg(batch_interval ORDER BY step_order) FROM planned_steps) = ARRAY[interval '12 hours', interval '1 day', interval '1 day']
    AND NOT EXISTS (SELECT 1 FROM backfill_test.minute),
    'planning is read-only and estimates every complete batch');

DO $test$
DECLARE invalid_range record;
BEGIN
    FOR invalid_range IN
        SELECT * FROM (VALUES
            (NULL::timestamptz, '2024-01-02+00'::timestamptz),
            ('2024-01-01+00'::timestamptz, NULL::timestamptz),
            ('-infinity'::timestamptz, '2024-01-02+00'::timestamptz),
            ('2024-01-01+00'::timestamptz, 'infinity'::timestamptz),
            ('2024-01-02+00'::timestamptz, '2024-01-01+00'::timestamptz),
            ('2024-01-01+00'::timestamptz, '2024-01-01+00'::timestamptz),
            (silver.time_bucket('1 day', now()), now() + interval '1 second')
        ) AS invalid_ranges(start_at, end_at)
    LOOP
        BEGIN
            PERFORM silver.plan_rollup_backfill('backfill_test.day', invalid_range.start_at, invalid_range.end_at);
            RAISE EXCEPTION 'Invalid backfill range accepted: %', invalid_range;
        EXCEPTION WHEN invalid_parameter_value THEN NULL;
        END;
    END LOOP;
END;
$test$;
SELECT pg_temp.assert_raises($sql$SELECT silver.plan_rollup_backfill(NULL, '2024-01-01+00', '2024-01-02+00')$sql$, '22023');
SELECT pg_temp.assert_raises($sql$SELECT silver.plan_rollup_backfill('backfill_test.missing', '2024-01-01+00', '2024-01-02+00')$sql$, '22023');

-- Batch windows round down to whole buckets, with a one-bucket minimum.
UPDATE silver.timeseries_rollup_config SET processing_window = interval '90 seconds', is_active = false
WHERE target_table = 'backfill_test.minute';
SELECT pg_temp.assert_true(
    (SELECT batch_interval = interval '1 minute' AND estimated_batches = 3
     FROM silver.plan_rollup_backfill('backfill_test.minute', '2024-01-01 00:00:01+00', '2024-01-01 00:02:10+00'))
    AND (SELECT count(*) = 3 FROM silver.plan_rollup_backfill('backfill_test.day', '2024-01-01+00', '2024-01-02+00')),
    'planner rounds processing windows and includes inactive ancestors');
UPDATE silver.timeseries_rollup_config SET processing_window = interval '30 seconds' WHERE target_table = 'backfill_test.minute';
SELECT pg_temp.assert_true(
    (SELECT batch_interval = interval '1 minute' FROM silver.plan_rollup_backfill('backfill_test.minute', '2024-01-01+00', '2024-01-01 00:01+00')),
    'processing windows smaller than a bucket still make forward progress');
UPDATE silver.timeseries_rollup_config SET processing_window = interval '12 hours', is_active = true WHERE target_table = 'backfill_test.minute';

-- Reject damaged dependency metadata and aggregate schemas before enqueueing.
DO $test$
BEGIN
    BEGIN
        UPDATE silver.timeseries_rollup_config
        SET source_table = 'backfill_test.day',
            source_rollup_id = (SELECT id FROM silver.timeseries_rollup_config WHERE target_table = 'backfill_test.day')
        WHERE target_table = 'backfill_test.minute';
        PERFORM silver.plan_rollup_backfill('backfill_test.day', '2024-01-01+00', '2024-01-02+00');
        RAISE EXCEPTION 'Dependency cycle was accepted';
    EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL;
    END;
    BEGIN
        UPDATE silver.timeseries_rollup_config SET source_rollup_id = NULL WHERE target_table = 'backfill_test.hour';
        PERFORM silver.plan_rollup_backfill('backfill_test.day', '2024-01-01+00', '2024-01-02+00');
        RAISE EXCEPTION 'A managed source with missing lineage was accepted';
    EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL;
    END;
    BEGIN
        UPDATE silver.timeseries_rollup_config SET processing_window = interval '1 month' WHERE target_table = 'backfill_test.minute';
        PERFORM silver.plan_rollup_backfill('backfill_test.day', '2024-01-01+00', '2024-01-02+00');
        RAISE EXCEPTION 'Calendar-month processing window was accepted';
    EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL;
    END;
    BEGIN
        ALTER TABLE backfill_test.day ALTER COLUMN avg_value TYPE numeric(10,2);
        PERFORM silver.enqueue_rollup_backfill('backfill_test.day', '2024-01-01+00', '2024-01-02+00');
        RAISE EXCEPTION 'Target precision drift was accepted';
    EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL;
    END;
END;
$test$;

SELECT silver.enqueue_rollup_backfill('backfill_test.day', '2024-01-01 00:14:23+00', '2024-01-01 23:02:17+00') AS initial_job \gset
SELECT pg_temp.assert_true(
    (SELECT status = 'queued' AND requested_start = '2024-01-01 00:14:23+00'
        AND requested_end = '2024-01-01 23:02:17+00' AND created_at IS NOT NULL AND completed_at IS NULL
     FROM silver.timeseries_backfill_jobs WHERE id = :initial_job)
    AND (SELECT count(*) = 3 AND bool_and(next_start = range_start AND completed_batches = 0
        AND records_processed = 0 AND config_snapshot IS NOT NULL)
     FROM silver.timeseries_backfill_steps WHERE job_id = :initial_job),
    'enqueue persists the request, immutable plan and initial cursors');
SELECT pg_temp.assert_true(silver.run_rollup_backfills(1, :initial_job) = 1, 'worker honors one-batch budget');
SELECT pg_temp.assert_true(
    (SELECT completed_batches = 1 AND next_start = '2024-01-01 12:00:00+00' AND records_processed = 3
     FROM silver.timeseries_backfill_steps WHERE job_id = :initial_job AND step_order = 1)
    AND NOT EXISTS (SELECT 1 FROM backfill_test.hour)
    AND NOT EXISTS (SELECT 1 FROM backfill_test.day),
    'child stages wait for every ancestor batch');
SELECT pg_temp.assert_true(
    (SELECT status = 'running' AND completed_batches = 1 AND estimated_batches = 4 AND progress_percent = 25
        AND records_processed = 3 AND current_target = 'backfill_test.minute'
        AND next_start = '2024-01-01 12:00:00+00'
        AND range_start = '2024-01-01 00:00:00+00' AND range_end = '2024-01-02 00:00:00+00'
     FROM silver.timeseries_backfill_monitor WHERE id = :initial_job),
    'monitor exposes aggregate progress and the earliest unfinished dependency');
SELECT pg_temp.assert_true(silver.run_rollup_backfills(2, :initial_job) = 2, 'worker can cross a stage boundary within its budget');
SELECT pg_temp.assert_true(
    (SELECT sum(completed_batches) = 3 FROM silver.timeseries_backfill_steps WHERE job_id = :initial_job)
    AND EXISTS (SELECT 1 FROM backfill_test.hour) AND NOT EXISTS (SELECT 1 FROM backfill_test.day),
    'two more batches finish minute and hour but leave day pending');
SELECT pg_temp.assert_true(silver.run_rollup_backfills(specific_job => :initial_job) = 1, 'default budget completes one batch');
SELECT pg_temp.assert_true(
    (SELECT status = 'completed' AND completed_at IS NOT NULL AND last_error IS NULL AND sql_state IS NULL
     FROM silver.timeseries_backfill_jobs WHERE id = :initial_job)
    AND (SELECT sum(completed_batches) = 4 AND sum(records_processed) = 14 AND bool_and(next_start = range_end)
     FROM silver.timeseries_backfill_steps WHERE job_id = :initial_job)
    AND silver.run_rollup_backfills(10, :initial_job) = 0,
    'completion is durable and completed jobs are not repeated');
SELECT pg_temp.assert_true(
    (SELECT status = 'completed' AND completed_batches = 4 AND estimated_batches = 4 AND progress_percent = 100
        AND records_processed = 14 AND current_target IS NULL AND next_start IS NULL
     FROM silver.timeseries_backfill_monitor WHERE id = :initial_job),
    'completed monitor totals match the persisted steps');
SELECT pg_temp.assert_true(
    (SELECT min_value = 1 AND max_value = 100 AND sum_value = 114 AND count_value = 4 AND avg_value = 28.5
        AND min_temperature = 10 AND max_temperature = 90 AND sum_temperature = 130 AND count_temperature = 3
        AND abs(avg_temperature - 130::numeric / 3) < 0.00000001 AND rollup_count = 5
     FROM backfill_test.day WHERE sensor = 'a')
    AND (SELECT count_value = 0 AND sum_value IS NULL AND avg_value IS NULL
        AND count_temperature = 0 AND avg_temperature IS NULL AND rollup_count = 1
     FROM backfill_test.day WHERE sensor = 'nulls')
    AND NOT EXISTS (SELECT 1 FROM backfill_test.day WHERE sensor = 'outside')
    AND NOT EXISTS (SELECT 1 FROM backfill_test.sibling)
    AND NOT EXISTS (SELECT 1 FROM backfill_test.descendant),
    'three levels preserve metric-specific weights, nulls, dimensions and requested coverage');

-- Repairing the highest target propagates both corrected values and deletions.
UPDATE backfill_test.readings SET value = 9 WHERE sensor = 'a' AND value = 3;
DELETE FROM backfill_test.readings WHERE sensor = 'deleted';
SELECT silver.enqueue_rollup_backfill('backfill_test.day', '2024-01-01 12:00:00+00', '2024-01-01 12:00:01+00') AS repair_job \gset
SELECT pg_temp.assert_true(silver.run_rollup_backfills(100, :repair_job) = 4, 'single highest-target repair executes every ancestor');
SELECT pg_temp.assert_true(
    (SELECT sum_value = 120 AND count_value = 4 AND avg_value = 30 AND rollup_count = 5 FROM backfill_test.day WHERE sensor = 'a')
    AND NOT EXISTS (SELECT 1 FROM backfill_test.minute WHERE sensor = 'deleted')
    AND NOT EXISTS (SELECT 1 FROM backfill_test.hour WHERE sensor = 'deleted')
    AND NOT EXISTS (SELECT 1 FROM backfill_test.day WHERE sensor = 'deleted'),
    'replacement removes deleted groups and propagates corrections through the chain');

SELECT silver.enqueue_rollup_backfill('backfill_test.day', '2024-01-03+00', '2024-01-04+00') AS empty_job \gset
SELECT pg_temp.assert_true(silver.run_rollup_backfills(10, :empty_job) = 4, 'empty source windows still execute all four batches');
SELECT pg_temp.assert_true(
    (SELECT status = 'completed' AND progress_percent = 100 AND records_processed = 0
     FROM silver.timeseries_backfill_monitor WHERE id = :empty_job)
    AND (SELECT sum_value = 120 FROM backfill_test.day WHERE sensor = 'a'),
    'empty batches advance progress without changing data outside their range');

-- A later failed batch retains earlier successes and its own old target rows.
-- The following queued job proves failed attempts also consume the call budget.
ALTER TABLE backfill_test.minute ADD CONSTRAINT backfill_nonnegative CHECK (min_value >= 0);
UPDATE backfill_test.readings SET value = 2 WHERE sensor = 'a' AND value = 1;
UPDATE backfill_test.readings SET value = -100 WHERE sensor = 'a' AND value = 100;
SELECT count(*) AS logs_before_failure FROM silver.timeseries_refresh_log \gset
SELECT silver.enqueue_rollup_backfill('backfill_test.day', '2024-01-01+00', '2024-01-02+00') AS failed_job \gset
SELECT silver.enqueue_rollup_backfill('backfill_test.day', '2024-01-01+00', '2024-01-02+00') AS later_job \gset
SELECT pg_temp.assert_true(silver.run_rollup_backfills(2) = 1, 'failed attempts consume budget but are not returned as successes');
SELECT pg_temp.assert_true(
    (SELECT status = 'failed' AND sql_state = '23514' AND last_error LIKE '%backfill_nonnegative%'
     FROM silver.timeseries_backfill_jobs WHERE id = :failed_job)
    AND (SELECT status = 'queued' FROM silver.timeseries_backfill_jobs WHERE id = :later_job)
    AND (SELECT completed_batches = 1 AND next_start = '2024-01-01 12:00:00+00'
     FROM silver.timeseries_backfill_steps WHERE job_id = :failed_job AND step_order = 1)
    AND (SELECT count(*) = :logs_before_failure + 1 FROM silver.timeseries_refresh_log)
    AND (SELECT min_value = 2 AND sum_value = 11 FROM backfill_test.minute WHERE timestamp = '2024-01-01 00:00:00+00' AND sensor = 'a')
    AND (SELECT min_value = 100 FROM backfill_test.minute WHERE timestamp = '2024-01-01 12:01:00+00' AND sensor = 'a')
    AND (SELECT sum_value = 120 FROM backfill_test.day WHERE sensor = 'a'),
    'failed batch rolls back replacement and logs while preserving previous batches and child data');
SELECT pg_temp.assert_true(silver.run_rollup_backfills(10, :failed_job) = 0, 'failed jobs require an explicit resume');
SELECT silver.cancel_rollup_backfill(:later_job);
SELECT silver.cancel_rollup_backfill(:later_job);
SELECT pg_temp.assert_true(
    (SELECT status = 'cancelled' FROM silver.timeseries_backfill_jobs WHERE id = :later_job)
    AND silver.run_rollup_backfills(10, :later_job) = 0,
    'cancellation is idempotent and prevents future work');
UPDATE backfill_test.readings SET value = 200 WHERE sensor = 'a' AND value = -100;
SELECT silver.resume_rollup_backfill(:failed_job);
SELECT pg_temp.assert_true(
    (SELECT status = 'queued' FROM silver.timeseries_backfill_jobs WHERE id = :failed_job)
    AND (SELECT completed_batches = 1 AND next_start = '2024-01-01 12:00:00+00'
     FROM silver.timeseries_backfill_steps WHERE job_id = :failed_job AND step_order = 1),
    'resume keeps the successful cursor');
SELECT pg_temp.assert_true(silver.run_rollup_backfills(10, :failed_job) = 3, 'resume executes only the three remaining batches');
SELECT pg_temp.assert_true(
    (SELECT sum_value = 221 AND count_value = 4 AND avg_value = 55.25 AND rollup_count = 5 FROM backfill_test.day WHERE sensor = 'a')
    AND (SELECT status = 'completed' AND last_error IS NULL AND sql_state IS NULL FROM silver.timeseries_backfill_jobs WHERE id = :failed_job)
    AND (SELECT count(*) = :logs_before_failure + 4 FROM silver.timeseries_refresh_log),
    'resumed chain produces corrected results without repeating earlier batches');

-- A valid but changed configuration cannot silently rewrite a persisted plan.
CREATE TABLE backfill_test.replacement_readings (LIKE backfill_test.readings INCLUDING ALL);
SELECT silver.enqueue_rollup_backfill('backfill_test.day', '2024-01-01+00', '2024-01-02+00') AS drift_job \gset
UPDATE silver.timeseries_rollup_config SET source_table = 'backfill_test.replacement_readings' WHERE target_table = 'backfill_test.minute';
SELECT pg_temp.assert_true(
    (SELECT is_valid FROM silver._validate_rollup_config('backfill_test.minute')),
    'replacement source has a valid schema so snapshot comparison must detect the change');
SELECT pg_temp.assert_true(silver.run_rollup_backfills(10, :drift_job) = 0, 'configuration drift stops work');
SELECT pg_temp.assert_true(
    (SELECT status = 'failed' AND sql_state = '55000' AND last_error IS NOT NULL FROM silver.timeseries_backfill_jobs WHERE id = :drift_job)
    AND (SELECT sum(completed_batches) = 0 AND bool_and(next_start = range_start) FROM silver.timeseries_backfill_steps WHERE job_id = :drift_job),
    'snapshot mismatch is diagnosed without advancing any cursor');
UPDATE silver.timeseries_rollup_config SET source_table = 'backfill_test.readings' WHERE target_table = 'backfill_test.minute';
SELECT silver.resume_rollup_backfill(:drift_job);
SELECT pg_temp.assert_true(silver.run_rollup_backfills(10, :drift_job) = 4, 'restoring the snapshot makes a failed plan resumable');

-- Quoted names are safe throughout planning and execution. A replacement
-- source with the same name and shape is still a different relation.
CREATE TABLE backfill_test."Sensor; readings" (timestamp timestamptz NOT NULL, "device name" text NOT NULL, "select" integer);
INSERT INTO silver.timeseries_dimension_config (source_table, dimension_column)
VALUES ('backfill_test."Sensor; readings"', 'device name');
INSERT INTO backfill_test."Sensor; readings" VALUES ('2024-01-01 00:00:10+00', 'quoted', 7);
SELECT silver.create_rollup_table('backfill_test."Sensor; readings"', 'backfill_test', 'Minute; history', '1 minute');
SELECT silver.enqueue_rollup_backfill('backfill_test."Minute; history"', '2024-01-01 00:00:01+00', '2024-01-01 00:00:30+00') AS quoted_job \gset
ALTER TABLE backfill_test."Sensor; readings" RENAME TO original_quoted_readings;
CREATE TABLE backfill_test."Sensor; readings" (LIKE backfill_test.original_quoted_readings INCLUDING ALL);
SELECT pg_temp.assert_true(silver.run_rollup_backfills(1, :quoted_job) = 0, 'same-name relation replacement is rejected');
SELECT pg_temp.assert_true(
    (SELECT status = 'failed' AND sql_state = '55000' FROM silver.timeseries_backfill_jobs WHERE id = :quoted_job)
    AND NOT EXISTS (SELECT 1 FROM backfill_test."Minute; history"),
    'relation identity belongs to the configuration snapshot');
DROP TABLE backfill_test."Sensor; readings";
ALTER TABLE backfill_test.original_quoted_readings RENAME TO "Sensor; readings";
SELECT silver.resume_rollup_backfill(:quoted_job);
SELECT pg_temp.assert_true(silver.run_rollup_backfills(1, :quoted_job) = 1, 'quoted relation plan can resume after identity is restored');
SELECT pg_temp.assert_true(
    (SELECT "device name" = 'quoted' AND avg_select = 7 AND count_select = 1 AND rollup_count = 1 FROM backfill_test."Minute; history"),
    'quoted dimensions and reserved-word metrics retain correct aggregates');

-- Fractional batches preserve pre-epoch boundaries and their frozen policy
-- across session timezone and interval rendering changes.
CREATE TABLE backfill_test.fractional_readings (timestamp timestamptz NOT NULL, value numeric);
INSERT INTO backfill_test.fractional_readings VALUES
    ('1969-12-31 23:59:59.100+00', 1),
    ('1969-12-31 23:59:59.300+00', 3),
    ('1969-12-31 23:59:59.999+00', 10),
    ('1970-01-01 00:00:00.050+00', 999);
SELECT silver.create_rollup_table('backfill_test.fractional_readings', 'backfill_test', 'quarter_second', '250 milliseconds', '0', '30 days', '700 milliseconds');
SELECT silver.create_rollup_table('backfill_test.quarter_second', 'backfill_test', 'second', '1 second', '0', '30 days', '1700 milliseconds');
SET TIME ZONE 'America/New_York';
SET intervalstyle = 'iso_8601';
SELECT pg_temp.assert_true(
    (SELECT bool_and(range_start = '1969-12-31 23:59:59+00' AND range_end = '1970-01-01 00:00:00+00')
        AND array_agg(batch_interval ORDER BY step_order) = ARRAY[interval '500 milliseconds', interval '1 second']
        AND array_agg(estimated_batches ORDER BY step_order) = ARRAY[2, 1]::bigint[]
     FROM silver.plan_rollup_backfill('backfill_test.second', '1969-12-31 23:59:59.125+00', '1969-12-31 23:59:59.875+00')),
    'pre-epoch planning widens to complete seconds and rounds 700ms processing to 500ms');
SELECT pg_temp.assert_true(
    (SELECT bool_and(range_start = '2024-03-10 00:00:00+00' AND range_end = '2024-03-11 00:00:00+00'
        AND extract(epoch FROM range_end - range_start) = 86400)
     FROM silver.plan_rollup_backfill('backfill_test.day', '2024-03-10 01:30:00-05', '2024-03-10 03:30:00-04')),
    'DST transitions do not move UTC day boundaries or shorten backfill coverage');
SELECT silver.enqueue_rollup_backfill('backfill_test.second', '1969-12-31 23:59:59.125+00', '1969-12-31 23:59:59.875+00') AS fractional_job \gset
CREATE TEMP TABLE saved_fractional_snapshot AS
SELECT silver._backfill_config_snapshot(id) AS snapshot
FROM silver.timeseries_rollup_config WHERE target_table = 'backfill_test.quarter_second';
UPDATE silver.timeseries_rollup_config SET processing_window = interval '250 milliseconds'
WHERE target_table = 'backfill_test.quarter_second';
SET TIME ZONE 'Pacific/Auckland';
SET intervalstyle = 'sql_standard';
SELECT pg_temp.assert_true(
    (SELECT sum(estimated_batches) = 5 FROM silver.plan_rollup_backfill('backfill_test.second', '1969-12-31 23:59:59.125+00', '1969-12-31 23:59:59.875+00'))
    AND (SELECT sum(estimated_batches) = 3 FROM silver.timeseries_backfill_steps WHERE job_id = :fractional_job)
    AND (SELECT silver._backfill_config_snapshot(id) = (SELECT snapshot FROM saved_fractional_snapshot)
        FROM silver.timeseries_rollup_config WHERE target_table = 'backfill_test.quarter_second'),
    'new processing policy affects new plans while queued estimates and semantic snapshots stay stable');
SELECT pg_temp.assert_true(silver.run_rollup_backfills(1, :fractional_job) = 1, 'fractional job executes one frozen batch');
SELECT pg_temp.assert_true(
    (SELECT next_start = '1969-12-31 23:59:59.500+00' AND completed_batches = 1
        AND batch_interval = interval '500 milliseconds' AND records_processed = 2
     FROM silver.timeseries_backfill_steps WHERE job_id = :fractional_job AND step_order = 1),
    'frozen 500ms batch survives a later 250ms processing policy');
SELECT pg_temp.assert_true(silver.run_rollup_backfills(10, :fractional_job) = 2, 'fractional job resumes at its exact subsecond cursor');
SELECT pg_temp.assert_true(
    (SELECT timestamp = '1969-12-31 23:59:59+00' AND sum_value = 14 AND count_value = 3
        AND abs(avg_value - 14::numeric / 3) < 0.00000001 AND rollup_count = 3 FROM backfill_test.second)
    AND (SELECT count(*) = 1 FROM backfill_test.second)
    AND (SELECT bool_and(last_processed_time IS NULL) FROM silver.timeseries_rollup_config
        WHERE target_table IN ('backfill_test.quarter_second', 'backfill_test.second')),
    'subsecond history is aggregated exactly once without moving watermarks');
SET TIME ZONE 'UTC';
SET intervalstyle = 'postgres';

SELECT pg_temp.assert_raises('SELECT silver.run_rollup_backfills(0)', '22023');
SELECT pg_temp.assert_raises('SELECT silver.run_rollup_backfills(-1)', '22023');
SELECT pg_temp.assert_raises('SELECT silver.run_rollup_backfills(NULL)', '22023');
SELECT pg_temp.assert_raises('SELECT silver.run_rollup_backfills(1, -1)', '22023');
SELECT pg_temp.assert_raises('SELECT silver.resume_rollup_backfill(-1)', '22023');
SELECT pg_temp.assert_raises('SELECT silver.resume_rollup_backfill(NULL)', '22023');
SELECT pg_temp.assert_raises('SELECT silver.cancel_rollup_backfill(-1)', '22023');
SELECT pg_temp.assert_raises('SELECT silver.cancel_rollup_backfill(NULL)', '22023');
SELECT pg_temp.assert_raises(format('SELECT silver.resume_rollup_backfill(%s)', :initial_job), '55000');
SELECT pg_temp.assert_raises(format('SELECT silver.cancel_rollup_backfill(%s)', :initial_job), '55000');
SELECT pg_temp.assert_raises(format('SELECT silver.resume_rollup_backfill(%s)', :later_job), '55000');

SELECT pg_temp.assert_true(
    NOT EXISTS (SELECT 1 FROM saved_watermarks saved
        JOIN silver.timeseries_rollup_config current_config USING (id)
        WHERE current_config.last_processed_time IS DISTINCT FROM saved.last_processed_time),
    'planning, successful repair, failures and resume preserve incremental watermarks');

-- Production's runtime role can create jobs, update cursors and write logs.
GRANT USAGE ON SCHEMA backfill_test TO db_ecs_user;
GRANT SELECT ON backfill_test."Sensor; readings" TO db_ecs_user;
SET LOCAL ROLE db_ecs_user;
SELECT silver.enqueue_rollup_backfill('backfill_test."Minute; history"', '2024-01-01 00:00:01+00', '2024-01-01 00:00:30+00') AS runtime_job \gset
SELECT pg_temp.assert_true(silver.run_rollup_backfills(1, :runtime_job) = 1, 'runtime role can execute the backfill lifecycle');
RESET ROLE;

ROLLBACK;
