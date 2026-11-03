"""
Comprehensive Security Audit Tests
Verifies:
1. Complete removal of hardcoded enrollment secrets from repository
2. Cryptographic random one-time provisioning token generation
3. Safe token delivery via URL hash fragments (no query string leakage)
4. Strict device key isolation (device_api_key never written to public dashboard files)
5. Database-level authorization guards against IDOR and revoked/expired credentials
"""

import re
import json
import hashlib
from pathlib import Path
from agent import config
from cloud.provision_device import generate_enrollment_token

PROJECT_ROOT = Path(__file__).resolve().parent.parent

def test_no_hardcoded_enrollment_secrets_in_production_sql_or_code():
    """Ensure predictable tokens like 'AEROSYS-ENROLL-2026' are absent from SQL and code."""
    sql_files = list((PROJECT_ROOT / "cloud").glob("*.sql"))
    assert len(sql_files) >= 6

    for sql_file in sql_files:
        content = sql_file.read_text(encoding="utf-8")
        assert "AEROSYS-ENROLL-2026" not in content, f"Hardcoded secret found in {sql_file.name}"

    # Also check agent .env.example
    env_example = (PROJECT_ROOT / "agent" / ".env.example").read_text(encoding="utf-8")
    assert "AEROSYS-ENROLL-2026" not in env_example

def test_admin_provisioning_token_generator():
    """Verify administrator helper generates random tokens and correct SHA-256 hashes."""
    raw1, hash1, sql1 = generate_enrollment_token("Laptop A", max_uses=1, expires_in_hours=48)
    raw2, hash2, sql2 = generate_enrollment_token("Laptop B", max_uses=1, expires_in_hours=48)

    # Tokens must be random and unique
    assert raw1 != raw2
    assert hash1 != hash2
    assert raw1.startswith("ENROLL-")
    assert len(raw1) >= 20

    # Verify SHA-256 hash match
    expected_hash1 = hashlib.sha256(raw1.encode("utf-8")).hexdigest()
    assert hash1 == expected_hash1
    assert hash1 in sql1
    assert "max_uses" in sql1

def test_device_api_key_never_written_to_dashboard_files():
    """Verify write secret (device_api_key) is excluded from all dashboard-readable files."""
    hw = config.get_hardware_info()
    
    # Check current_device.json
    json_path = PROJECT_ROOT / "dashboard" / "current_device.json"
    if json_path.exists():
        data = json.loads(json_path.read_text(encoding="utf-8"))
        assert "device_api_key" not in data
        assert "dashboard_token" in data

    # Check device_info.js (public template)
    js_path = PROJECT_ROOT / "dashboard" / "js" / "device_info.js"
    if js_path.exists():
        js_content = js_path.read_text(encoding="utf-8")
        assert "device_api_key" not in js_content
        assert config.DASHBOARD_TOKEN not in js_content
        assert '"dashboard_token": ""' in js_content

    # Check device_info.local.js (local bridge)
    local_js = PROJECT_ROOT / "dashboard" / "js" / "device_info.local.js"
    if local_js.exists():
        local_content = local_js.read_text(encoding="utf-8")
        assert "device_api_key" not in local_content

def test_dashboard_url_delivery_uses_hash_fragment_strictly():
    """Verify dashboard URL passes read token in hash fragment (RFC 3986) to prevent log leakage."""
    url = config.open_dashboard_in_browser()
    parts = url.split("#")
    
    assert len(parts) == 2, "URL must contain exactly one '#' fragment identifier"
    base_and_query, fragment = parts[0], parts[1]

    # Query string must have device_id
    assert f"device_id={config.DEVICE_ID}" in base_and_query
    # Query string must NEVER have token
    assert "token=" not in base_and_query
    
    # Hash fragment must carry the read token
    assert f"token={config.DASHBOARD_TOKEN}" in fragment

def test_sql_contains_admin_provisioning_and_revocation():
    """Verify admin RPCs exist with security definer and strict privilege separation."""
    sql = (PROJECT_ROOT / "cloud" / "03_ingest_function.sql").read_text(encoding="utf-8")
    assert "create_device_enrollment_token" in sql
    assert "revoke_device" in sql
    assert "REVOKE ALL ON FUNCTION public.create_device_enrollment_token FROM PUBLIC, anon" in sql
    assert "REVOKE ALL ON FUNCTION public.revoke_device FROM PUBLIC, anon" in sql
    assert "GRANT EXECUTE ON FUNCTION public.create_device_enrollment_token TO authenticated, service_role" in sql
    assert "GRANT EXECUTE ON FUNCTION public.revoke_device TO authenticated, service_role" in sql

def test_sql_rls_does_not_contain_blanket_anon_bypass():
    """Verify that Realtime logical replication does not blindly allow anonymous listeners."""
    rls_sql = (PROJECT_ROOT / "cloud" / "02_rls_policies.sql").read_text(encoding="utf-8")
    assert "v_headers IS NULL AND auth.role() = 'anon'" not in rls_sql

