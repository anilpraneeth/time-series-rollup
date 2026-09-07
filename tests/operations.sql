\set ON_ERROR_STOP on
BEGIN;

-- Real catalog membership must win over naming conventions, including nested
-- partitions and ordinary tables whose names resemble a partition prefix.
CREATE SCHEMA operations_test;
CREATE TABLE operations_test."Odd Parent" (timestamp timestamptz NOT NULL, value numeric)
    PARTITION BY RANGE (timestamp);
CREATE TABLE operations_test.first_branch PARTITION OF operations_test."Odd Parent"
    FOR VALUES FROM ('2020-01-01 00:00:00+00') TO ('2021-01-01 00:00:00+00')
    PARTITION BY RANGE (timestamp);
CREATE TABLE operations_test.unrelated_leaf_name PARTITION OF operations_test.first_branch
    FOR VALUES FROM ('2020-01-01 00:00:00+00') TO ('2021-01-01 00:00:00+00');
CREATE TABLE operations_test.catch_all PARTITION OF operations_test."Odd Parent" DEFAULT;
CREATE TABLE operations_test."Odd Parent_imposter" (value numeric);
INSERT INTO operations_test."Odd Parent" VALUES
    ('2020-02-01 00:00:00+00', 10), ('2022-02-01 00:00:00+00', 20);
ANALYZE operations_test."Odd Parent";

DO $test$
DECLARE
    names text[];
    expected_size bigint;
    observed_size bigint;
    query_time double precision;
BEGIN
    SELECT array_agg(s.partition_full_name ORDER BY s.partition_full_name) INTO names
    FROM silver.get_partition_stats('operations_test."Odd Parent"') s;
    IF names IS DISTINCT FROM ARRAY['operations_test.catch_all', 'operations_test.unrelated_leaf_name'] THEN
        RAISE EXCEPTION 'Incorrect catalog partition membership: %', names;
    END IF;
    SELECT sum(pg_total_relation_size(tree.relid)) INTO expected_size
    FROM pg_partition_tree('operations_test."Odd Parent"'::regclass) tree WHERE tree.isleaf;
    SELECT s.total_size, s.avg_query_time INTO observed_size, query_time
    FROM silver.get_detailed_stats('operations_test."Odd Parent"') s;
    IF observed_size IS DISTINCT FROM expected_size OR observed_size <= 0 THEN
        RAISE EXCEPTION 'Parent size must include its leaves: actual %, expected %', observed_size, expected_size;
    END IF;
    IF query_time IS NOT NULL THEN RAISE EXCEPTION 'Unmeasured query duration must be NULL'; END IF;
    IF NOT EXISTS (SELECT 1 FROM silver.get_detailed_stats('operations_test.unrelated_leaf_name') s
                   WHERE s.total_size = pg_total_relation_size('operations_test.unrelated_leaf_name')) THEN
        RAISE EXCEPTION 'Individual leaf statistics missing or double-counted';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM silver.get_detailed_stats('operations_test."Odd Parent_imposter"')) THEN
        RAISE EXCEPTION 'Ordinary table statistics missing';
    END IF;
    BEGIN
        PERFORM silver.get_partition_stats('operations_test."Odd Parent_imposter"');
        RAISE EXCEPTION 'Nonpartitioned table should be rejected';
    EXCEPTION WHEN wrong_object_type THEN NULL;
    END;
    BEGIN
        PERFORM silver.get_partition_stats('operations_test.missing');
        RAISE EXCEPTION 'Missing partition parent should be rejected';
    EXCEPTION WHEN undefined_table THEN NULL;
    END;
    BEGIN
        PERFORM silver.optimize_chunk_interval('operations_test."Odd Parent"', 0);
        RAISE EXCEPTION 'Zero target chunk size should be rejected';
    EXCEPTION WHEN invalid_parameter_value THEN NULL;
    END;
END;
$test$;

CREATE TABLE operations_test.source (
    timestamp timestamptz NOT NULL, sensor text NOT NULL, reading numeric
);
INSERT INTO silver.timeseries_dimension_config (source_table, dimension_column)
VALUES ('operations_test.source', 'sensor');
SELECT silver.create_rollup_table('operations_test.source', 'operations_test', 'bad_hour', '1 hour');
SELECT silver.create_rollup_table('operations_test.source', 'operations_test', 'good_hour', '1 hour');
SELECT silver.create_rollup_table('operations_test.good_hour', 'operations_test', 'good_day', '1 day');

