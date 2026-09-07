#!/bin/sh
set -eu
REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$REPO_ROOT/scripts/postgres-tools.sh"
: "${TEST_DATABASE_URL:?Run this test through scripts/test.sh}"

test_tmp=$(mktemp -d /tmp/tsrollup-lock.XXXXXX)
fixture="tsrollup_lock_$(basename "$test_tmp" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')"
locker_name="${fixture}_locker"
locker_pid=
pipe_open=false
fixture_created=false
pg() {
    psql -X --quiet --set ON_ERROR_STOP=1 --dbname "$TEST_DATABASE_URL" \
        --set "fixture=$fixture" --set "source=$fixture.readings" \
        --set "target=$fixture.hourly" --set "locker=$locker_name" "$@"
}
cleanup() {
    test_status=$?
    trap - EXIT INT TERM
    if [ "$pipe_open" = true ]; then exec 3>&-; fi
    if [ -n "$locker_pid" ]; then
        kill "$locker_pid" 2>/dev/null || true
        wait "$locker_pid" 2>/dev/null || true
    fi
    if [ "$test_status" -ne 0 ]; then cat "$test_tmp/locker.log" >&2 2>/dev/null || true; fi
    if [ "$fixture_created" = true ]; then
        if ! pg >/dev/null <<'SQL'
SET lock_timeout = '2s';
BEGIN;
DELETE FROM silver.timeseries_refresh_log WHERE table_name = :'target';
DELETE FROM silver.timeseries_error_log WHERE source_table = :'source' AND target_table = :'target';
DELETE FROM silver.timeseries_rollup_config WHERE source_table = :'source' AND target_table = :'target';
DELETE FROM silver.timeseries_dimension_config WHERE source_table = :'source';
DROP SCHEMA :"fixture" CASCADE;
COMMIT;
SQL
        then
            printf 'Concurrency fixture cleanup failed for schema %s.\n' "$fixture" >&2
            test_status=1
        fi
    fi
    rm -rf -- "$test_tmp"
    exit "$test_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pg <<'SQL'
BEGIN;
CREATE SCHEMA :"fixture";
CREATE TABLE :"fixture".readings (timestamp timestamptz NOT NULL, value integer);
INSERT INTO :"fixture".readings VALUES
    ('2025-01-01 00:05:00+00', 1), ('2025-01-01 00:35:00+00', 2);
SELECT silver.create_rollup_table(:'source', :'fixture', 'hourly', '1 hour', '0 seconds');
COMMIT;
SQL
fixture_created=true

# Keep session A open through a FIFO so the parent controls COMMIT. Observing
# "idle in transaction" after FOR UPDATE proves that the row lock was acquired.
mkfifo "$test_tmp/locker.sql"
PGAPPNAME="$locker_name" psql -X --quiet --set ON_ERROR_STOP=1 \
    --dbname "$TEST_DATABASE_URL" --set "target=$fixture.hourly" \
    --file "$test_tmp/locker.sql" >"$test_tmp/locker.log" 2>&1 &
locker_pid=$!
exec 3>"$test_tmp/locker.sql"
pipe_open=true
cat >&3 <<'SQL'
BEGIN;
SELECT id FROM silver.timeseries_rollup_config WHERE target_table = :'target' FOR UPDATE;
SQL

attempt=0
ready=false
while [ "$attempt" -lt 100 ]; do
    if ! kill -0 "$locker_pid" 2>/dev/null; then
        printf 'Lock holder exited before acquiring its row lock.\n' >&2
        exit 1
    fi
    observed=$(pg --tuples-only --no-align <<'SQL'
SELECT count(*) = 1 FROM pg_stat_activity
WHERE application_name = :'locker' AND state = 'idle in transaction'
  AND query LIKE '%FOR UPDATE%';
SQL
    )
    if [ "$observed" = t ]; then ready=true; break; fi
    attempt=$((attempt + 1))
    sleep 0.1
done
if [ "$ready" != true ]; then
    printf 'Timed out waiting for the config-row lock handshake.\n' >&2
    exit 1
fi

# A blocking implementation fails the statement timeout while A holds the row.
pg <<'SQL'
SET statement_timeout = '2s';
SELECT silver.perform_rollup(:'target');
SQL
skipped=$(pg --tuples-only --no-align <<'SQL'
SELECT (SELECT count(*) = 0 FROM :"fixture".hourly)
   AND last_processed_time IS NULL AND status = 'idle' AND retry_count = 0
FROM silver.timeseries_rollup_config WHERE target_table = :'target';
SQL
)
if [ "$skipped" != t ]; then
    printf 'A competing worker modified the locked rollup.\n' >&2
    exit 1
fi

printf 'COMMIT;\n' >&3
exec 3>&-
pipe_open=false
wait "$locker_pid"
locker_pid=

pg <<'SQL'
SET statement_timeout = '2s';
SELECT silver.perform_rollup(:'target');
SQL
processed=$(pg --tuples-only --no-align <<'SQL'
SELECT (SELECT count(*) = 1 AND min(avg_value) = 1.5 AND min(rollup_count) = 2 FROM :"fixture".hourly)
   AND last_processed_time = '2025-01-01 01:00:00+00' AND status = 'idle' AND retry_count = 0
FROM silver.timeseries_rollup_config WHERE target_table = :'target';
SQL
)
if [ "$processed" != t ]; then
    printf 'Worker did not resume correctly after the config lock was released.\n' >&2
    exit 1
fi
printf 'Concurrent worker skipped the locked job and processed it after release.\n'
