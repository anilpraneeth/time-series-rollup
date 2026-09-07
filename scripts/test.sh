#!/bin/sh
set -eu
REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$REPO_ROOT/scripts/postgres-tools.sh"
require_postgres_tool psql

test_tmp=
server_started=false
cleanup() {
    test_status=$?
    trap - EXIT INT TERM
    if [ "$server_started" = true ]; then
        pg_ctl --pgdata "$test_tmp/data" --mode immediate --wait stop >/dev/null 2>&1 || true
    fi
    if [ -n "$test_tmp" ]; then
        if [ "$test_status" -ne 0 ] && [ -f "$test_tmp/server.log" ]; then
            printf '\nDisposable PostgreSQL server log:\n' >&2
            tail -n 60 "$test_tmp/server.log" >&2
        fi
        rm -rf -- "$test_tmp"
    fi
    exit "$test_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# DATABASE_URL is deliberately ignored: only an explicit TEST_DATABASE_URL opts
# into running fixtures on an existing server. That database must be disposable.
if [ -n "${TEST_DATABASE_URL:-}" ]; then
    printf 'Using the explicitly supplied disposable TEST_DATABASE_URL.\n'
else
    require_postgres_tool initdb
    require_postgres_tool pg_ctl
    if [ "$(id -u)" -eq 0 ]; then
        printf 'initdb cannot run as root. Run as a regular user or supply TEST_DATABASE_URL.\n' >&2
        exit 1
    fi
    # A short, private path also fits macOS's Unix-domain socket length limit.
    test_tmp=$(mktemp -d /tmp/tsrollup.XXXXXX)
    initdb --pgdata "$test_tmp/data" --username rollup_test --auth=trust --encoding=UTF8 --no-locale >"$test_tmp/initdb.log" 2>&1 || {
        cat "$test_tmp/initdb.log" >&2
        exit 1
    }
    server_started=true
    pg_ctl --pgdata "$test_tmp/data" --log "$test_tmp/server.log" \
        --options "-k $test_tmp -h '' -p 55439 -F" --wait start >/dev/null
    psql -X --set ON_ERROR_STOP=1 --dbname "host=$test_tmp port=55439 user=rollup_test dbname=postgres" \
        --command 'CREATE DATABASE rollup_test' >/dev/null
    TEST_DATABASE_URL="host=$test_tmp port=55439 user=rollup_test dbname=rollup_test"
    printf 'Started disposable PostgreSQL using a private Unix socket.\n'
fi
export TEST_DATABASE_URL

DATABASE_URL="$TEST_DATABASE_URL" "$REPO_ROOT/scripts/install.sh"
test_count=0
for test_file in "$REPO_ROOT"/tests/*.sql; do
    [ -f "$test_file" ] || continue
    printf '\nRunning %s\n' "$(basename "$test_file")"
    psql -X --set ON_ERROR_STOP=1 --dbname "$TEST_DATABASE_URL" --file "$test_file"
    test_count=$((test_count + 1))
done
for test_file in "$REPO_ROOT"/tests/*.sh; do
    [ -f "$test_file" ] || continue
    printf '\nRunning %s\n' "$(basename "$test_file")"
    sh "$test_file"
    test_count=$((test_count + 1))
done
if [ "$test_count" -eq 0 ]; then
    printf 'No SQL or shell tests were found.\n' >&2
    exit 1
fi
printf '\nAll %s test files passed.\n' "$test_count"
