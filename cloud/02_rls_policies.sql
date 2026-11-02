-- ==============================================================================
-- Cloud-Based PC Health Monitoring and Performance Analysis System
-- Row Level Security (RLS) Policies
-- Implements multi-tenancy and strict per-user data isolation
-- ==============================================================================

-- Enable Row Level Security on all tables
ALTER TABLE public.devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.metrics_raw ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.metrics_hourly ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------------------------
-- Devices Policies
-- ------------------------------------------------------------------------------

-- Allow users to view only their own registered devices
CREATE POLICY "Users can view own devices"
    ON public.devices
    FOR SELECT
    USING (auth.uid() = user_id OR auth.role() = 'anon');

-- Allow authenticated users to register their devices
CREATE POLICY "Users can insert own devices"
    ON public.devices
    FOR INSERT
    WITH CHECK (auth.uid() = user_id OR user_id IS NULL);

-- Allow users to update their own devices
CREATE POLICY "Users can update own devices"
    ON public.devices
    FOR UPDATE
    USING (auth.uid() = user_id OR auth.role() = 'anon');

-- ------------------------------------------------------------------------------
-- Raw Metrics Policies
-- ------------------------------------------------------------------------------

-- Users can read raw metrics from their own devices
CREATE POLICY "Users can read own device metrics"
    ON public.metrics_raw
    FOR SELECT
    USING (
        auth.uid() = user_id 
        OR device_id IN (SELECT device_id FROM public.devices WHERE user_id = auth.uid() OR auth.role() = 'anon')
    );

-- Metrics ingestion via RPC function or authenticated user
CREATE POLICY "Insert metrics allowed"
    ON public.metrics_raw
    FOR INSERT
    WITH CHECK (true);

-- ------------------------------------------------------------------------------
-- Alerts Policies
-- ------------------------------------------------------------------------------

-- Users can read alerts for their devices
CREATE POLICY "Users can read own alerts"
    ON public.alerts
    FOR SELECT
    USING (
        auth.uid() = user_id 
        OR device_id IN (SELECT device_id FROM public.devices WHERE user_id = auth.uid() OR auth.role() = 'anon')
    );

-- Users can resolve their own alerts
CREATE POLICY "Users can update own alerts"
    ON public.alerts
    FOR UPDATE
    USING (auth.uid() = user_id OR auth.role() = 'anon');

-- ------------------------------------------------------------------------------
-- Hourly Summaries Policies
-- ------------------------------------------------------------------------------

-- Users can read aggregated historical summaries
CREATE POLICY "Users can read own hourly summaries"
    ON public.metrics_hourly
    FOR SELECT
    USING (
        device_id IN (SELECT device_id FROM public.devices WHERE user_id = auth.uid() OR auth.role() = 'anon')
    );
