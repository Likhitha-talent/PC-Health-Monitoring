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
SET search_path = public, pg_temp
AS $$
BEGIN
    -- [CPU Alert Evaluation]
    IF NEW.cpu_percent >= 90.0 THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.alerts 
            WHERE device_id = NEW.device_id 
              AND metric_type = 'CPU' 
              AND severity = 'critical'
              AND created_at >= (NOW() - INTERVAL '60 seconds')
        ) THEN
            INSERT INTO public.alerts (
                device_id, user_id, severity, metric_type, metric_value, threshold_value, message
            ) VALUES (
                NEW.device_id, NEW.user_id, 'critical', 'CPU', NEW.cpu_percent, 90.0,
                'Critical CPU spike detected: ' || NEW.cpu_percent || '% utilization'
            );
        END IF;
    ELSIF NEW.cpu_percent >= 80.0 THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.alerts 
            WHERE device_id = NEW.device_id 
              AND metric_type = 'CPU' 
              AND severity = 'warning'
              AND created_at >= (NOW() - INTERVAL '60 seconds')
        ) THEN
            INSERT INTO public.alerts (
                device_id, user_id, severity, metric_type, metric_value, threshold_value, message
            ) VALUES (
                NEW.device_id, NEW.user_id, 'warning', 'CPU', NEW.cpu_percent, 80.0,
                'High CPU load detected: ' || NEW.cpu_percent || '% utilization'
            );
        END IF;
    END IF;

    -- [RAM Alert Evaluation]
    IF NEW.ram_percent >= 90.0 THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.alerts 
            WHERE device_id = NEW.device_id 
              AND metric_type = 'RAM' 
              AND severity = 'critical'
              AND created_at >= (NOW() - INTERVAL '60 seconds')
        ) THEN
            INSERT INTO public.alerts (
                device_id, user_id, severity, metric_type, metric_value, threshold_value, message
            ) VALUES (
                NEW.device_id, NEW.user_id, 'critical', 'RAM', NEW.ram_percent, 90.0,
                'Critical Memory exhaustion: ' || NEW.ram_percent || '% (' || NEW.ram_used_gb || ' GB used)'
            );
        END IF;
    ELSIF NEW.ram_percent >= 85.0 THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.alerts 
            WHERE device_id = NEW.device_id 
              AND metric_type = 'RAM' 
              AND severity = 'warning'
              AND created_at >= (NOW() - INTERVAL '60 seconds')
        ) THEN
            INSERT INTO public.alerts (
                device_id, user_id, severity, metric_type, metric_value, threshold_value, message
            ) VALUES (
                NEW.device_id, NEW.user_id, 'warning', 'RAM', NEW.ram_percent, 85.0,
                'Elevated RAM usage: ' || NEW.ram_percent || '% (' || NEW.ram_used_gb || ' GB used)'
            );
        END IF;
    END IF;

    -- [Disk Alert Evaluation]
    IF NEW.disk_percent >= 92.0 THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.alerts 
            WHERE device_id = NEW.device_id 
              AND metric_type = 'DISK' 
              AND severity = 'critical'
              AND created_at >= (NOW() - INTERVAL '60 seconds')
        ) THEN
            INSERT INTO public.alerts (
                device_id, user_id, severity, metric_type, metric_value, threshold_value, message
            ) VALUES (
                NEW.device_id, NEW.user_id, 'critical', 'DISK', NEW.disk_percent, 92.0,
                'Disk storage almost full: ' || NEW.disk_percent || '% capacity used'
            );
        END IF;
    ELSIF NEW.disk_percent >= 85.0 THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.alerts 
            WHERE device_id = NEW.device_id 
              AND metric_type = 'DISK' 
              AND severity = 'warning'
              AND created_at >= (NOW() - INTERVAL '60 seconds')
        ) THEN
            INSERT INTO public.alerts (
                device_id, user_id, severity, metric_type, metric_value, threshold_value, message
            ) VALUES (
                NEW.device_id, NEW.user_id, 'warning', 'DISK', NEW.disk_percent, 85.0,
                'Disk space running low: ' || NEW.disk_percent || '% capacity used'
            );
        END IF;
    END IF;

    -- [Battery Alert Evaluation]
    IF NEW.battery_percent IS NOT NULL AND NEW.battery_percent <= 15.0 AND (NEW.battery_plugged = FALSE OR NEW.battery_plugged IS NULL) THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.alerts 
            WHERE device_id = NEW.device_id 
              AND metric_type = 'BATTERY' 
              AND severity = 'critical'
              AND created_at >= (NOW() - INTERVAL '60 seconds')
        ) THEN
            INSERT INTO public.alerts (
                device_id, user_id, severity, metric_type, metric_value, threshold_value, message
            ) VALUES (
                NEW.device_id, NEW.user_id, 'critical', 'BATTERY', NEW.battery_percent, 15.0,
                'Battery critically low (' || NEW.battery_percent || '%). Connect AC power adapter.'
            );
        END IF;
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
    -- Ensure publication exists
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime'
    ) THEN
        CREATE PUBLICATION supabase_realtime;
    END IF;

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
