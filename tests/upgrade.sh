#!/bin/sh
set -eu
REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$REPO_ROOT/scripts/postgres-tools.sh"
: "${TEST_DATABASE_URL:?Run this test through scripts/test.sh}"

test_tmp=$(mktemp -d /tmp/tsrollup-upgrade.XXXXXX)
upgrade_database="tsrollup_upgrade_$(basename "$test_tmp" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')"
upgrade_created=false
cleanup() {
    test_status=$?
    trap - EXIT INT TERM
    if [ "$upgrade_created" = true ]; then
        if ! psql -X --quiet --set ON_ERROR_STOP=1 --dbname "$TEST_DATABASE_URL" \
            --set "upgrade_database=$upgrade_database" >/dev/null <<'SQL'
DROP DATABASE :"upgrade_database";
SQL
        then
            printf 'Could not clean up upgrade test database %s.\n' "$upgrade_database" >&2
            test_status=1
        fi
    fi
    rm -rf -- "$test_tmp"
    exit "$test_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

psql -X --quiet --set ON_ERROR_STOP=1 --dbname "$TEST_DATABASE_URL" \
    --set "upgrade_database=$upgrade_database" <<'SQL'
CREATE DATABASE :"upgrade_database" TEMPLATE template0;
SQL
upgrade_created=true

# \connect retains the original host, port, user, and password, supporting both
# URI and keyword/value TEST_DATABASE_URL forms without parsing credentials.
upgrade_pg() {
    psql -X --quiet --set ON_ERROR_STOP=1 --dbname "$TEST_DATABASE_URL" \
        --command "\connect $upgrade_database" "$@"
}

# Install the historical schema unchanged. Target DDL below reproduces the V7
# numeric layout without needing the old pg_partman-specific creation function.
set -- --command BEGIN --file "$REPO_ROOT/scripts/bootstrap.sql"
version=5
while [ "$version" -le 10 ]; do
    for migration in "$REPO_ROOT/src/main/pgdb/migrations/foundational/timeseries/V${version}__"*.sql; do
        set -- "$@" --file "$migration"
    done
    version=$((version + 1))
done
upgrade_pg "$@" --file - <<'SQL'
CREATE TABLE raw.upgrade_readings (timestamp timestamptz NOT NULL, value integer);
INSERT INTO raw.upgrade_readings VALUES
    ('2025-01-01 00:05:00+00', 1), ('2025-01-01 00:35:00+00', 2);
CREATE TABLE silver.upgrade_hourly (
    timestamp timestamptz PRIMARY KEY,
    min_value integer, max_value integer, avg_value integer,
    rollup_count integer DEFAULT 1,
    last_updated_at timestamptz DEFAULT now()
) PARTITION BY RANGE (timestamp);
CREATE TABLE silver.upgrade_hourly_default PARTITION OF silver.upgrade_hourly DEFAULT;
INSERT INTO silver.upgrade_hourly VALUES ('2025-01-01 00:00:00+00', 1, 2, 2, 2, '2025-01-02 00:00:00+00');
INSERT INTO silver.timeseries_rollup_config (
    source_table, target_table, rollup_table_interval, look_back_window,
    processing_window, last_processed_time, last_processed_rows
) VALUES ('raw.upgrade_readings', 'silver.upgrade_hourly', '1 hour', '5 minutes',
    '1 hour', '2025-01-01 01:00:00+00', 1);
INSERT INTO silver.timeseries_refresh_log (table_name, start_time, end_time, records_processed, refresh_timestamp)
VALUES ('silver.upgrade_hourly', '2025-01-02 00:00:00+00', '2025-01-02 00:00:01+00', 1, '2025-01-02 00:00:01+00');
CREATE VIEW public.upgrade_monitor_consumer AS
    SELECT id, target_table, health_status FROM silver.timeseries_operations_monitor;
CREATE TABLE public.upgrade_snapshot AS SELECT
    (SELECT to_jsonb(c) FROM silver.timeseries_rollup_config c) AS config,
    (SELECT to_jsonb(t) FROM silver.upgrade_hourly t) AS target,
    (SELECT to_jsonb(l) FROM silver.timeseries_refresh_log l) AS history;
COMMIT;
SQL

upgrade_pg --command BEGIN \
    --file "$REPO_ROOT/src/main/pgdb/migrations/foundational/timeseries/V11__reliable_rollup_engine.sql" \
    --file "$REPO_ROOT/src/main/pgdb/migrations/foundational/timeseries/V12__timeseries_operations.sql" \
    --file - <<'SQL'
DO $test$
DECLARE preserved jsonb;
BEGIN
    SELECT to_jsonb(c) - ARRAY['engine_version', 'dimension_columns', 'metric_columns',
        'source_rollup_id', 'refresh_overlap', 'max_retries', 'retry_base_delay', 'retry_max_delay']
    INTO preserved FROM silver.timeseries_rollup_config c;
    IF preserved IS DISTINCT FROM (SELECT config FROM public.upgrade_snapshot) THEN
        RAISE EXCEPTION 'Upgrade altered existing configuration fields';
    END IF;
    IF (SELECT to_jsonb(t) FROM silver.upgrade_hourly t) IS DISTINCT FROM
       (SELECT target FROM public.upgrade_snapshot) THEN
        RAISE EXCEPTION 'Upgrade altered legacy target data';
    END IF;
    IF (SELECT to_jsonb(l) FROM silver.timeseries_refresh_log l) IS DISTINCT FROM
       (SELECT history FROM public.upgrade_snapshot) THEN
        RAISE EXCEPTION 'Upgrade altered refresh history';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM silver.timeseries_rollup_config
                   WHERE engine_version = 1 AND dimension_columns IS NULL AND metric_columns IS NULL) THEN
        RAISE EXCEPTION 'Existing configuration did not retain its legacy marker';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.upgrade_monitor_consumer WHERE health_status = 'UPGRADE REQUIRED') THEN
        RAISE EXCEPTION 'Legacy monitor consumer broke or the upgrade warning is absent';
    END IF;
    BEGIN
        PERFORM silver.refresh_rollup('silver.upgrade_hourly', '2025-01-01 00:00+00', '2025-01-01 01:00+00');
        RAISE EXCEPTION 'Unexpectedly refreshed legacy target';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'Legacy rollup % must be recreated and backfilled%' THEN RAISE; END IF;
    END;
