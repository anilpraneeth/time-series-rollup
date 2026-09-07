#!/bin/sh
# Shared PostgreSQL client discovery; source this file from the scripts below.
if [ -n "${PG_BIN:-}" ]; then
    PATH="$PG_BIN:$PATH"
elif command -v pg_config >/dev/null 2>&1; then
    PATH="$(pg_config --bindir):$PATH"
fi
export PATH

require_postgres_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Missing PostgreSQL tool: %s. Install PostgreSQL 14+ or set PG_BIN to its bin directory.\n' "$1" >&2
        exit 1
    fi
}
