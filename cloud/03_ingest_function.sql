-- ==============================================================================
-- Cloud-Based PC Health Monitoring and Performance Analysis System
-- Ingestion API Function: ingest_readings()
-- Demonstrates Loose Coupling: Desktop Agent interfaces only with this cloud RPC
-- ==============================================================================

CREATE OR REPLACE FUNCTION public.ingest_readings(
    p_device_id UUID,
    p_hostname TEXT,
    p_os_info TEXT,
    p_cpu_model TEXT,
    p_cpu_cores INTEGER,
    p_ram_total_gb NUMERIC,
    p_disk_total_gb NUMERIC,
    p_readings JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_inserted_count INTEGER := 0;
    v_reading JSONB;
BEGIN
    -- 1. Upsert Device Record & update heartbeat (last_seen_at)
    INSERT INTO public.devices (
        device_id,
        hostname,
        os_info,
        cpu_model,
        cpu_cores,
        ram_total_gb,
        disk_total_gb,
        last_seen_at,
        updated_at
    )
    VALUES (
        p_device_id,
        p_hostname,
        p_os_info,
        p_cpu_model,
        p_cpu_cores,
        p_ram_total_gb,
        p_disk_total_gb,
        NOW(),
        NOW()
    )
    ON CONFLICT (device_id) DO UPDATE SET
        hostname = EXCLUDED.hostname,
        os_info = EXCLUDED.os_info,
        cpu_model = COALESCE(EXCLUDED.cpu_model, devices.cpu_model),
        cpu_cores = COALESCE(EXCLUDED.cpu_cores, devices.cpu_cores),
        ram_total_gb = EXCLUDED.ram_total_gb,
        disk_total_gb = EXCLUDED.disk_total_gb,
        last_seen_at = NOW(),
        updated_at = NOW();

    -- 2. Bulk Insert Metrics Readings from JSON Array
    IF p_readings IS NOT NULL AND jsonb_array_length(p_readings) > 0 THEN
        FOR v_reading IN SELECT * FROM jsonb_array_elements(p_readings)
        LOOP
            INSERT INTO public.metrics_raw (
                device_id,
                cpu_percent,
                cpu_freq_mhz,
                ram_percent,
                ram_used_gb,
                disk_percent,
                disk_used_gb,
                battery_percent,
                battery_plugged,
                battery_secs_left,
                net_sent_kb,
                net_recv_kb,
                client_timestamp
            ) VALUES (
                p_device_id,
                (v_reading->>'cpu_percent')::NUMERIC,
                (v_reading->>'cpu_freq_mhz')::NUMERIC,
                (v_reading->>'ram_percent')::NUMERIC,
                (v_reading->>'ram_used_gb')::NUMERIC,
                (v_reading->>'disk_percent')::NUMERIC,
                (v_reading->>'disk_used_gb')::NUMERIC,
                (v_reading->>'battery_percent')::NUMERIC,
                (v_reading->>'battery_plugged')::BOOLEAN,
                (v_reading->>'battery_secs_left')::BIGINT,
                COALESCE((v_reading->>'net_sent_kb')::NUMERIC, 0),
                COALESCE((v_reading->>'net_recv_kb')::NUMERIC, 0),
                COALESCE((v_reading->>'client_timestamp')::TIMESTAMPTZ, NOW())
            );
            v_inserted_count := v_inserted_count + 1;
        END LOOP;
    END IF;

    -- 3. Return JSON response to client
    RETURN jsonb_build_object(
        'success', TRUE,
        'device_id', p_device_id,
        'records_ingested', v_inserted_count,
        'server_timestamp', NOW()
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'error', SQLERRM,
            'server_timestamp', NOW()
        );
END;
$$;

-- Grant execution permission to anon and authenticated roles
GRANT EXECUTE ON FUNCTION public.ingest_readings TO anon, authenticated, service_role;
