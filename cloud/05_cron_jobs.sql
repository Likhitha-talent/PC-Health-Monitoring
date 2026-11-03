-- ==============================================================================
-- Cloud-Based PC Health Monitoring and Performance Analysis System
-- pg_cron Scheduled Jobs: Lifecycle Management & Hourly Aggregation
-- ==============================================================================

-- 1. Enable pg_cron extension (Available on Supabase Free Tier)
-- Note: In Supabase, pg_cron can also be toggled in Dashboard -> Database -> Extensions.
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- 2. Aggregation Function: Aggregates metrics into hourly rollups
CREATE OR REPLACE FUNCTION public.aggregate_hourly_metrics()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    INSERT INTO public.metrics_hourly (
        device_id,
        hour_timestamp,
        sample_count,
        avg_cpu,
        max_cpu,
        min_cpu,
        avg_ram,
        max_ram,
        avg_disk,
        max_disk
    )
    SELECT 
        device_id,
        date_trunc('hour', client_timestamp) AS hour_timestamp,
        COUNT(*) AS sample_count,
        ROUND(AVG(cpu_percent), 2) AS avg_cpu,
        ROUND(MAX(cpu_percent), 2) AS max_cpu,
        ROUND(MIN(cpu_percent), 2) AS min_cpu,
        ROUND(AVG(ram_percent), 2) AS avg_ram,
        ROUND(MAX(ram_percent), 2) AS max_ram,
        ROUND(AVG(disk_percent), 2) AS avg_disk,
        ROUND(MAX(disk_percent), 2) AS max_disk
    FROM public.metrics_raw
    WHERE client_timestamp >= (NOW() - INTERVAL '2 hours')
      AND client_timestamp < date_trunc('hour', NOW())
    GROUP BY device_id, date_trunc('hour', client_timestamp)
    ON CONFLICT (device_id, hour_timestamp) DO UPDATE SET
        sample_count = EXCLUDED.sample_count,
        avg_cpu = EXCLUDED.avg_cpu,
        max_cpu = EXCLUDED.max_cpu,
        min_cpu = EXCLUDED.min_cpu,
        avg_ram = EXCLUDED.avg_ram,
        max_ram = EXCLUDED.max_ram,
        avg_disk = EXCLUDED.avg_disk,
        max_disk = EXCLUDED.max_disk;
END;
$$;

-- 3. Data Retention Pruning Function: Removes raw metrics older than 7 days
CREATE OR REPLACE FUNCTION public.purge_expired_raw_metrics()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_deleted_count INTEGER;
BEGIN
    DELETE FROM public.metrics_raw
    WHERE client_timestamp < (NOW() - INTERVAL '7 days');
    
    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    RETURN v_deleted_count;
END;
$$;

-- 4. Schedule pg_cron jobs safely
DO $$
BEGIN
    -- Verify pg_cron is installed and cron.job table is accessible
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        -- Unschedule existing jobs with same names if re-running
        PERFORM cron.unschedule(jobid) 
        FROM cron.job 
        WHERE jobname IN ('hourly_metrics_rollup', 'purge_raw_metrics_7days');

        -- Job A: Hourly rollup runs 5 minutes past every hour ('5 * * * *')
        PERFORM cron.schedule(
            'hourly_metrics_rollup',
            '5 * * * *',
            'SELECT public.aggregate_hourly_metrics();'
        );

        -- Job B: Retention purge runs every night at 03:00 UTC ('0 3 * * *')
        PERFORM cron.schedule(
            'purge_raw_metrics_7days',
            '0 3 * * *',
            'SELECT public.purge_expired_raw_metrics();'
        );
    END IF;
END $$;
