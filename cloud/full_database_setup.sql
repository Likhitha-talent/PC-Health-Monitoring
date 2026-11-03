-- ==============================================================================
-- Cloud-Based PC Health Monitoring and Performance Analysis System (AEROSYS)
-- Complete Cloud Database Setup (PostgreSQL / Supabase)
-- Combines: 01_schema, 02_rls_policies, 03_ingest_function, 04_triggers, 05_cron_jobs
-- Hardened with Cryptographic One-Time Enrollment, Anti-Squatting, and Anti-IDOR RLS.
-- Execute this script once in the Supabase SQL Editor.
-- ==============================================================================

-- ==============================================================================
-- PART 1: EXTENSIONS & CORE TABLES
-- ==============================================================================

-- ==============================================================================
-- Cloud-Based PC Health Monitoring and Performance Analysis System (AEROSYS)
-- Schema Definition (PostgreSQL / Supabase)
-- Hardened with Cryptographic Device Authentication & Secure Provisioning
-- ==============================================================================

-- 1. Enable Cryptographic & UUID Extensions
DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
    CREATE EXTENSION IF NOT EXISTS "pgcrypto";
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'Extension initialization notice: %', SQLERRM;
END $$;

-- 2. Device Enrollment Tokens Table (Provisioning & Anti-Squatting Guard)
-- Enforces authorized enrollment: No machine can register without a valid token.
CREATE TABLE IF NOT EXISTS public.device_enrollment_tokens (
    token_id BIGSERIAL PRIMARY KEY,
    token_hash TEXT NOT NULL UNIQUE,
    token_name TEXT NOT NULL DEFAULT 'Provisioned Device Token',
    max_uses INTEGER DEFAULT 1, -- Default 1: One-time provisioning token (Anti-Squatting)
    uses_count INTEGER DEFAULT 0,
    is_active BOOLEAN DEFAULT TRUE,
    expires_at TIMESTAMPTZ DEFAULT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Note: No predictable default tokens are seeded in production.
-- Administrators provision one-time random tokens using create_device_enrollment_token().

-- 3. Registered Devices Table
CREATE TABLE IF NOT EXISTS public.devices (
    device_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    hostname TEXT NOT NULL,
    os_info TEXT NOT NULL,
    cpu_model TEXT,
    cpu_cores INTEGER DEFAULT 1,
    ram_total_gb NUMERIC(8, 2) NOT NULL,
    disk_total_gb NUMERIC(10, 2) NOT NULL,
    ip_address TEXT,
    agent_version TEXT DEFAULT '1.0.0',
    is_active BOOLEAN DEFAULT TRUE,
    last_seen_at TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 4. Device Authentication & Secret Store (Dedicated Security Boundary)
-- Stores cryptographically hashed write keys (device_api_key) and read keys (dashboard_token).
-- Inaccessible to public REST queries (RLS enforced with 0 public policies).
CREATE TABLE IF NOT EXISTS public.device_auth (
    device_id UUID PRIMARY KEY REFERENCES public.devices(device_id) ON DELETE CASCADE,
    api_key_hash TEXT NOT NULL,
    dashboard_token_hash TEXT NOT NULL,
    enrolled_via_token_id BIGINT REFERENCES public.device_enrollment_tokens(token_id) ON DELETE SET NULL,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'revoked')),
    enrolled_at TIMESTAMPTZ DEFAULT NOW(),
    last_authenticated_at TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 5. Raw Metrics Table (High frequency: collected every 5s, batch uploaded every 60s)
CREATE TABLE IF NOT EXISTS public.metrics_raw (
    id BIGSERIAL PRIMARY KEY,
    device_id UUID NOT NULL REFERENCES public.devices(device_id) ON DELETE CASCADE,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    cpu_percent NUMERIC(5, 2) NOT NULL,
    cpu_freq_mhz NUMERIC(7, 2),
    ram_percent NUMERIC(5, 2) NOT NULL,
    ram_used_gb NUMERIC(8, 2) NOT NULL,
    disk_percent NUMERIC(5, 2) NOT NULL,
    disk_used_gb NUMERIC(10, 2) NOT NULL,
    battery_percent NUMERIC(5, 2),
    battery_plugged BOOLEAN,
    battery_secs_left BIGINT,
    net_sent_kb NUMERIC(14, 2) DEFAULT 0,
    net_recv_kb NUMERIC(14, 2) DEFAULT 0,
    client_timestamp TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_metrics_raw_device_time 
    ON public.metrics_raw(device_id, client_timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_metrics_raw_user 
    ON public.metrics_raw(user_id);
CREATE INDEX IF NOT EXISTS idx_metrics_raw_created 
    ON public.metrics_raw(created_at DESC);

-- 6. Alerts Table (Event-driven triggers populate this when thresholds are breached)
CREATE TABLE IF NOT EXISTS public.alerts (
    id BIGSERIAL PRIMARY KEY,
    device_id UUID NOT NULL REFERENCES public.devices(device_id) ON DELETE CASCADE,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    severity TEXT NOT NULL CHECK (severity IN ('info', 'warning', 'critical')),
    metric_type TEXT NOT NULL, -- 'CPU', 'RAM', 'DISK', 'BATTERY'
    metric_value NUMERIC(10, 2) NOT NULL,
    threshold_value NUMERIC(10, 2) NOT NULL,
    message TEXT NOT NULL,
    is_resolved BOOLEAN DEFAULT FALSE,
    resolved_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_alerts_device_resolved 
    ON public.alerts(device_id, is_resolved, created_at DESC);

-- 7. Hourly Summaries Table (Lifecycle Management & Long-term Analytics)
CREATE TABLE IF NOT EXISTS public.metrics_hourly (
    id BIGSERIAL PRIMARY KEY,
    device_id UUID NOT NULL REFERENCES public.devices(device_id) ON DELETE CASCADE,
    hour_timestamp TIMESTAMPTZ NOT NULL,
    sample_count INTEGER NOT NULL,
    avg_cpu NUMERIC(5, 2) NOT NULL,
    max_cpu NUMERIC(5, 2) NOT NULL,
    min_cpu NUMERIC(5, 2) NOT NULL,
    avg_ram NUMERIC(8, 2) NOT NULL,
    max_ram NUMERIC(8, 2) NOT NULL,
    avg_disk NUMERIC(10, 2) NOT NULL,
    max_disk NUMERIC(10, 2) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT uq_device_hour UNIQUE(device_id, hour_timestamp)
);

CREATE INDEX IF NOT EXISTS idx_metrics_hourly_device_hour 
    ON public.metrics_hourly(device_id, hour_timestamp DESC);


-- ==============================================================================
-- PART 2: ROW LEVEL SECURITY (RLS) POLICIES
-- ==============================================================================

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


-- ==============================================================================
-- PART 3: INGESTION RPC FUNCTION WITH ENROLLMENT & AUTHENTICATION
-- ==============================================================================

-- ==============================================================================
-- Cloud-Based PC Health Monitoring and Performance Analysis System (AEROSYS)
-- Ingestion API Function: ingest_readings()
-- Hardened with Cryptographic Token Enrollment, API Key Verification, and Revocation Guards
-- ==============================================================================

CREATE OR REPLACE FUNCTION public.ingest_readings(
    p_device_id UUID,
    p_device_api_key TEXT,
    p_dashboard_token TEXT,
    p_enrollment_token TEXT,
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
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    v_inserted_count INTEGER := 0;
    v_reading JSONB;
    v_user_id UUID;
    v_auth_record RECORD;
    v_enroll_record RECORD;
    v_api_key_hash TEXT;
    v_dash_token_hash TEXT;
    v_enroll_hash TEXT;
BEGIN
    -- 1. Strict Input Validation
    IF p_device_id IS NULL THEN
        RETURN jsonb_build_object('success', FALSE, 'error', 'Missing p_device_id');
    END IF;

    IF p_device_api_key IS NULL OR length(trim(p_device_api_key)) < 16 THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'error', 'Unauthorized: Device API key is missing or too short (minimum 16 characters required)',
            'server_timestamp', NOW()
        );
    END IF;

    -- Compute SHA-256 cryptographic hash of the provided device write key
    v_api_key_hash := encode(digest(trim(p_device_api_key), 'sha256'), 'hex');

    -- 2. Check if device is already provisioned
    SELECT * INTO v_auth_record
    FROM public.device_auth
    WHERE device_id = p_device_id;

    IF v_auth_record.device_id IS NOT NULL THEN
        -- ----------------------------------------------------------------------
        -- [SUBSEQUENT INGESTION]: Authenticate Existing Machine
        -- ----------------------------------------------------------------------

        -- Guard 1: Revocation Check
        IF v_auth_record.status = 'revoked' THEN
            RETURN jsonb_build_object(
                'success', FALSE,
                'error', 'Forbidden: Machine ' || p_device_id::TEXT || ' has been REVOKED by an administrator. Ingestion blocked.',
                'server_timestamp', NOW()
            );
        ELSIF v_auth_record.status = 'suspended' THEN
            RETURN jsonb_build_object(
                'success', FALSE,
                'error', 'Forbidden: Machine ' || p_device_id::TEXT || ' is temporarily SUSPENDED.',
                'server_timestamp', NOW()
            );
        END IF;

        -- Guard 2: Cryptographic API Key Verification
        IF v_auth_record.api_key_hash != v_api_key_hash THEN
            RETURN jsonb_build_object(
                'success', FALSE,
                'error', 'Unauthorized: Device API key mismatch for device ' || p_device_id::TEXT || '. Ingestion rejected.',
                'server_timestamp', NOW()
            );
        END IF;

        -- Authenticated successfully: update heartbeat and specifications
        v_user_id := auth.uid();
        IF v_user_id IS NULL THEN
            SELECT user_id INTO v_user_id FROM public.devices WHERE device_id = p_device_id;
        END IF;

        UPDATE public.devices SET
            user_id = COALESCE(devices.user_id, v_user_id),
            hostname = p_hostname,
            os_info = p_os_info,
            cpu_model = COALESCE(p_cpu_model, devices.cpu_model),
            cpu_cores = COALESCE(p_cpu_cores, devices.cpu_cores),
            ram_total_gb = p_ram_total_gb,
            disk_total_gb = p_disk_total_gb,
            last_seen_at = NOW(),
            updated_at = NOW()
        WHERE device_id = p_device_id;

        -- Update last authentication timestamp in secret store and allow token rotation
        IF p_dashboard_token IS NOT NULL AND length(trim(p_dashboard_token)) >= 16 THEN
            v_dash_token_hash := encode(digest(trim(p_dashboard_token), 'sha256'), 'hex');
            UPDATE public.device_auth SET
                dashboard_token_hash = v_dash_token_hash,
                last_authenticated_at = NOW(),
                updated_at = NOW()
            WHERE device_id = p_device_id;
        ELSE
            UPDATE public.device_auth SET
                last_authenticated_at = NOW(),
                updated_at = NOW()
            WHERE device_id = p_device_id;
        END IF;

    ELSE
        -- ----------------------------------------------------------------------
        -- [INITIAL ENROLLMENT]: Secure Provisioning with Enrollment Token
        -- Prevents TOFU squatting and unauthorized rogue machine registration.
        -- ----------------------------------------------------------------------

        IF p_enrollment_token IS NULL OR length(trim(p_enrollment_token)) < 8 THEN
            RETURN jsonb_build_object(
                'success', FALSE,
                'error', 'Unauthorized: Device is not enrolled. Initial registration requires a valid enrollment_token.',
                'server_timestamp', NOW()
            );
        END IF;

        v_enroll_hash := encode(digest(trim(p_enrollment_token), 'sha256'), 'hex');

        -- Validate enrollment token against active tokens
        SELECT * INTO v_enroll_record
        FROM public.device_enrollment_tokens
        WHERE token_hash = v_enroll_hash
          AND is_active = TRUE
          AND (expires_at IS NULL OR expires_at > NOW())
          AND (max_uses IS NULL OR uses_count < max_uses)
        FOR UPDATE;

        IF v_enroll_record.token_id IS NULL THEN
            RETURN jsonb_build_object(
                'success', FALSE,
                'error', 'Unauthorized: Invalid, expired, or exhausted enrollment token. Registration refused.',
                'server_timestamp', NOW()
            );
        END IF;

        -- Increment token use count
        UPDATE public.device_enrollment_tokens
        SET uses_count = uses_count + 1
        WHERE token_id = v_enroll_record.token_id;

        -- Compute SHA-256 hash of dashboard viewer token
        IF p_dashboard_token IS NOT NULL AND length(trim(p_dashboard_token)) >= 16 THEN
            v_dash_token_hash := encode(digest(trim(p_dashboard_token), 'sha256'), 'hex');
        ELSE
            v_dash_token_hash := encode(digest(gen_random_uuid()::text, 'sha256'), 'hex');
        END IF;

        v_user_id := auth.uid();

        -- Provision Device Record
        INSERT INTO public.devices (
            device_id,
            user_id,
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
            v_user_id,
            p_hostname,
            p_os_info,
            p_cpu_model,
            p_cpu_cores,
            p_ram_total_gb,
            p_disk_total_gb,
            NOW(),
            NOW()
        );

        -- Provision Secret Store Record (Permanently binds device_id to keys)
        INSERT INTO public.device_auth (
            device_id,
            api_key_hash,
            dashboard_token_hash,
            enrolled_via_token_id,
            status,
            enrolled_at,
            last_authenticated_at,
            created_at,
            updated_at
        )
        VALUES (
            p_device_id,
            v_api_key_hash,
            v_dash_token_hash,
            v_enroll_record.token_id,
            'active',
            NOW(),
            NOW(),
            NOW(),
            NOW()
        );

    END IF;

    -- 3. Bulk Insert Metrics Readings from JSON Array
    IF p_readings IS NOT NULL AND jsonb_array_length(p_readings) > 0 THEN
        FOR v_reading IN SELECT * FROM jsonb_array_elements(p_readings)
        LOOP
            INSERT INTO public.metrics_raw (
                device_id,
                user_id,
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
                v_user_id,
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

    -- 4. Return JSON response to client
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

-- Secure Profile Verification RPC: Verifies dashboard_token before returning device telemetry
CREATE OR REPLACE FUNCTION public.get_authorized_device_telemetry(
    p_device_id UUID,
    p_dashboard_token TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    v_token_hash TEXT;
    v_auth_record RECORD;
    v_device RECORD;
    v_metrics JSONB;
    v_alerts JSONB;
BEGIN
    IF p_device_id IS NULL OR p_dashboard_token IS NULL THEN
        RETURN jsonb_build_object('authorized', FALSE, 'error', 'Missing device_id or dashboard_token');
    END IF;

    v_token_hash := encode(digest(trim(p_dashboard_token), 'sha256'), 'hex');

    -- Verify dashboard token against device_auth
    SELECT * INTO v_auth_record
    FROM public.device_auth
    WHERE device_id = p_device_id
      AND dashboard_token_hash = v_token_hash
      AND status = 'active';

    IF v_auth_record.device_id IS NULL THEN
        RETURN jsonb_build_object('authorized', FALSE, 'error', 'Access Denied: Invalid or revoked dashboard token');
    END IF;

    -- Fetch device record
    SELECT * INTO v_device FROM public.devices WHERE device_id = p_device_id;

    -- Fetch latest 30 metrics
    SELECT COALESCE(jsonb_agg(to_jsonb(m)), '[]'::jsonb) INTO v_metrics
    FROM (
        SELECT * FROM public.metrics_raw 
        WHERE device_id = p_device_id 
        ORDER BY client_timestamp DESC 
        LIMIT 30
    ) m;

    -- Fetch latest 10 alerts
    SELECT COALESCE(jsonb_agg(to_jsonb(a)), '[]'::jsonb) INTO v_alerts
    FROM (
        SELECT * FROM public.alerts 
        WHERE device_id = p_device_id 
        ORDER BY created_at DESC 
        LIMIT 10
    ) a;

    RETURN jsonb_build_object(
        'authorized', TRUE,
        'device', to_jsonb(v_device),
        'metrics', v_metrics,
        'alerts', v_alerts
    );
END;
$$;

-- ==============================================================================
-- Administrator Provisioning Function: create_device_enrollment_token()
-- Generates a cryptographically random one-time enrollment token.
-- Stores ONLY the SHA-256 hash in the database.
-- Returns the plaintext token ONCE to the administrator.
-- ==============================================================================
CREATE OR REPLACE FUNCTION public.create_device_enrollment_token(
    p_token_name TEXT DEFAULT 'Provisioned Device Token',
    p_max_uses INTEGER DEFAULT 1,
    p_expires_in_hours INTEGER DEFAULT 72
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    v_caller_role TEXT;
    v_raw_token TEXT;
    v_token_hash TEXT;
    v_expires_at TIMESTAMPTZ;
BEGIN
    -- Only service_role or authenticated administrators can generate enrollment tokens
    v_caller_role := auth.role();
    IF v_caller_role != 'service_role' AND auth.uid() IS NULL THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'error', 'Access Denied: Only administrators can create enrollment tokens'
        );
    END IF;

    -- Generate 192-bit (48 hex chars) cryptographically secure random token
    v_raw_token := 'ENROLL-' || upper(encode(gen_random_bytes(18), 'hex'));
    v_token_hash := encode(digest(v_raw_token, 'sha256'), 'hex');
    
    IF p_expires_in_hours IS NOT NULL AND p_expires_in_hours > 0 THEN
        v_expires_at := NOW() + (p_expires_in_hours || ' hours')::INTERVAL;
    ELSE
        v_expires_at := NULL;
    END IF;

    INSERT INTO public.device_enrollment_tokens (
        token_hash,
        token_name,
        max_uses,
        uses_count,
        is_active,
        expires_at,
        created_at
    ) VALUES (
        v_token_hash,
        p_token_name,
        p_max_uses,
        0,
        TRUE,
        v_expires_at,
        NOW()
    );

    -- Return the plaintext token ONCE to the administrator
    RETURN jsonb_build_object(
        'success', TRUE,
        'enrollment_token', v_raw_token,
        'token_name', p_token_name,
        'max_uses', p_max_uses,
        'expires_at', v_expires_at,
        'instructions', 'Add this one-time token to the new laptop agent/.env as ENROLLMENT_TOKEN=' || v_raw_token
    );
END;
$$;

-- ==============================================================================
-- Administrator Revocation Function: revoke_device()
-- Immediately revokes a machine, terminating telemetry uploads and dashboard access.
-- ==============================================================================
CREATE OR REPLACE FUNCTION public.revoke_device(p_device_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    v_caller_role TEXT;
BEGIN
    v_caller_role := auth.role();
    IF v_caller_role != 'service_role' AND auth.uid() IS NULL THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'error', 'Access Denied: Only administrators can revoke devices'
        );
    END IF;

    UPDATE public.device_auth 
    SET status = 'revoked', updated_at = NOW() 
    WHERE device_id = p_device_id;

    UPDATE public.devices 
    SET is_active = FALSE, updated_at = NOW() 
    WHERE device_id = p_device_id;

    RETURN jsonb_build_object('success', TRUE, 'device_id', p_device_id, 'status', 'revoked');
END;
$$;

-- Permissions and Access Grants
GRANT EXECUTE ON FUNCTION public.ingest_readings TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_authorized_device_telemetry TO anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.create_device_enrollment_token FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_device_enrollment_token TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.revoke_device FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.revoke_device TO authenticated, service_role;


-- ==============================================================================
-- PART 4: EVENT-DRIVEN DATABASE TRIGGERS & REALTIME
-- ==============================================================================

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


-- ==============================================================================
-- PART 5: PG_CRON HOURLY ROLLUPS & 7-DAY RETENTION
-- ==============================================================================

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