DO $test$
DECLARE failures text;
BEGIN
    SELECT string_agg(v.target_table || ': ' || v.validation_message, E'\n') INTO failures
    FROM silver.validate_rollup_config() v
    WHERE v.source_table LIKE 'operations_test.%' AND NOT v.is_valid;
    IF failures IS NOT NULL THEN RAISE EXCEPTION 'Fresh engine configurations should validate: %', failures; END IF;
    IF silver.optimize_chunk_interval('operations_test.source') <> INTERVAL '1 day' THEN
        RAISE EXCEPTION 'Insufficient statistics should produce the documented default';
    END IF;
END;
$test$;

-- Revalidate the target immediately before replacement. A manually constrained
-- average column would otherwise silently round new results.
INSERT INTO operations_test.source VALUES ('2025-01-01 00:15:00+00', 'a', 1.234567);
SELECT silver.refresh_rollup('operations_test.bad_hour', '2025-01-01 00:00:00+00', '2025-01-01 01:00:00+00');
ALTER TABLE operations_test.bad_hour ALTER COLUMN avg_reading TYPE numeric(10,2);
UPDATE operations_test.source SET reading = 99;
DO $test$
BEGIN
    BEGIN
        PERFORM silver.refresh_rollup('operations_test.bad_hour', '2025-01-01 00:00:00+00', '2025-01-01 01:00:00+00');
        RAISE EXCEPTION 'Refresh accepted numeric precision drift';
    EXCEPTION WHEN object_not_in_prerequisite_state THEN
        IF SQLERRM NOT LIKE '%avg_reading%' THEN RAISE; END IF;
    END;
    IF NOT EXISTS (SELECT 1 FROM operations_test.bad_hour
                   WHERE min_reading = 1.234567 AND avg_reading = 1.23 AND rollup_count = 1) THEN
        RAISE EXCEPTION 'Rejected precision drift must preserve the existing target rows';
    END IF;
END;
$test$;

-- A missing metric/dimension must be reported, and must not contaminate the
-- next configuration's validation results.
ALTER TABLE operations_test.bad_hour DROP COLUMN count_reading;
UPDATE silver.timeseries_rollup_config
SET dimension_columns = ARRAY['sensor', 'missing_dimension']
WHERE target_table = 'operations_test.bad_hour';
DO $test$
DECLARE bad_message text;
BEGIN
    SELECT v.validation_message INTO bad_message FROM silver.validate_rollup_config() v
    WHERE v.target_table = 'operations_test.bad_hour' AND NOT v.is_valid;
    IF bad_message IS NULL OR bad_message NOT LIKE '%missing_dimension%'
       OR bad_message NOT LIKE '%count_reading%' OR bad_message NOT LIKE '%avg_reading%' THEN
        RAISE EXCEPTION 'Missing columns must be reported: %', bad_message;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM silver.validate_rollup_config() v
                   WHERE v.target_table = 'operations_test.good_hour' AND v.is_valid) THEN
        RAISE EXCEPTION 'Validation errors leaked into the next configuration';
    END IF;
END;
$test$;

-- Zero-row successes count as successful attempts; old outcomes do not.
INSERT INTO silver.timeseries_refresh_log (table_name, start_time, end_time, records_processed, refresh_timestamp)
VALUES
    ('operations_test.good_hour', now() - INTERVAL '1 second', now(), 0, now()),
    ('operations_test.good_hour', now() - INTERVAL '3 seconds', now(), 5, now()),
    ('operations_test.good_hour', now() - INTERVAL '3 days', now() - INTERVAL '3 days', 0, now() - INTERVAL '3 days');
INSERT INTO silver.timeseries_error_log (source_table, target_table, error_message, error_timestamp)
VALUES
    ('operations_test.source', 'operations_test.good_hour', 'current failure', now()),
    ('operations_test.source', 'operations_test.good_hour', 'old failure', now() - INTERVAL '3 days');

