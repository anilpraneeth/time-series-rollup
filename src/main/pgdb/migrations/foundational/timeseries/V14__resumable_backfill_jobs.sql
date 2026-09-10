-- Durable, bounded, parent-first historical refreshes. Existing migrations,
-- scheduled watermarks and retry state are intentionally preserved.
CREATE TABLE silver.timeseries_backfill_jobs (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    target_table TEXT NOT NULL,
    requested_start TIMESTAMPTZ NOT NULL,
    requested_end TIMESTAMPTZ NOT NULL,
    status TEXT NOT NULL DEFAULT 'queued'
        CHECK (status IN ('queued', 'running', 'completed', 'failed', 'cancelled')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    completed_at TIMESTAMPTZ,
    last_error TEXT,
    sql_state TEXT,
    CHECK (isfinite(requested_start) AND isfinite(requested_end) AND requested_start < requested_end)
);

CREATE TABLE silver.timeseries_backfill_steps (
    job_id BIGINT NOT NULL REFERENCES silver.timeseries_backfill_jobs(id) ON DELETE CASCADE,
    step_order INTEGER NOT NULL CHECK (step_order > 0),
    config_id INTEGER NOT NULL,
    source_table TEXT NOT NULL,
    target_table TEXT NOT NULL,
    range_start TIMESTAMPTZ NOT NULL,
    range_end TIMESTAMPTZ NOT NULL,
    batch_interval INTERVAL NOT NULL,
    next_start TIMESTAMPTZ NOT NULL,
    estimated_batches BIGINT NOT NULL CHECK (estimated_batches > 0),
    completed_batches BIGINT NOT NULL DEFAULT 0 CHECK (completed_batches >= 0),
    records_processed BIGINT NOT NULL DEFAULT 0 CHECK (records_processed >= 0),
    config_snapshot JSONB NOT NULL,
    PRIMARY KEY (job_id, step_order),
    UNIQUE (job_id, config_id),
    CHECK (isfinite(range_start) AND isfinite(range_end) AND range_start < range_end
        AND next_start >= range_start AND next_start <= range_end),
    CHECK (isfinite(batch_interval) AND batch_interval > INTERVAL '0'
        AND extract(year FROM batch_interval) = 0 AND extract(month FROM batch_interval) = 0)
);

CREATE INDEX timeseries_backfill_runnable ON silver.timeseries_backfill_jobs(id)
    WHERE status IN ('queued', 'running');

CREATE FUNCTION silver.enqueue_rollup_backfill(
    target_table TEXT, window_start TIMESTAMPTZ, window_end TIMESTAMPTZ
) RETURNS BIGINT LANGUAGE plpgsql SET search_path = pg_catalog, silver SET timezone = 'UTC' AS $$
DECLARE
    plan JSONB;
    locked_plan JSONB;
    planned_id INTEGER;
    new_job BIGINT;
BEGIN
    SELECT jsonb_agg(to_jsonb(p) || jsonb_build_object('config_snapshot',
        silver._backfill_config_snapshot(p.config_id)) ORDER BY p.step_order)
    INTO plan FROM silver.plan_rollup_backfill(target_table, window_start, window_end) p;

    -- Lock in the same ID order as the scheduled worker. NOWAIT leaves callers
    -- free to retry instead of waiting behind a long ingestion transaction.
    FOR planned_id IN SELECT (p->>'config_id')::integer
        FROM jsonb_array_elements(plan) p ORDER BY (p->>'config_id')::integer
    LOOP
        PERFORM rc.id FROM silver.timeseries_rollup_config rc
            WHERE rc.id = planned_id FOR UPDATE NOWAIT;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Backfill configuration changed while planning; retry the request'
                USING ERRCODE = '40001';
        END IF;
    END LOOP;
    SELECT jsonb_agg(to_jsonb(p) || jsonb_build_object('config_snapshot',
        silver._backfill_config_snapshot(p.config_id)) ORDER BY p.step_order)
    INTO locked_plan FROM silver.plan_rollup_backfill(target_table, window_start, window_end) p;
    IF locked_plan IS DISTINCT FROM plan THEN
        RAISE EXCEPTION 'Backfill configuration changed while planning; retry the request'
            USING ERRCODE = '40001';
    END IF;

    INSERT INTO silver.timeseries_backfill_jobs(target_table, requested_start, requested_end)
    VALUES (silver._qualified_table_name(target_table), window_start, window_end)
    RETURNING id INTO new_job;
    INSERT INTO silver.timeseries_backfill_steps(job_id, step_order, config_id,
        source_table, target_table, range_start, range_end, batch_interval,
        next_start, estimated_batches, config_snapshot)
    SELECT new_job, p.step_order, p.config_id, p.source_table, p.target_table,
        p.range_start, p.range_end, p.batch_interval, p.range_start,
        p.estimated_batches, p.config_snapshot
    FROM jsonb_to_recordset(plan) AS p(step_order integer, config_id integer,
        source_table text, target_table text, range_start timestamptz,
        range_end timestamptz, batch_interval interval, estimated_batches bigint,
        config_snapshot jsonb);
    RETURN new_job;
END;
$$;

CREATE FUNCTION silver.run_rollup_backfills(
    max_batches INTEGER DEFAULT 1, specific_job BIGINT DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql SET search_path = pg_catalog, silver SET timezone = 'UTC' AS $$
DECLARE
    job silver.timeseries_backfill_jobs%ROWTYPE;
    step silver.timeseries_backfill_steps%ROWTYPE;
    planned RECORD;
    relation_name TEXT;
    batch_end TIMESTAMPTZ;
    affected BIGINT;
    attempted INTEGER := 0;
    succeeded INTEGER := 0;
    validation_error TEXT;
BEGIN
    IF max_batches IS NULL OR max_batches < 1 THEN
        RAISE EXCEPTION 'max_batches must be a positive integer' USING ERRCODE = '22023';
    END IF;
    IF specific_job IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM silver.timeseries_backfill_jobs bj WHERE bj.id = specific_job
    ) THEN
        RAISE EXCEPTION 'Unknown backfill job: %', specific_job USING ERRCODE = '22023';
    END IF;

    <<jobs>>
    FOR job IN SELECT bj.* FROM silver.timeseries_backfill_jobs bj
        WHERE bj.status IN ('queued', 'running')
            AND (specific_job IS NULL OR bj.id = specific_job)
        ORDER BY bj.id FOR UPDATE SKIP LOCKED
    LOOP
        -- Claim the whole dependency chain before any replacement. Other jobs,
        -- manual refreshes and scheduled workers use these same row locks.
        BEGIN
            FOR planned IN SELECT bs.config_id FROM silver.timeseries_backfill_steps bs
                WHERE bs.job_id = job.id ORDER BY bs.config_id
            LOOP
                PERFORM rc.id FROM silver.timeseries_rollup_config rc
                    WHERE rc.id = planned.config_id FOR UPDATE NOWAIT;
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'Backfill configuration % no longer exists; enqueue a new plan', planned.config_id
                        USING ERRCODE = '55000';
                END IF;
            END LOOP;
            -- Keep catalog validation and execution on the same relations.
            -- Config locks alone cannot prevent concurrent DROP/CREATE or ALTER.
            -- ONLY avoids eagerly locking every partition; ordinary ingestion
            -- remains compatible with these ACCESS SHARE locks.
            FOR relation_name IN
                SELECT bs.source_table FROM silver.timeseries_backfill_steps bs WHERE bs.job_id = job.id
                UNION
                SELECT bs.target_table FROM silver.timeseries_backfill_steps bs WHERE bs.job_id = job.id
                ORDER BY 1
            LOOP
                EXECUTE format('LOCK TABLE ONLY %s IN ACCESS SHARE MODE NOWAIT',
                    silver._qualified_table_name(relation_name));
            END LOOP;
        EXCEPTION
            WHEN lock_not_available THEN CONTINUE jobs;
            WHEN OTHERS THEN
                UPDATE silver.timeseries_backfill_jobs SET status = 'failed',
                    last_error = SQLERRM, sql_state = SQLSTATE, updated_at = clock_timestamp()
                    WHERE id = job.id;
                attempted := attempted + 1;
                IF attempted >= max_batches THEN EXIT jobs; END IF;
                CONTINUE jobs;
        END;

        BEGIN
            IF NOT EXISTS (SELECT 1 FROM silver.timeseries_backfill_steps bs WHERE bs.job_id = job.id) THEN
                RAISE EXCEPTION 'Backfill job % has no planned steps', job.id USING ERRCODE = '55000';
            END IF;
            FOR planned IN SELECT bs.* FROM silver.timeseries_backfill_steps bs
                WHERE bs.job_id = job.id ORDER BY bs.step_order
            LOOP
                IF silver._backfill_config_snapshot(planned.config_id) IS DISTINCT FROM planned.config_snapshot THEN
                    RAISE EXCEPTION 'Backfill configuration changed for %; cancel this job and enqueue a new plan', planned.target_table
                        USING ERRCODE = '55000';
                END IF;
                SELECT v.validation_message INTO validation_error
                FROM silver._validate_rollup_config(planned.target_table) v WHERE NOT v.is_valid;
                IF FOUND THEN
                    RAISE EXCEPTION 'Invalid backfill structure for %: %', planned.target_table, validation_error
                        USING ERRCODE = '55000';
                END IF;
            END LOOP;
        EXCEPTION WHEN OTHERS THEN
            UPDATE silver.timeseries_backfill_jobs SET status = 'failed',
                last_error = SQLERRM, sql_state = SQLSTATE, updated_at = clock_timestamp()
                WHERE id = job.id;
            attempted := attempted + 1;
            IF attempted >= max_batches THEN EXIT jobs; END IF;
            CONTINUE jobs;
        END;

        WHILE attempted < max_batches LOOP
            SELECT bs.* INTO step FROM silver.timeseries_backfill_steps bs
                WHERE bs.job_id = job.id AND bs.next_start < bs.range_end
                ORDER BY bs.step_order LIMIT 1;
            IF NOT FOUND THEN
                UPDATE silver.timeseries_backfill_jobs SET status = 'completed',
                    updated_at = clock_timestamp(), completed_at = clock_timestamp()
                    WHERE id = job.id;
                EXIT;
            END IF;
            attempted := attempted + 1;
            BEGIN
                batch_end := LEAST(step.range_end, step.next_start + step.batch_interval);
                affected := silver.refresh_rollup(step.target_table, step.next_start, batch_end);
                UPDATE silver.timeseries_backfill_steps SET next_start = batch_end,
                    completed_batches = completed_batches + 1,
                    records_processed = records_processed + affected
                    WHERE job_id = job.id AND step_order = step.step_order;
                UPDATE silver.timeseries_backfill_jobs SET status = 'running',
                    updated_at = clock_timestamp(), last_error = NULL, sql_state = NULL
                    WHERE id = job.id;
                IF NOT EXISTS (SELECT 1 FROM silver.timeseries_backfill_steps bs
                    WHERE bs.job_id = job.id AND bs.next_start < bs.range_end) THEN
                    UPDATE silver.timeseries_backfill_jobs SET status = 'completed',
                        completed_at = clock_timestamp() WHERE id = job.id;
                END IF;
                succeeded := succeeded + 1;
            EXCEPTION WHEN OTHERS THEN
                -- Only the current batch rolls back. Earlier batches in this
                -- call still commit with the caller, together with this error.
                UPDATE silver.timeseries_backfill_jobs SET status = 'failed',
                    last_error = SQLERRM, sql_state = SQLSTATE, updated_at = clock_timestamp()
                    WHERE id = job.id;
                EXIT;
            END;
        END LOOP;
        EXIT WHEN attempted >= max_batches;
    END LOOP jobs;
    RETURN succeeded;
END;
$$;

CREATE FUNCTION silver.resume_rollup_backfill(job_id BIGINT)
RETURNS VOID LANGUAGE plpgsql SET search_path = pg_catalog, silver SET timezone = 'UTC' AS $$
DECLARE current_status TEXT;
BEGIN
    SELECT bj.status INTO current_status FROM silver.timeseries_backfill_jobs bj
        WHERE bj.id = job_id FOR UPDATE NOWAIT;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown backfill job: %', job_id USING ERRCODE = '22023';
    END IF;
    IF current_status IN ('completed', 'cancelled') THEN
        RAISE EXCEPTION 'Cannot resume a % backfill; enqueue a new job', current_status
            USING ERRCODE = '55000';
    END IF;
    IF current_status = 'failed' THEN
        UPDATE silver.timeseries_backfill_jobs SET status = 'queued',
            last_error = NULL, sql_state = NULL, updated_at = clock_timestamp()
            WHERE id = job_id;
    END IF;
END;
$$;

CREATE FUNCTION silver.cancel_rollup_backfill(job_id BIGINT)
RETURNS VOID LANGUAGE plpgsql SET search_path = pg_catalog, silver SET timezone = 'UTC' AS $$
DECLARE current_status TEXT;
BEGIN
    SELECT bj.status INTO current_status FROM silver.timeseries_backfill_jobs bj
        WHERE bj.id = job_id FOR UPDATE NOWAIT;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown backfill job: %', job_id USING ERRCODE = '22023';
    END IF;
    IF current_status = 'completed' THEN
        RAISE EXCEPTION 'Cannot cancel a completed backfill' USING ERRCODE = '55000';
    END IF;
    UPDATE silver.timeseries_backfill_jobs SET status = 'cancelled',
        updated_at = clock_timestamp() WHERE id = job_id;
END;
$$;

CREATE VIEW silver.timeseries_backfill_monitor AS
SELECT bj.id, bj.target_table, bj.status, bj.requested_start, bj.requested_end,
    totals.range_start, totals.range_end, active.target_table AS current_target,
    active.next_start, totals.completed_batches, totals.estimated_batches,
    round(100.0 * totals.completed_batches / NULLIF(totals.estimated_batches, 0), 2) AS progress_percent,
    totals.records_processed, bj.created_at, bj.updated_at, bj.completed_at,
    bj.last_error, bj.sql_state
FROM silver.timeseries_backfill_jobs bj
LEFT JOIN LATERAL (
    SELECT min(bs.range_start) AS range_start, max(bs.range_end) AS range_end,
        sum(bs.completed_batches)::bigint AS completed_batches,
        sum(bs.estimated_batches)::bigint AS estimated_batches,
        sum(bs.records_processed)::bigint AS records_processed
    FROM silver.timeseries_backfill_steps bs WHERE bs.job_id = bj.id
) totals ON true
LEFT JOIN LATERAL (
    SELECT bs.target_table, bs.next_start FROM silver.timeseries_backfill_steps bs
    WHERE bs.job_id = bj.id AND bs.next_start < bs.range_end
    ORDER BY bs.step_order LIMIT 1
) active ON true;

GRANT SELECT, INSERT, UPDATE, DELETE ON silver.timeseries_backfill_jobs,
    silver.timeseries_backfill_steps TO db_ecs_user;
GRANT USAGE, SELECT ON SEQUENCE silver.timeseries_backfill_jobs_id_seq TO db_ecs_user;
GRANT SELECT ON silver.timeseries_backfill_monitor TO db_ecs_user;
GRANT EXECUTE ON FUNCTION silver.enqueue_rollup_backfill(TEXT, TIMESTAMPTZ, TIMESTAMPTZ),
    silver.run_rollup_backfills(INTEGER, BIGINT), silver.resume_rollup_backfill(BIGINT),
    silver.cancel_rollup_backfill(BIGINT) TO db_ecs_user;

COMMENT ON FUNCTION silver.enqueue_rollup_backfill(TEXT, TIMESTAMPTZ, TIMESTAMPTZ) IS
'Freeze a parent-first plan up to the selected target, widening the requested range to its whole buckets. Does not refresh data or change incremental watermarks.';
COMMENT ON FUNCTION silver.run_rollup_backfills(INTEGER, BIGINT) IS
'Execute at most max_batches attempts, returning successful batches. Claims jobs with SKIP LOCKED and their full dependency chain with NOWAIT. Failed jobs require explicit resume. Commit each call to persist progress and release locks.';
COMMENT ON VIEW silver.timeseries_backfill_monitor IS
'Committed historical backfill progress. Percentage is completed batches, not estimated time. A running job has remaining work; it does not imply a worker currently holds it.';
