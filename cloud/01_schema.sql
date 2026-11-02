-- ==============================================================================
-- Cloud-Based PC Health Monitoring and Performance Analysis System
-- Schema Definition (PostgreSQL / Supabase)
-- ==============================================================================

-- 1. Enable UUID Extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 2. Registered Devices Table
CREATE TABLE IF NOT EXISTS public.devices (
    device_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    hostname TEXT NOT NULL,
    os_info TEXT NOT NULL,
    cpu_model TEXT,
    cpu_cores INTEGER DEFAULT 1,
    ram_total_gb NUMERIC(6, 2) NOT NULL,
    disk_total_gb NUMERIC(6, 2) NOT NULL,
    ip_address TEXT,
    agent_version TEXT DEFAULT '1.0.0',
    is_active BOOLEAN DEFAULT TRUE,
    last_seen_at TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3. Raw Metrics Table (High frequency: collected every 5s, batch uploaded every 60s)
CREATE TABLE IF NOT EXISTS public.metrics_raw (
    id BIGSERIAL PRIMARY KEY,
    device_id UUID NOT NULL REFERENCES public.devices(device_id) ON DELETE CASCADE,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    cpu_percent NUMERIC(5, 2) NOT NULL,
    cpu_freq_mhz NUMERIC(7, 2),
    ram_percent NUMERIC(5, 2) NOT NULL,
    ram_used_gb NUMERIC(6, 2) NOT NULL,
    disk_percent NUMERIC(5, 2) NOT NULL,
    disk_used_gb NUMERIC(6, 2) NOT NULL,
    battery_percent NUMERIC(5, 2),
    battery_plugged BOOLEAN,
    battery_secs_left BIGINT,
    net_sent_kb NUMERIC(14, 2) DEFAULT 0,
    net_recv_kb NUMERIC(14, 2) DEFAULT 0,
    client_timestamp TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes for lightning-fast queries
CREATE INDEX IF NOT EXISTS idx_metrics_raw_device_time 
    ON public.metrics_raw(device_id, client_timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_metrics_raw_user 
    ON public.metrics_raw(user_id);
CREATE INDEX IF NOT EXISTS idx_metrics_raw_created 
    ON public.metrics_raw(created_at DESC);

-- 4. Alerts Table (Event-driven triggers populate this when thresholds are breached)
CREATE TABLE IF NOT EXISTS public.alerts (
    id BIGSERIAL PRIMARY KEY,
    device_id UUID NOT NULL REFERENCES public.devices(device_id) ON DELETE CASCADE,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    severity TEXT NOT NULL CHECK (severity IN ('info', 'warning', 'critical')),
    metric_type TEXT NOT NULL, -- 'CPU', 'RAM', 'DISK', 'BATTERY'
    metric_value NUMERIC(6, 2) NOT NULL,
    threshold_value NUMERIC(6, 2) NOT NULL,
    message TEXT NOT NULL,
    is_resolved BOOLEAN DEFAULT FALSE,
    resolved_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_alerts_device_resolved 
    ON public.alerts(device_id, is_resolved, created_at DESC);

-- 5. Hourly Summaries Table (Lifecycle Management & Long-term Analytics)
CREATE TABLE IF NOT EXISTS public.metrics_hourly (
    id BIGSERIAL PRIMARY KEY,
    device_id UUID NOT NULL REFERENCES public.devices(device_id) ON DELETE CASCADE,
    hour_timestamp TIMESTAMPTZ NOT NULL,
    sample_count INTEGER NOT NULL,
    avg_cpu NUMERIC(5, 2) NOT NULL,
    max_cpu NUMERIC(5, 2) NOT NULL,
    min_cpu NUMERIC(5, 2) NOT NULL,
    avg_ram NUMERIC(5, 2) NOT NULL,
    max_ram NUMERIC(5, 2) NOT NULL,
    avg_disk NUMERIC(5, 2) NOT NULL,
    max_disk NUMERIC(5, 2) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT uq_device_hour UNIQUE(device_id, hour_timestamp)
);

CREATE INDEX IF NOT EXISTS idx_metrics_hourly_device_hour 
    ON public.metrics_hourly(device_id, hour_timestamp DESC);