END;
$test$;

SELECT silver.perform_rollup('silver.upgrade_hourly');
DO $test$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM silver.timeseries_rollup_config WHERE status = 'error' AND retry_count = 1
                   AND last_processed_time = '2025-01-01 01:00:00+00') THEN
        RAISE EXCEPTION 'Legacy worker refusal lost its watermark or retry state';
    END IF;
    IF (SELECT to_jsonb(t) FROM silver.upgrade_hourly t) IS DISTINCT FROM
       (SELECT target FROM public.upgrade_snapshot) THEN
        RAISE EXCEPTION 'Legacy worker modified old aggregates';
    END IF;
END;
$test$;
SELECT silver.create_rollup_table('raw.upgrade_readings', 'silver', 'upgrade_hourly_v2', '1 hour');
SELECT silver.refresh_rollup('silver.upgrade_hourly_v2', '2025-01-01 00:00+00', '2025-01-01 01:00+00');
DO $test$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM silver.upgrade_hourly_v2
                   WHERE avg_value = 1.5 AND count_value = 2 AND rollup_count = 2) THEN
        RAISE EXCEPTION 'Recreated target did not recover precision from the original source';
    END IF;
END;
$test$;
COMMIT;
SQL
printf 'V10-to-V12 upgrade preserved legacy data and enabled a precise side-by-side backfill.\n'
