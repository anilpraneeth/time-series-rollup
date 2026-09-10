#!/bin/sh
set -eu
REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$REPO_ROOT/scripts/postgres-tools.sh"
: "${TEST_DATABASE_URL:?Run this test through scripts/test.sh}"

test_tmp=$(mktemp -d /tmp/tsrollup-backfill-lock.XXXXXX)
fixture="tsrollup_bf_$(basename "$test_tmp" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')"
locker_name="${fixture}_locker"
locker_pid=
pipe_open=false
fixture_created=false
first_job=0
second_job=0
pg() {
    psql -X --quiet --set ON_ERROR_STOP=1 --dbname "$TEST_DATABASE_URL" \
        --set "fixture=$fixture" --set "source=$fixture.readings" \
        --set "hourly=$fixture.hourly" --set "daily=$fixture.daily" \
        --set "first_job=$first_job" --set "second_job=$second_job" \
        --set "locker=$locker_name" "$@"
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
DELETE FROM silver.timeseries_backfill_jobs WHERE target_table IN (:'hourly', :'daily');
DELETE FROM silver.timeseries_refresh_log WHERE table_name IN (:'hourly', :'daily');
DELETE FROM silver.timeseries_error_log WHERE target_table IN (:'hourly', :'daily');
DELETE FROM silver.timeseries_rollup_config WHERE target_table IN (:'hourly', :'daily');
DELETE FROM silver.timeseries_dimension_config WHERE source_table IN (:'source', :'hourly');
DROP SCHEMA :"fixture" CASCADE;
COMMIT;
SQL
        then
            printf 'Backfill concurrency fixture cleanup failed for schema %s.\n' "$fixture" >&2
            test_status=1
        fi
    fi
    rm -rf -- "$test_tmp"
    exit "$test_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

assert_scalar() {
    expected=$1
    failure=$2
    observed=$(pg --tuples-only --no-align)
    if [ "$observed" != "$expected" ]; then
        printf '%s (expected %s, observed %s).\n' "$failure" "$expected" "$observed" >&2
        exit 1
    fi
}

# Compare complete durable rows, including timestamps and errors. Sequence
# allocation is deliberately excluded: PostgreSQL sequences do not roll back.
fixture_state() {
    pg --tuples-only --no-align <<'SQL'
SELECT jsonb_build_object(
    'jobs', (SELECT jsonb_agg(to_jsonb(j) ORDER BY j.id)
        FROM silver.timeseries_backfill_jobs j WHERE j.id IN (:first_job, :second_job)),
    'steps', (SELECT jsonb_agg(to_jsonb(s) ORDER BY s.job_id, s.step_order)
        FROM silver.timeseries_backfill_steps s WHERE s.job_id IN (:first_job, :second_job)),
    'configs', (SELECT jsonb_agg(to_jsonb(c) ORDER BY c.id)
        FROM silver.timeseries_rollup_config c WHERE c.target_table IN (:'hourly', :'daily')),
    'hourly', (SELECT jsonb_agg(to_jsonb(h) ORDER BY h.timestamp) FROM :"fixture".hourly h),
    'daily', (SELECT jsonb_agg(to_jsonb(d) ORDER BY d.timestamp) FROM :"fixture".daily d),
    'logs', (SELECT jsonb_agg(to_jsonb(l) ORDER BY l.id)
        FROM silver.timeseries_refresh_log l WHERE l.table_name IN (:'hourly', :'daily')),
    'errors', (SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id)
        FROM silver.timeseries_error_log e WHERE e.target_table IN (:'hourly', :'daily'))
);
SQL
}
assert_pristine() {
    if [ "$(fixture_state)" != "$pristine_state" ]; then
        printf '%s\n' "$1" >&2
        exit 1
    fi
}

# A FIFO lets the parent release the lock only after the competing worker
# returns. The activity handshake proves acquisition without timing guesses.
start_locker() {
    PGAPPNAME="$locker_name" psql -X --quiet --set ON_ERROR_STOP=1 \
        --dbname "$TEST_DATABASE_URL" --set "fixture=$fixture" --set "hourly=$fixture.hourly" \
        --set "first_job=$first_job" --file "$test_tmp/locker.sql" \
        >"$test_tmp/locker.log" 2>&1 &
    locker_pid=$!
    exec 3>"$test_tmp/locker.sql"
    pipe_open=true
    cat >&3
    attempt=0
    ready=false
    while [ "$attempt" -lt 100 ]; do
        if ! kill -0 "$locker_pid" 2>/dev/null; then
            printf 'Backfill lock holder exited before acquiring its lock.\n' >&2
            exit 1
        fi
        observed=$(pg --tuples-only --no-align <<'SQL'
SELECT count(*) = 1 FROM pg_stat_activity
WHERE application_name = :'locker' AND state = 'idle in transaction'
  AND (query LIKE '%FOR UPDATE%' OR query LIKE '%ACCESS EXCLUSIVE%');
SQL
        )
        if [ "$observed" = t ]; then ready=true; break; fi
        attempt=$((attempt + 1))
        sleep 0.1
    done
    if [ "$ready" != true ]; then
        printf 'Timed out waiting for the backfill lock handshake.\n' >&2
        exit 1
    fi
}
release_locker() {
    printf 'COMMIT;\n' >&3
    exec 3>&-
    pipe_open=false
    wait "$locker_pid"
    locker_pid=
}

