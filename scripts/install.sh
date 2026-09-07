#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$REPO_ROOT/scripts/postgres-tools.sh"
require_postgres_tool psql

if [ "$#" -gt 1 ]; then
    printf 'Usage: DATABASE_URL=... %s [database-url]\n' "$0" >&2
    exit 2
fi
DATABASE_URL=${1:-${DATABASE_URL:-}}
if [ -z "$DATABASE_URL" ]; then
    printf 'Set DATABASE_URL to an empty PostgreSQL 14+ database before installing.\n' >&2
    exit 2
fi

# Build ordered -f arguments without relying on platform-specific sort options.
# Keep this upper bound in sync when adding a new versioned migration.
set -- --file "$REPO_ROOT/scripts/bootstrap.sql"
version=5
while [ "$version" -le 12 ]; do
    migration_count=0
    for migration in "$REPO_ROOT/src/main/pgdb/migrations/foundational/timeseries/V${version}__"*.sql; do
        if [ -f "$migration" ]; then
            migration_count=$((migration_count + 1))
            set -- "$@" --file "$migration"
        fi
    done
    if [ "$migration_count" -ne 1 ]; then
        printf 'Expected exactly one V%s migration, found %s. No changes applied.\n' "$version" "$migration_count" >&2
        exit 1
    fi
    version=$((version + 1))
done

printf 'Installing portable Time Series Rollup (V1, V5–V12) in one transaction...\n'
psql -X --quiet --set ON_ERROR_STOP=1 --single-transaction --dbname "$DATABASE_URL" "$@"
printf 'Installation complete.\n'
