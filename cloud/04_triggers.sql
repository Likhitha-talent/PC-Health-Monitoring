-- ==============================================================================
-- Cloud-Based PC Health Monitoring and Performance Analysis System
-- Event-Driven Database Triggers & Real-time Alerts
-- Demonstrates Event-Driven Architecture & Realtime Pub/Sub
-- ==============================================================================

-- 1. Trigger function: Evaluates metrics thresholds after every incoming raw reading
CREATE OR REPLACE FUNCTION public.evaluate_reading_thresholds()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- [CPU Alert Evaluation]
    IF NEW.cpu_percent >= 90.0 THEN
        INSERT INTO public.alerts (
            device_id, user_id, severity, metric_type, metric_value, threshold_value, message
        ) VALUES (
            NEW.device_id, NEW.user_id, 'critical', 'CPU', NEW.cpu_percent, 90.0,
            'Critical CPU spike detected: ' || NEW.cpu_percent || '% utilization'
        );
    ELSIF NEW.cpu_percent >= 80.0 THEN
        INSERT INTO public.alerts (
            device_id, user_id, severity, metric_type, metric_value, threshold_value, message
        ) VALUES (
            NEW.device_id, NEW.user_id, 'warning', 'CPU', NEW.cpu_percent, 80.0,
            'High CPU load detected: ' || NEW.cpu_percent || '% utilization'
        );
    END IF;

    -- [RAM Alert Evaluation]
    IF NEW.ram_percent >= 90.0 THEN
        INSERT INTO public.alerts (
            device_id, user_id, severity, metric_type, metric_value, threshold_value, message
        ) VALUES (
            NEW.device_id, NEW.user_id, 'critical', 'RAM', NEW.ram_percent, 90.0,
            'Critical Memory exhaustion: ' || NEW.ram_percent || '% (' || NEW.ram_used_gb || ' GB used)'
        );
    ELSIF NEW.ram_percent >= 85.0 THEN
        INSERT INTO public.alerts (
            device_id, user_id, severity, metric_type, metric_value, threshold_value, message
        ) VALUES (
            NEW.device_id, NEW.user_id, 'warning', 'RAM', NEW.ram_percent, 85.0,
            'Elevated RAM usage: ' || NEW.ram_percent || '% (' || NEW.ram_used_gb || ' GB used)'
        );
    END IF;

    -- [Disk Alert Evaluation]
    IF NEW.disk_percent >= 92.0 THEN
        INSERT INTO public.alerts (
            device_id, user_id, severity, metric_type, metric_value, threshold_value, message
        ) VALUES (
            NEW.device_id, NEW.user_id, 'critical', 'DISK', NEW.disk_percent, 92.0,
            'Disk storage almost full: ' || NEW.disk_percent || '% capacity used'
        );
    ELSIF NEW.disk_percent >= 85.0 THEN
        INSERT INTO public.alerts (
            device_id, user_id, severity, metric_type, metric_value, threshold_value, message
        ) VALUES (
            NEW.device_id, NEW.user_id, 'warning', 'DISK', NEW.disk_percent, 85.0,
            'Disk space running low: ' || NEW.disk_percent || '% capacity used'
        );
    END IF;

    -- [Battery Alert Evaluation]
    IF NEW.battery_percent IS NOT NULL AND NEW.battery_percent <= 15.0 AND (NEW.battery_plugged = FALSE OR NEW.battery_plugged IS NULL) THEN
        INSERT INTO public.alerts (
            device_id, user_id, severity, metric_type, metric_value, threshold_value, message
        ) VALUES (
            NEW.device_id, NEW.user_id, 'critical', 'BATTERY', NEW.battery_percent, 15.0,
            'Battery critically low (' || NEW.battery_percent || '%). Connect AC power adapter.'
        );
    END IF;

    RETURN NEW;
END;
$$;

-- 2. Attach Trigger to metrics_raw table
DROP TRIGGER IF EXISTS trg_evaluate_reading_thresholds ON public.metrics_raw;

CREATE TRIGGER trg_evaluate_reading_thresholds
    AFTER INSERT ON public.metrics_raw
    FOR EACH ROW
    EXECUTE FUNCTION public.evaluate_reading_thresholds();

-- 3. Enable Supabase Realtime for instant pub/sub push to Dashboard
-- Supabase uses Postgres logical replication to broadcast table changes
DO $$
BEGIN
    -- Add public.alerts to realtime publication
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables 
        WHERE pubname = 'supabase_realtime' AND tablename = 'alerts'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.alerts;
    END IF;

    -- Add public.metrics_raw to realtime publication for instant live graph updates
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables 
        WHERE pubname = 'supabase_realtime' AND tablename = 'metrics_raw'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.metrics_raw;
    END IF;

    -- Add public.devices to realtime publication for device heartbeat / status changes
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables 
        WHERE pubname = 'supabase_realtime' AND tablename = 'devices'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.devices;
    END IF;
END $$;
