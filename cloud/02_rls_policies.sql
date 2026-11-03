-- ==============================================================================
-- Cloud-Based PC Health Monitoring and Performance Analysis System (AEROSYS)
-- Row Level Security (RLS) Policies & Database-Enforced Authorization
-- Defends against IDOR, device impersonation, and unauthorized telemetry queries.
-- ==============================================================================

-- Enable Row Level Security on all tables
ALTER TABLE public.devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.device_auth ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.device_enrollment_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.metrics_raw ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.metrics_hourly ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------------------------
-- 1. Security Gatekeeper: check_device_read_authorization()
-- Enforces authorization at the PostgreSQL engine level for both REST and Realtime.
-- Validates that the caller is either:
--   a) The authenticated user owning the machine (Supabase Auth: auth.uid() = user_id).
--   b) A viewer possessing the machine's private dashboard_token (via x-dashboard-token header or JWT claim).
-- Any request attempting to access an unauthorized or revoked device_id is REJECTED (returns FALSE).
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_device_read_authorization(check_device_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    v_user_id UUID;
    v_token TEXT;
    v_token_hash TEXT;
    v_headers JSONB;
BEGIN
    -- [Path A]: Authenticated User via Supabase Auth (Strict User Isolation)
    v_user_id := auth.uid();
    IF v_user_id IS NOT NULL THEN
        IF EXISTS (SELECT 1 FROM public.devices WHERE device_id = check_device_id AND user_id = v_user_id) THEN
            RETURN TRUE;
        END IF;
    END IF;

    -- [Path B]: Dashboard Viewer Token Verification (Anti-IDOR Protection)
    -- Inspects the HTTP request header 'x-dashboard-token' or JWT claims
    BEGIN
        v_headers := current_setting('request.headers', true)::jsonb;
        v_token := v_headers->>'x-dashboard-token';
    EXCEPTION WHEN OTHERS THEN
        v_token := NULL;
    END;

    -- Check JWT claims as well for authenticated Realtime/WebSocket connections
    IF v_token IS NULL THEN
        BEGIN
            v_headers := current_setting('request.jwt.claims', true)::jsonb;
            v_token := v_headers->>'dashboard_token';
            IF v_token IS NULL THEN
                v_token := v_headers->'app_metadata'->>'dashboard_token';
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_token := NULL;
        END;
    END IF;

    IF v_token IS NOT NULL AND length(trim(v_token)) >= 16 THEN
        v_token_hash := encode(digest(trim(v_token), 'sha256'), 'hex');
        -- Device must be active and match the registered dashboard_token_hash
        IF EXISTS (
            SELECT 1 FROM public.device_auth 
            WHERE device_id = check_device_id 
              AND dashboard_token_hash = v_token_hash 
              AND status = 'active'
        ) THEN
            RETURN TRUE;
        END IF;
    END IF;

    -- Access Denied: Caller does not possess valid credentials for this device_id
    -- Enforces strict zero-trust: unauthorized anonymous CDC subscriptions are denied.
    RETURN FALSE;
END;
$$;

-- ------------------------------------------------------------------------------
-- 2. Sensitive Security Tables: device_auth & device_enrollment_tokens
-- ------------------------------------------------------------------------------
-- STRICT ZERO-TRUST: No policies granted to public roles (anon/authenticated).
-- Completely invisible through Supabase PostgREST REST endpoints.
-- Only SECURITY DEFINER functions (ingest_readings) and service_role can access.

-- ------------------------------------------------------------------------------
-- 3. Devices Policies (Anti-IDOR and Anti-Tampering)
-- ------------------------------------------------------------------------------

-- Allow reading device specs ONLY if authorized for this specific device
DROP POLICY IF EXISTS "Users can view own devices" ON public.devices;
CREATE POLICY "Users can view own devices"
    ON public.devices
    FOR SELECT
    USING (
        public.check_device_read_authorization(device_id)
    );

-- Prevent unauthorized direct device insertions via REST API.
DROP POLICY IF EXISTS "Users can insert own devices" ON public.devices;
CREATE POLICY "Users can insert own devices"
    ON public.devices
    FOR INSERT
    TO authenticated
    WITH CHECK (auth.uid() = user_id);

-- Prevent unauthorized direct modifications via REST API.
DROP POLICY IF EXISTS "Users can update own devices" ON public.devices;
CREATE POLICY "Users can update own devices"
    ON public.devices
    FOR UPDATE
    TO authenticated
    USING (auth.uid() = user_id);

-- ------------------------------------------------------------------------------
-- 4. Raw Metrics Policies (Database-Enforced Telemetry Isolation)
-- ------------------------------------------------------------------------------

-- Users can read metrics ONLY from devices they are authorized to view
DROP POLICY IF EXISTS "Users can read own device metrics" ON public.metrics_raw;
CREATE POLICY "Users can read own device metrics"
    ON public.metrics_raw
    FOR SELECT
    USING (
        public.check_device_read_authorization(device_id)
    );

-- SECURITY ENFORCEMENT: Direct anonymous REST INSERT into metrics_raw is REVOKED.
-- Telemetry must arrive exclusively through the authenticated ingest_readings() RPC.
DROP POLICY IF EXISTS "Insert metrics allowed" ON public.metrics_raw;

-- ------------------------------------------------------------------------------
-- 5. Alerts Policies
-- ------------------------------------------------------------------------------

-- Users can read alerts ONLY from devices they are authorized to view
DROP POLICY IF EXISTS "Users can read own alerts" ON public.alerts;
CREATE POLICY "Users can read own alerts"
    ON public.alerts
    FOR SELECT
    USING (
        public.check_device_read_authorization(device_id)
    );

-- Only authenticated users owning the machine can resolve alerts
DROP POLICY IF EXISTS "Users can update own alerts" ON public.alerts;
CREATE POLICY "Users can update own alerts"
    ON public.alerts
    FOR UPDATE
    TO authenticated
    USING (auth.uid() = user_id);

-- ------------------------------------------------------------------------------
-- 6. Hourly Summaries Policies
-- ------------------------------------------------------------------------------

DROP POLICY IF EXISTS "Users can read own hourly summaries" ON public.metrics_hourly;
CREATE POLICY "Users can read own hourly summaries"
    ON public.metrics_hourly
    FOR SELECT
    USING (
        public.check_device_read_authorization(device_id)
    );