pg <<'SQL'
BEGIN;
CREATE SCHEMA :"fixture";
CREATE TABLE :"fixture".readings (timestamp timestamptz NOT NULL, value integer);
INSERT INTO :"fixture".readings VALUES
    ('2025-01-01 00:05:00+00', 1), ('2025-01-01 00:35:00+00', 3),
    ('2025-01-02 00:05:00+00', 9);
SELECT silver.create_rollup_table(:'source', :'fixture', 'hourly', '1 hour',
    '0 seconds', '30 days', '1 day');
SELECT silver.create_rollup_table(:'hourly', :'fixture', 'daily', '1 day',
    '0 seconds', '30 days', '1 day');
COMMIT;
SQL
fixture_created=true
first_job=$(pg --tuples-only --no-align <<'SQL'
SELECT silver.enqueue_rollup_backfill(:'daily', '2025-01-01 00:00:00+00', '2025-01-03 00:00:00+00');
SQL
)
second_job=$(pg --tuples-only --no-align <<'SQL'
SELECT silver.enqueue_rollup_backfill(:'daily', '2025-01-01 00:00:00+00', '2025-01-03 00:00:00+00');
SQL
)
pristine_state=$(fixture_state)
mkfifo "$test_tmp/locker.sql"

start_locker <<'SQL'
BEGIN;
SELECT id FROM silver.timeseries_rollup_config WHERE target_table = :'hourly' FOR UPDATE;
SQL
# Both daily jobs share this ancestor. A blocking implementation fails the
# timeout; a partial implementation changes the captured job, target or log rows.
assert_scalar 0 'Worker did not skip its locked ancestor' <<'SQL'
SET statement_timeout = '2s';
SELECT silver.run_rollup_backfills(1, :first_job);
SQL
assert_scalar 0 'A different job bypassed the shared ancestor lock' <<'SQL'
SET statement_timeout = '2s';
SELECT silver.run_rollup_backfills(1, :second_job);
SQL
assert_pristine 'A dependency-lock skip changed queued jobs, cursors, targets or logs.'
release_locker

start_locker <<'SQL'
BEGIN;
SELECT id FROM silver.timeseries_backfill_jobs WHERE id = :first_job FOR UPDATE;
SQL
assert_scalar 0 'Worker did not skip the locked job row' <<'SQL'
SET statement_timeout = '2s';
SELECT silver.run_rollup_backfills(1, :first_job);
SQL
assert_pristine 'A job-lock skip changed queued jobs, cursors, targets or logs.'
release_locker

# DDL may hold a relation lock without touching rollup configuration rows.
# The worker must skip before catalog validation or reading the locked source.
start_locker <<'SQL'
BEGIN;
LOCK TABLE ONLY :"fixture".readings IN ACCESS EXCLUSIVE MODE;
SQL
assert_scalar 0 'Worker did not skip a source relation locked for DDL' <<'SQL'
SET statement_timeout = '2s';
SELECT silver.run_rollup_backfills(1, :first_job);
SQL
assert_pristine 'A source-relation lock skip changed queued jobs, cursors, targets or logs.'
release_locker

# Work and cursor/log updates belong to the caller's transaction. A subsequent
# connection must observe the original state and safely repeat the same batch.
assert_scalar 1 'Worker did not execute the batch inside the caller transaction' <<'SQL'
SET statement_timeout = '2s';
BEGIN;
SELECT silver.run_rollup_backfills(1, :first_job);
ROLLBACK;
SQL
assert_pristine 'Caller ROLLBACK did not restore the complete durable backfill state.'

assert_scalar 1 'Worker did not process a batch after locks and rollback were released' <<'SQL'
SET statement_timeout = '2s';
SELECT silver.run_rollup_backfills(1, :first_job);
SQL
assert_scalar t 'First committed batch did not persist bounded parent-first progress' <<'SQL'
SELECT (SELECT status = 'running' AND last_error IS NULL AND sql_state IS NULL
           FROM silver.timeseries_backfill_jobs WHERE id = :first_job)
   AND (SELECT count(*) = 2 AND sum(completed_batches) = 1 AND sum(records_processed) = 1
           FROM silver.timeseries_backfill_steps WHERE job_id = :first_job)
   AND EXISTS (SELECT 1 FROM silver.timeseries_backfill_steps
           WHERE job_id = :first_job AND step_order = 1
             AND next_start = '2025-01-02 00:00:00+00')
   AND (SELECT count(*) = 1 AND min(avg_value) = 2 AND min(rollup_count) = 2 FROM :"fixture".hourly)
   AND (SELECT count(*) = 0 FROM :"fixture".daily)
   AND (SELECT count(*) = 1 FROM silver.timeseries_refresh_log WHERE table_name = :'hourly');