DO $test$
DECLARE mon record;
BEGIN
    SELECT * INTO mon FROM silver.timeseries_operations_monitor WHERE target_table = 'operations_test.good_hour';
    IF mon.recent_successes <> 2 OR mon.recent_errors <> 1 OR mon.recent_attempts <> 3
       OR abs(mon.success_rate - (200.0 / 3)) > 0.000001
       OR mon.avg_duration <> INTERVAL '2 seconds' OR mon.latest_error <> 'current failure' THEN
        RAISE EXCEPTION 'Incorrect logged outcome accounting: %', row_to_json(mon);
    END IF;
    IF (SELECT success_rate FROM silver.timeseries_operations_monitor WHERE target_table = 'operations_test.good_day') IS NOT NULL THEN
        RAISE EXCEPTION 'No attempts must report an unknown success rate';
    END IF;
    UPDATE silver.timeseries_rollup_config SET retry_count = 1, next_retry_time = now() + INTERVAL '1 minute'
    WHERE target_table = 'operations_test.good_hour';
    IF (SELECT health_status FROM silver.timeseries_operations_monitor WHERE target_table = 'operations_test.good_hour') <> 'WARNING' THEN
        RAISE EXCEPTION 'Pending retries must be visible';
    END IF;
    UPDATE silver.timeseries_rollup_config SET retry_count = max_retries WHERE target_table = 'operations_test.good_hour';
    IF (SELECT health_status FROM silver.timeseries_operations_monitor WHERE target_table = 'operations_test.good_hour') <> 'ALERT' THEN
        RAISE EXCEPTION 'Exhausted retries must alert';
    END IF;
    UPDATE silver.timeseries_rollup_config SET is_active = false WHERE target_table = 'operations_test.good_hour';
    IF (SELECT health_status FROM silver.timeseries_operations_monitor WHERE target_table = 'operations_test.good_hour') <> 'INACTIVE' THEN
        RAISE EXCEPTION 'Inactive configurations must be distinguished';
    END IF;
    IF (SELECT count(*) FROM silver._validate_rollup_config('operations_test.good_hour')) <> 1
       OR NOT EXISTS (SELECT 1 FROM silver._validate_rollup_config('operations_test.good_hour') v
                      WHERE v.target_table = 'operations_test.good_hour' AND v.is_valid) THEN
        RAISE EXCEPTION 'Targeted validation must include inactive configurations';
    END IF;
    IF EXISTS (SELECT 1 FROM silver.validate_rollup_config() v WHERE v.target_table = 'operations_test.good_hour') THEN
        RAISE EXCEPTION 'Public validation should retain its active-only behavior';
    END IF;
    UPDATE silver.timeseries_rollup_config SET is_active = true, retry_count = 0, next_retry_time = NULL
    WHERE target_table = 'operations_test.good_hour';
END;
$test$;

-- Maintenance should analyze, preserve the configured partition interval, and
-- avoid adding fake successes to the rollup log.
DO $test$
DECLARE
    old_logs bigint;
    new_logs bigint;
    old_interval interval;
    cfg record;
BEGIN
    SELECT count(*) INTO old_logs FROM silver.timeseries_refresh_log;
    SELECT chunk_interval INTO old_interval FROM silver.timeseries_rollup_config
    WHERE target_table = 'operations_test.good_hour';
    PERFORM silver.maintain_timeseries_tables('operations_test.good_hour');
    SELECT count(*) INTO new_logs FROM silver.timeseries_refresh_log;
    SELECT * INTO cfg FROM silver.timeseries_rollup_config WHERE target_table = 'operations_test.good_hour';
    IF old_logs <> new_logs OR cfg.last_optimization_time IS NULL OR cfg.chunk_interval IS DISTINCT FROM old_interval THEN
        RAISE EXCEPTION 'Maintenance changed rollup accounting or partition interval';
    END IF;
    IF (SELECT last_optimization_time FROM silver.timeseries_rollup_config WHERE target_table = 'operations_test.good_day') IS NOT NULL THEN
        RAISE EXCEPTION 'Targeted maintenance affected another target';
    END IF;
    UPDATE silver.timeseries_rollup_config SET engine_version = 1 WHERE target_table = 'operations_test.good_day';
    IF NOT EXISTS (SELECT 1 FROM silver.validate_rollup_config() v
                   WHERE v.target_table = 'operations_test.good_day' AND NOT v.is_valid
                     AND v.validation_message LIKE '%recreate%backfill%') THEN
        RAISE EXCEPTION 'Legacy configurations require an actionable upgrade diagnosis';
    END IF;
END;
$test$;

ROLLBACK;
