#!/usr/bin/env python3
r"""Generate a new, reviewable pg_cron maintenance migration from JSON manifests.

Usage (paths may be absolute or relative to the caller's working directory)::

    python3 src/main/pgdb/migrations/postgres/generate_migration.py \
        --manifests /path/to/manifests \
        --output /path/to/V6__project_maintenance.sql \
        --database iotmetrics --schedule '0 0 * * *' --intervals 1m,5m

Each direct *.json child must contain an array of objects with a ``ProtoDefName``
string, for example ``[{"ProtoDefName": "telemetry.Sensor"}]``. Other fields are
ignored. Names become lowercase PostgreSQL table names with dots replaced by
underscores. Duplicate or colliding names, invalid identifiers, and names that
would exceed PostgreSQL's 63-byte table/job limits are rejected.

The resulting jobs maintain ``silver.<name>_<interval>`` in the chosen database.
Run the generated SQL in the database that hosts pg_cron (usually ``postgres``),
as a role permitted to call ``cron.schedule_in_database`` (pg_cron 1.4+). The
target database must already contain the configured rollup tables and maintenance
function. Schedule syntax is checked by pg_cron when the migration is applied;
times use the server's ``cron.timezone`` setting.

This standard-library-only module is safe to import and never connects to a
database. Output is deterministic and published atomically. Existing files are
preserved unless ``--force`` is explicitly supplied. Always choose a new Flyway
version; do not regenerate a migration that has already been applied.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from typing import Optional, Sequence, Union


DEFAULT_INTERVALS = ("1m", "5m")
IDENTIFIER_LIMIT = 63
PROTO_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*")
TABLE_NAME = re.compile(r"[a-z_][a-z0-9_]*")
INTERVAL_SUFFIX = re.compile(r"[1-9][0-9]*[smhdw]")
TEMPLATE_PATH = (
    Path(__file__).resolve().parent
    / "configure_timeseries_maintenance_template"
    / "configure_timeseries_maintenance.sql"
)


class MigrationError(ValueError):
    """Invalid migration inputs or an unsafe output destination."""


def _text(value: str, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise MigrationError(f"{label} must be a nonempty string")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise MigrationError(f"{label} must not contain control characters")
    return value


def sql_literal(value: str) -> str:
    """Quote PostgreSQL text independently of standard_conforming_strings."""
    if "\x00" in value:
        raise MigrationError("SQL literals must not contain NUL characters")
    return "E'" + value.replace("\\", "\\\\").replace("'", "''") + "'"


def _check_identifier_length(value: str, label: str) -> None:
    if len(value.encode("utf-8")) > IDENTIFIER_LIMIT:
        raise MigrationError(f"{label} {value!r} exceeds PostgreSQL's 63-byte limit")


def normalize_table_name(proto_name: str) -> str:
    """Normalize a protobuf name without lossy character replacement."""
    if not isinstance(proto_name, str) or not PROTO_NAME.fullmatch(proto_name):
        raise MigrationError(f"invalid ProtoDefName {proto_name!r}: expected dot-separated identifiers")
    table_name = proto_name.replace(".", "_").lower()
    _check_identifier_length(table_name, "table name")
    return table_name


def load_table_names(manifests_dir: Union[str, Path]) -> list[str]:
    """Read direct JSON files and reject duplicates after name normalization."""
    manifests_dir = Path(manifests_dir)
    if not manifests_dir.is_dir():
        raise MigrationError(f"manifests directory does not exist or is not a directory: {manifests_dir}")
    manifest_paths = sorted(
        (path for path in manifests_dir.iterdir() if path.is_file() and path.suffix.lower() == ".json"),
        key=lambda path: path.name,
    )
    if not manifest_paths:
        raise MigrationError(f"no JSON manifest files found in {manifests_dir}")

    sources: dict[str, str] = {}
    for path in manifest_paths:
        try:
            entries = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise MigrationError(f"cannot read JSON manifest {path}: {error}") from error
        if not isinstance(entries, list):
            raise MigrationError(f"{path}: expected a JSON array of manifest objects")
        for index, entry in enumerate(entries):
            source = f"{path.name}[{index}]"
            if not isinstance(entry, dict) or "ProtoDefName" not in entry:
                raise MigrationError(f"{source}: expected an object with ProtoDefName")
            try:
                table_name = normalize_table_name(entry["ProtoDefName"])
            except MigrationError as error:
                raise MigrationError(f"{source}: {error}") from error
            if table_name in sources:
                raise MigrationError(
                    f"{source}: duplicate or colliding table name {table_name!r}; "
                    f"already defined by {sources[table_name]}"
                )
            sources[table_name] = source
    if not sources:
        raise MigrationError("JSON manifests contain no table definitions")
    return sorted(sources)


def normalize_intervals(intervals: Union[str, Sequence[str]]) -> list[str]:
    """Validate table suffixes such as 1m, 5m, and 1h, returning stable order."""
    values = intervals.split(",") if isinstance(intervals, str) else list(intervals)
    if not values:
        raise MigrationError("at least one interval suffix is required")
    normalized = []
    for value in values:
        if not isinstance(value, str):
            raise MigrationError(f"invalid interval suffix {value!r}")
        suffix = value.strip().lower()
        if not INTERVAL_SUFFIX.fullmatch(suffix):
            raise MigrationError(f"invalid interval suffix {value!r}: expected a positive integer and s, m, h, d, or w")
        if suffix in normalized:
            raise MigrationError(f"duplicate interval suffix {suffix!r}")
        normalized.append(suffix)
    return sorted(normalized)


def render_migration(
    table_names: Sequence[str],
    database: str = "iotmetrics",
    schedule: str = "0 0 * * *",
    intervals: Union[str, Sequence[str]] = DEFAULT_INTERVALS,
) -> str:
    """Render exact named jobs; never change unrelated cron.job rows."""
    database = _text(database, "database")
    _check_identifier_length(database, "database name")
    schedule = " ".join(_text(schedule, "schedule").split())
    suffixes = normalize_intervals(intervals)
    if not table_names:
        raise MigrationError("at least one table name is required")
    seen = set()
    for table_name in table_names:
        if not isinstance(table_name, str) or not TABLE_NAME.fullmatch(table_name):
            raise MigrationError(f"invalid normalized table name {table_name!r}")
        if table_name in seen:
            raise MigrationError(f"duplicate table name {table_name!r}")
        seen.add(table_name)

    template = TEMPLATE_PATH.read_text(encoding="utf-8")
    statements = [
        "-- Generated timeseries maintenance jobs. Review before applying.\n"
        "-- Apply in the database hosting pg_cron; each job names its target database.\n"
        "-- Requires pg_cron 1.4+ and permission to call cron.schedule_in_database.\n"
    ]
    for table_name in sorted(seen):
        for suffix in suffixes:
            relation = f"{table_name}_{suffix}"
            job_name = f"maintain_{relation}"
            _check_identifier_length(relation, "rollup table name")
            # pg_cron stores jobname as PostgreSQL's fixed-length `name` type.
            _check_identifier_length(job_name, "cron job name")
            command = f"SELECT silver.maintain_timeseries_tables({sql_literal('silver.' + relation)});"
            statements.append(template.format(
                job_name=sql_literal(job_name),
                schedule=sql_literal(schedule),
                command=sql_literal(command),
                database=sql_literal(database),
            ).strip())
    return "\n\n".join(statements).rstrip() + "\n"


def generate_migration(
    manifests_dir: Union[str, Path],
    output: Union[str, Path],
    *,
    database: str = "iotmetrics",
    schedule: str = "0 0 * * *",
    intervals: Union[str, Sequence[str]] = DEFAULT_INTERVALS,
    force: bool = False,
) -> Path:
    """Validate all input and atomically write an explicit .sql destination."""
    output = Path(output)
    if output.suffix.lower() != ".sql":
        raise MigrationError("output must be an explicit .sql file path")
    if not output.parent.is_dir():
        raise MigrationError(f"output directory does not exist: {output.parent}")
    if output.is_dir():
        raise MigrationError(f"output is a directory: {output}")
    if not force and (output.exists() or output.is_symlink()):
        raise MigrationError(f"output already exists: {output}; use --force only for unapplied migrations")

    sql = render_migration(load_table_names(manifests_dir), database, schedule, intervals)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", newline="\n", dir=output.parent,
            prefix=f".{output.name}.", suffix=".tmp", delete=False,
        ) as handle:
            temporary = Path(handle.name)
            handle.write(sql)
            handle.flush()
            os.fsync(handle.fileno())
        if force:
            os.replace(temporary, output)
        else:
            # A hard link publishes the complete file without a check/write race.
            os.link(temporary, output)
    except FileExistsError as error:
        raise MigrationError(f"output already exists: {output}; use --force only for unapplied migrations") from error
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return output


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifests", required=True, type=Path, help="directory containing JSON manifest arrays")
    parser.add_argument("--output", required=True, type=Path, help="new SQL migration file; parent directory must exist")
    parser.add_argument("--database", default="iotmetrics", help="database in which maintenance jobs execute (default: iotmetrics)")
    parser.add_argument("--schedule", default="0 0 * * *", help="pg_cron schedule (default: daily at midnight)")
    parser.add_argument("--intervals", default=",".join(DEFAULT_INTERVALS), help="comma-separated rollup suffixes (default: 1m,5m)")
    parser.add_argument("--force", action="store_true", help="replace an existing, unapplied output file")
    args = parser.parse_args(argv)
    try:
        output = generate_migration(
            args.manifests, args.output, database=args.database,
            schedule=args.schedule, intervals=args.intervals, force=args.force,
        )
    except (MigrationError, OSError, UnicodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"Wrote {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
