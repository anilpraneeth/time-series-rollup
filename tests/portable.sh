#!/bin/sh
set -eu
REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$REPO_ROOT/scripts/postgres-tools.sh"
: "${TEST_DATABASE_URL:?Run this test through scripts/test.sh}"

# Reinstalling must fail before any existing application objects are changed.
if refusal_output=$(DATABASE_URL="$TEST_DATABASE_URL" "$REPO_ROOT/scripts/install.sh" 2>&1); then
    printf 'Expected the portable installer to refuse an existing installation.\n' >&2
    exit 1
fi
case "$refusal_output" in
    *'already installed'*) ;;
    *) printf 'Installer failed for an unexpected reason:\n%s\n' "$refusal_output" >&2; exit 1 ;;
esac

# The documented demo runs twice and produces the same corrected result.
psql -X --quiet --set ON_ERROR_STOP=1 --single-transaction --dbname "$TEST_DATABASE_URL" \
    --file "$REPO_ROOT/examples/quickstart.sql" \
    --file "$REPO_ROOT/examples/quickstart.sql" \
    --file - <<'SQL'
DO $assert$
BEGIN
    IF (SELECT count(*) FROM silver.demo_hourly) <> 3 THEN
        RAISE EXCEPTION 'Expected three demo rollup groups';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM silver.demo_hourly
        WHERE timestamp = '2025-01-01 00:00:00+00' AND device = 'sensor-a'
          AND avg_temperature = 21.5 AND rollup_count = 2
    ) THEN
        RAISE EXCEPTION 'Demo correction did not preserve fractional average and row count';
    END IF;
END
$assert$;
SQL