SQL

# Every invocation starts a fresh connection, demonstrating durable resumption
# across worker restarts and completion of all ancestors before child batches.
assert_scalar 1 'A new worker did not resume the second parent batch' <<'SQL'
SET statement_timeout = '2s';
SELECT silver.run_rollup_backfills(1, :first_job);
SQL
assert_scalar t 'Child data appeared before its parent step completed' <<'SQL'
SELECT EXISTS (SELECT 1 FROM silver.timeseries_backfill_steps
               WHERE job_id = :first_job AND step_order = 1
                 AND next_start = range_end AND completed_batches = 2)
   AND EXISTS (SELECT 1 FROM silver.timeseries_backfill_steps
               WHERE job_id = :first_job AND step_order = 2
                 AND next_start = range_start AND completed_batches = 0)
   AND (SELECT count(*) = 2 FROM :"fixture".hourly)
   AND (SELECT count(*) = 0 FROM :"fixture".daily);
SQL
assert_scalar 1 'A new worker did not resume the first child batch' <<'SQL'
SET statement_timeout = '2s';
SELECT silver.run_rollup_backfills(1, :first_job);
SQL
assert_scalar t 'Child batch progress was not committed independently' <<'SQL'
SELECT (SELECT status = 'running' AND completed_batches = 3 AND progress_percent = 75
               AND current_target = :'daily' AND next_start = '2025-01-02 00:00:00+00'
           FROM silver.timeseries_backfill_monitor WHERE id = :first_job)
   AND (SELECT count(*) = 1 AND min(avg_value) = 2 AND min(rollup_count) = 2 FROM :"fixture".daily);
SQL
assert_scalar 1 'A new worker did not finish the final child batch' <<'SQL'
SET statement_timeout = '2s';
SELECT silver.run_rollup_backfills(1, :first_job);
SQL
assert_scalar t 'Completed job has incorrect progress, aggregates or scheduled state' <<'SQL'
SELECT (SELECT status = 'completed' AND completed_at IS NOT NULL AND last_error IS NULL
               AND completed_batches = 4 AND estimated_batches = 4 AND records_processed = 4
               AND progress_percent = 100 AND current_target IS NULL AND next_start IS NULL
           FROM silver.timeseries_backfill_monitor WHERE id = :first_job)
   AND (SELECT count(*) = 2 AND sum(rollup_count) = 3 AND sum(sum_value) = 13 FROM :"fixture".daily)
   AND EXISTS (SELECT 1 FROM :"fixture".daily
           WHERE timestamp = '2025-01-01 00:00:00+00' AND avg_value = 2 AND rollup_count = 2)
   AND EXISTS (SELECT 1 FROM :"fixture".daily
           WHERE timestamp = '2025-01-02 00:00:00+00' AND avg_value = 9 AND rollup_count = 1)
   AND (SELECT count(*) = 4 FROM silver.timeseries_refresh_log WHERE table_name IN (:'hourly', :'daily'))
   AND (SELECT count(*) = 2 AND bool_and(last_processed_time IS NULL AND status = 'idle' AND retry_count = 0)
           FROM silver.timeseries_rollup_config WHERE target_table IN (:'hourly', :'daily'))
   AND (SELECT status = 'queued' AND last_error IS NULL AND sql_state IS NULL
           FROM silver.timeseries_backfill_jobs WHERE id = :second_job)
   AND (SELECT count(*) = 2 AND bool_and(next_start = range_start AND completed_batches = 0)
           FROM silver.timeseries_backfill_steps WHERE job_id = :second_job);
SQL
assert_scalar 0 'A completed job executed an extra batch' <<'SQL'
SET statement_timeout = '2s';
SELECT silver.run_rollup_backfills(1, :first_job);
SQL
assert_scalar 4 'Previously skipped overlapping job did not complete after release' <<'SQL'
SET statement_timeout = '2s';
SELECT silver.run_rollup_backfills(4, :second_job);
SQL
assert_scalar t 'Overlapping backfill duplicated aggregates or failed to complete' <<'SQL'
SELECT (SELECT count(*) = 2 AND bool_and(status = 'completed' AND last_error IS NULL AND sql_state IS NULL)
           FROM silver.timeseries_backfill_jobs WHERE id IN (:first_job, :second_job))
   AND (SELECT count(*) = 2 AND sum(rollup_count) = 3 AND sum(sum_value) = 13 FROM :"fixture".hourly)
   AND (SELECT count(*) = 2 AND sum(rollup_count) = 3 AND sum(sum_value) = 13 FROM :"fixture".daily)
   AND (SELECT count(*) = 8 FROM silver.timeseries_refresh_log WHERE table_name IN (:'hourly', :'daily'))
   AND NOT EXISTS (SELECT 1 FROM silver.timeseries_error_log WHERE target_table IN (:'hourly', :'daily'));
SQL
printf 'Backfill workers skipped shared locks, rolled back atomically and resumed across connections.\n'
