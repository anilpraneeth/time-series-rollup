# Time-series SQL API

The maintained API and executable example are documented in the [root README](../../../../../../README.md). See [engine design](../../../../../../docs/engine-design.md) for transaction semantics and [upgrading](../../../../../../docs/upgrading.md) for legacy targets.

| Entry point | Behavior |
| --- | --- |
| `time_bucket(interval, timestamptz)` | Positive fixed UTC buckets; common Monday origin; no calendar months |
| `create_rollup_table(source, target_schema, target_name, interval, ...)` | Creates a numeric rollup with frozen dimensions and composable state |
| `refresh_rollup(target, start, end)` | Atomically replaces complete `[start,end)` buckets; returns output group count |
| `perform_rollup([source_or_target])` | One bounded forward window plus capped overlap per eligible configuration |
| `handle_rollup_retries()` | Runs due failures through the same worker and backoff checks |
| `reset_rollup_retry(target)` | Clears failure state after the underlying cause is corrected |
| `validate_rollup_config()` | Checks active configurations for invalid sources, dimensions, metrics, keys, and legacy formats |
| `timeseries_operations_monitor` | Logged outcomes, retry status, lag, and configuration health |
| `get_detailed_stats(pattern)` | Catalog sizes and counters; unavailable query timings remain null |
| `get_partition_stats(parent)` | Actual leaf partitions from PostgreSQL catalogs |
| `maintain_timeseries_tables([target])` | Analyze targets and maintain registered pg_partman parents |
| `optimize_chunk_interval(table, [target_bytes])` | Advisory chunk size estimate; does not change partitions |

V5–V10 are immutable historical migrations; their comments describe the original implementation. V11–V12 supersede engine and operations behavior. The old scalar `first_value` and `last_value` helpers are retained for compatibility; they are not aggregate functions and are not used by the new engine.
