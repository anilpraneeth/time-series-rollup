# Historical backfills

A backfill rebuilds historical aggregates after a correction, a late arrival, or the creation of a new rollup level. Choose the **coarsest target whose results you need to repair**. The planner includes that target and every ancestor back to the raw source, in parent-first order. Siblings and descendants are outside the plan.

For example, with `raw.readings → silver.readings_minute → silver.readings_hour → gold.readings_day`, select `gold.readings_day` to rebuild all three levels. Selecting `silver.readings_hour` rebuilds minutes and hours only; the existing daily results are not refreshed.

## Preview the plan

```sql
SELECT * FROM silver.plan_rollup_backfill(
    'gold.readings_day',
    '2025-01-01 10:17:00+00',
    '2025-01-01 11:42:00+00'
);
```

The requested range is half-open: `[start, end)`. The planner widens both ends to complete buckets of the selected target. In this example, a daily target produces `[2025-01-01 00:00+00, 2025-01-02 00:00+00)` at every level. Each ancestor must use a smaller interval that divides its child interval exactly, so these common bounds also align with every ancestor. An end that is already aligned stays unchanged. A widened end in an unfinished or future bucket is rejected.

The result contains one row per level:

| Column | Meaning |
| --- | --- |
| `step_order` | Parent-first execution order, starting at 1. |
| `config_id` | Existing rollup configuration ID. |
| `source_table`, `target_table` | Tables read and rebuilt at that level. |
| `range_start`, `range_end` | Common expanded bounds, with an exclusive end. |
| `batch_interval` | Configured processing window rounded down to a whole number of buckets, with a minimum of one bucket. |
| `estimated_batches` | Number of batches needed for that level, including a shorter final batch. |

Planning is read-only. It validates every included configuration, including inactive ones, and rejects cycles, missing parents, inconsistent lineage, schema drift, and calendar-month processing windows. It does not inspect raw rows or establish whether historical source data is complete.

## Enqueue and run bounded batches

```sql
SELECT silver.enqueue_rollup_backfill(
    'gold.readings_day',
    '2025-01-01 10:17:00+00',
    '2025-01-01 11:42:00+00'
);
-- Returns a job ID; use that ID in the following calls.

SELECT silver.run_rollup_backfills(max_batches := 1, specific_job := 42);
SELECT * FROM silver.timeseries_backfill_monitor WHERE id = 42;
```

Enqueueing stores the requested range, expanded per-level plan, batch sizes, configuration metadata, and source/target relation identities. It refreshes no rows. Changing a configured processing window later does not resize this job's batches. A changed lineage, renamed configuration, replaced relation, or invalid schema prevents the queued job from continuing with a different meaning.

Each worker call makes at most `max_batches` attempts across eligible jobs and returns the number of successful batches. Omit `specific_job` to process the queue. A return value of zero can mean that jobs are complete, locked by another session, or failed; inspect the monitor to distinguish these cases. The worker finishes every batch at one level before advancing to its child.

**Commit after every worker call.** In psql's default autocommit mode, each `SELECT` is already a separate transaction. When using an application transaction, explicitly commit before scheduling the next call. Do not wrap an entire large backfill in one outer transaction: progress and failure state are only durable after commit, and locks remain held until that transaction ends. A failed batch rolls back its own replacement and cursor update; successful earlier batches in the same call can still commit with its failure record. Cancellation or connection loss rolls back the current call's transaction.

The worker locks the job and every configuration in its planned chain for each call. It also takes `ACCESS SHARE` locks on the named source and target tables before checking their identities and schemas, preventing replacement or type changes during execution. A busy chain or conflicting schema operation is skipped without recording a failure. These configuration locks coordinate with other backfills, manual refreshes, and incremental workers. They are released at commit; the job does not reserve the chain between calls. Raw ingestion remains concurrent, and batches do not share a single source-data snapshot. Readers can observe partially completed history between committed batches; the entire hierarchy is not one atomic replacement.

Backfills neither advance nor reset the incremental worker's watermarks or retry state. They may run for inactive configurations. A manual refresh of an individual target remains available when a durable multi-level job is unnecessary.

## Monitor, recover, or cancel

```sql
SELECT id, target_table, status, current_target, next_start,
       completed_batches, estimated_batches, progress_percent,
       last_error, sql_state
FROM silver.timeseries_backfill_monitor
ORDER BY id DESC;

-- After repairing the cause of a failed batch:
SELECT silver.resume_rollup_backfill(42);
SELECT silver.run_rollup_backfills(1, 42);

-- Stop further work; committed batches remain in place:
SELECT silver.cancel_rollup_backfill(42);
```

| Status | Meaning |
| --- | --- |
| `queued` | Ready for work, including a failed job explicitly resumed by an operator. |
| `running` | At least one batch succeeded and work remains; a worker may not currently be attached. |
| `completed` | Every planned batch succeeded. Terminal; enqueue a new job to refresh again. |
| `failed` | Work stopped with `last_error` and `sql_state`; automatic worker calls leave it paused. |
| `cancelled` | Further work was cancelled. Terminal; enqueue a new job to continue with a new plan. |

After repairing a transient source or target constraint failure, resume retries the saved batch boundary. If the configuration's meaning or source/target relation identity changed, cancel the old job and enqueue a new plan. Resume does not erase successful progress, and cancelling a job does not undo committed replacements.

The monitor's percentage measures completed batches, not elapsed time or source rows. `records_processed` sums output groups written across every level. Monitoring shows committed progress; it does not expose another session's uncommitted claim.

Run [the repeatable psql example](../examples/backfill.sql) in an installed development database to see a correction propagate through three levels with one committed batch per worker call.

## Choose ranges with retained source data

Range replacement recomputes from the source rows available when each batch runs. If original raw history has expired, rebuilding its ancestors can overwrite valid historical aggregates with incomplete results or remove them entirely. Confirm the **expanded** range is available in the root raw source before enqueueing a backfill. A source minimum timestamp alone does not prove that the intervening history is complete.

The plan always starts from the root raw source. If raw history is unavailable but a trustworthy intermediate aggregate remains, use a deliberate `silver.refresh_rollup` on the desired child from that intermediate source, and propagate the correction through subsequent levels yourself. That lower-level API requires complete bucket boundaries and leaves ancestor refresh ordering to the caller.

Source ingestion remains concurrent. Data committed after a batch reads its source may require a later backfill or configured overlap. Backfills repair the selected historical range; they do not establish a continuous ingestion watermark.
