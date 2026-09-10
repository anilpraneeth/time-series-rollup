#!/bin/sh
set -eu
REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$REPO_ROOT/scripts/postgres-tools.sh"
require_postgres_tool psql
: "${DATABASE_URL:?Set DATABASE_URL to a database with Time Series Rollup installed}"
# Each worker call commits separately to demonstrate durable progress.
exec psql -X --set ON_ERROR_STOP=1 --dbname "$DATABASE_URL" --file "$REPO_ROOT/examples/backfill.sql"
