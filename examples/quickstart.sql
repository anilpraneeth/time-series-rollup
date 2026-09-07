\set ON_ERROR_STOP on
\pset null '(null)'
SET TIME ZONE 'UTC';

-- This repeatable example owns only raw.demo_readings and silver.demo_hourly.
-- Use a development database: fixtures have fixed historical timestamps.
CREATE TABLE IF NOT EXISTS raw.demo_readings (
    timestamp timestamptz NOT NULL,
    device text NOT NULL,
    temperature integer,
    power numeric(12, 2),
    PRIMARY KEY (timestamp, device)
);

INSERT INTO silver.timeseries_dimension_config (source_table, dimension_column, description)
VALUES ('raw.demo_readings', 'device', 'Demo device identifier')
ON CONFLICT (source_table, dimension_column) DO NOTHING;

DO $demo$
BEGIN
    IF to_regclass('silver.demo_hourly') IS NULL THEN
        PERFORM silver.create_rollup_table(
            source_table_name := 'raw.demo_readings',
            target_schema := 'silver',
            target_table_name := 'demo_hourly',
            rollup_table_interval := interval '1 hour',
            look_back_window := interval '5 minutes',
            retention_period := interval '30 days',
            processing_window := interval '1 day',
            initial_status := 'idle',
            is_active := false
        );
    END IF;
END
$demo$;

INSERT INTO raw.demo_readings (timestamp, device, temperature, power)
VALUES
    ('2025-01-01 00:05:00+00', 'sensor-a', 20, 1.00),
    ('2025-01-01 00:35:00+00', 'sensor-a', 21, 2.00),
    ('2025-01-01 00:10:00+00', 'sensor-b', 18, 0.50),
    ('2025-01-01 01:05:00+00', 'sensor-a', 22, 3.00),
    ('2025-01-01 01:35:00+00', 'sensor-a', NULL, 4.00)
ON CONFLICT (timestamp, device) DO UPDATE
SET temperature = excluded.temperature, power = excluded.power;

-- Explicit refresh accepts complete bucket bounds, with an exclusive end.
SELECT silver.refresh_rollup(
    'silver.demo_hourly', '2025-01-01 00:00:00+00', '2025-01-01 02:00:00+00'
) AS refreshed_groups;

SELECT timestamp, device, min_temperature, max_temperature, avg_temperature,
       min_power, max_power, avg_power, rollup_count
FROM silver.demo_hourly
ORDER BY timestamp, device;

-- Late corrections are safe: refreshing replaces the same complete buckets.
UPDATE raw.demo_readings SET temperature = 23
WHERE timestamp = '2025-01-01 00:35:00+00' AND device = 'sensor-a';
SELECT silver.refresh_rollup(
    'silver.demo_hourly', '2025-01-01 00:00:00+00', '2025-01-01 01:00:00+00'
) AS corrected_groups;

SELECT timestamp, device, avg_temperature, rollup_count
FROM silver.demo_hourly
ORDER BY timestamp, device;
