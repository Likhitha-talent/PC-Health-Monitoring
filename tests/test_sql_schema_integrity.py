"""
Tests for SQL Schema, Trigger, RLS Policies, and Migration Script Integrity
"""

from pathlib import Path

CLOUD_DIR = Path(__file__).resolve().parent.parent / "cloud"

def test_sql_files_exist():
    expected_files = [
        "01_schema.sql",
        "02_rls_policies.sql",
        "03_ingest_function.sql",
        "04_triggers.sql",
        "05_cron_jobs.sql",
        "full_database_setup.sql"
    ]
    for filename in expected_files:
        file_path = CLOUD_DIR / filename
        assert file_path.exists(), f"Missing required SQL file: {filename}"
        assert file_path.stat().st_size > 0, f"SQL file is empty: {filename}"

def test_01_schema_has_required_tables_and_types():
    content = (CLOUD_DIR / "01_schema.sql").read_text(encoding="utf-8")
    assert "CREATE TABLE IF NOT EXISTS public.devices" in content
    assert "CREATE TABLE IF NOT EXISTS public.device_enrollment_tokens" in content
    assert "CREATE TABLE IF NOT EXISTS public.device_auth" in content
    assert "CREATE TABLE IF NOT EXISTS public.metrics_raw" in content
    assert "CREATE TABLE IF NOT EXISTS public.alerts" in content
    assert "CREATE TABLE IF NOT EXISTS public.metrics_hourly" in content
    # Assert zero hardcoded default tokens
    assert "AEROSYS-ENROLL-2026" not in content
    assert "gen_random_uuid()" in content
    assert "disk_total_gb NUMERIC(10, 2)" in content
    assert "disk_used_gb NUMERIC(10, 2)" in content

def test_02_rls_policies_idempotency_and_security():
    content = (CLOUD_DIR / "02_rls_policies.sql").read_text(encoding="utf-8")
    assert "ENABLE ROW LEVEL SECURITY" in content
    assert "ALTER TABLE public.device_auth ENABLE ROW LEVEL SECURITY" in content
    assert "ALTER TABLE public.device_enrollment_tokens ENABLE ROW LEVEL SECURITY" in content
    assert "check_device_read_authorization" in content
    assert "x-dashboard-token" in content
    assert "DROP POLICY IF EXISTS" in content
    assert 'DROP POLICY IF EXISTS "Users can view own devices"' in content
    assert 'DROP POLICY IF EXISTS "Users can read own device metrics"' in content
    assert 'DROP POLICY IF EXISTS "Users can read own alerts"' in content
    # Assert direct anonymous metrics INSERT is revoked
    assert 'DROP POLICY IF EXISTS "Insert metrics allowed"' in content
    # Assert Realtime anonymous blanket bypass was removed
    assert "v_headers IS NULL AND auth.role() = 'anon'" not in content

def test_03_ingest_function_signature_and_grants():
    content = (CLOUD_DIR / "03_ingest_function.sql").read_text(encoding="utf-8")
    assert "CREATE OR REPLACE FUNCTION public.ingest_readings" in content
    assert "SECURITY DEFINER" in content
    assert "p_device_id UUID" in content
    assert "p_device_api_key TEXT" in content
    assert "p_dashboard_token TEXT" in content
    assert "p_enrollment_token TEXT" in content
    assert "p_readings JSONB" in content
    assert "api_key_hash" in content
    assert "get_authorized_device_telemetry" in content
    assert "create_device_enrollment_token" in content
    assert "revoke_device" in content
    assert "GRANT EXECUTE ON FUNCTION public.ingest_readings TO anon, authenticated, service_role" in content
    assert "GRANT EXECUTE ON FUNCTION public.get_authorized_device_telemetry TO anon, authenticated, service_role" in content
    # Admin functions must be revoked from public and anon
    assert "REVOKE ALL ON FUNCTION public.create_device_enrollment_token FROM PUBLIC, anon" in content
    assert "REVOKE ALL ON FUNCTION public.revoke_device FROM PUBLIC, anon" in content

def test_04_triggers_and_realtime_publication():
    content = (CLOUD_DIR / "04_triggers.sql").read_text(encoding="utf-8")
    assert "CREATE OR REPLACE FUNCTION public.evaluate_reading_thresholds" in content
    assert "CREATE TRIGGER trg_evaluate_reading_thresholds" in content
    assert "supabase_realtime" in content
    assert "ALTER PUBLICATION supabase_realtime ADD TABLE public.alerts" in content

def test_05_cron_jobs_definition():
    content = (CLOUD_DIR / "05_cron_jobs.sql").read_text(encoding="utf-8")
    assert "CREATE EXTENSION IF NOT EXISTS pg_cron" in content
    assert "public.aggregate_hourly_metrics" in content
    assert "public.purge_expired_raw_metrics" in content
    assert "cron.schedule" in content

def test_full_database_setup_contains_all_parts():
    content = (CLOUD_DIR / "full_database_setup.sql").read_text(encoding="utf-8")
    assert "PART 1: EXTENSIONS & CORE TABLES" in content
    assert "device_enrollment_tokens" in content
    assert "device_auth" in content
    # Zero hardcoded tokens in master migration
    assert "AEROSYS-ENROLL-2026" not in content
    assert "PART 2: ROW LEVEL SECURITY (RLS) POLICIES" in content
    assert "check_device_read_authorization" in content
    assert "PART 3: INGESTION RPC FUNCTION WITH ENROLLMENT & AUTHENTICATION" in content
    assert "get_authorized_device_telemetry" in content
    assert "create_device_enrollment_token" in content
    assert "revoke_device" in content
    assert "PART 4: EVENT-DRIVEN DATABASE TRIGGERS & REALTIME" in content
    assert "PART 5: PG_CRON HOURLY ROLLUPS & 7-DAY RETENTION" in content
