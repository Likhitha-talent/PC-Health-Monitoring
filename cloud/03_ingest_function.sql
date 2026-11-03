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
