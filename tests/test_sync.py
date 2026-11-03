"""
Tests for Cloud Synchronization Engine with Device Authentication & Enrollment Tokens
"""

import tempfile
import os
import pytest
from unittest.mock import patch, MagicMock
from agent.buffer import LocalBuffer
from agent.sync import SyncEngine
from agent import config

@pytest.fixture
def sync_env():
    fd, db_path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    buf = LocalBuffer(db_path=db_path)
    engine = SyncEngine(buffer=buf)

    orig_url = config.SUPABASE_URL
    orig_key = config.SUPABASE_KEY
    orig_enroll = config.ENROLLMENT_TOKEN

    config.ENROLLMENT_TOKEN = "ENROLL-TEST-TOKEN-98765"
    yield engine, buf

    config.SUPABASE_URL = orig_url
    config.SUPABASE_KEY = orig_key
    config.ENROLLMENT_TOKEN = orig_enroll
    if os.path.exists(db_path):
        os.remove(db_path)

def test_sync_no_credentials(sync_env):
    engine, buf = sync_env
    config.SUPABASE_URL = ""
    config.SUPABASE_KEY = ""

    success, count, msg = engine.sync_batch()
    assert success is False
    assert count == 0
    assert "not configured" in msg

def test_sync_empty_buffer(sync_env):
    engine, buf = sync_env
    config.SUPABASE_URL = "https://example.supabase.co"
    config.SUPABASE_KEY = "test-key"

    success, count, msg = engine.sync_batch()
    assert success is True
    assert count == 0
    assert "Buffer empty" in msg

def test_sync_successful_batch(sync_env):
    engine, buf = sync_env
    config.SUPABASE_URL = "https://example.supabase.co"
    config.SUPABASE_KEY = "test-key"

    r1 = buf.add_reading({"cpu_percent": 30.0, "client_timestamp": "2026-11-02T12:00:00Z"})
    r2 = buf.add_reading({"cpu_percent": 35.0, "client_timestamp": "2026-11-02T12:00:05Z"})

    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.json.return_value = {
        "success": True,
        "device_id": config.HARDWARE_INFO["device_id"],
        "records_ingested": 2
    }

    with patch("requests.post", return_value=mock_resp) as mock_post:
        success, count, msg = engine.sync_batch()
        assert success is True
        assert count == 2
        assert "Successfully uploaded" in msg
        mock_post.assert_called_once()
        sent_body = mock_post.call_args[1]["json"]
        assert "p_device_api_key" in sent_body
        assert len(sent_body["p_device_api_key"]) >= 16
        assert "p_dashboard_token" in sent_body
        assert len(sent_body["p_dashboard_token"]) >= 16
        assert "p_enrollment_token" in sent_body
        assert len(sent_body["p_enrollment_token"]) >= 8

    # Buffer should now have 0 unsynced records
    assert len(buf.get_unsynced_readings()) == 0

def test_sync_supports_publishable_key_format(sync_env):
    engine, buf = sync_env
    config.SUPABASE_URL = "https://bqnaozqefdexarvujlre.supabase.co"
    config.SUPABASE_KEY = "sb_publishable_mock_test_key_12345"

    buf.add_reading({"cpu_percent": 25.0})

    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.json.return_value = {"success": True, "records_ingested": 1}

    with patch("requests.post", return_value=mock_resp) as mock_post:
        success, count, msg = engine.sync_batch()
        assert success is True
        mock_post.assert_called_once()
        headers = mock_post.call_args[1]["headers"]
        # Must pass apikey header
        assert headers["apikey"] == "sb_publishable_mock_test_key_12345"
        # Must NOT pass invalid Bearer header for non-JWT publishable keys to prevent PostgREST PGRST301 JWT format error
        assert "Authorization" not in headers

def test_sync_supports_legacy_jwt_anon_key(sync_env):
    engine, buf = sync_env
    config.SUPABASE_URL = "https://bqnaozqefdexarvujlre.supabase.co"
    jwt_key = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiJ9.mock_signature"
    config.SUPABASE_KEY = jwt_key

    buf.add_reading({"cpu_percent": 25.0})

    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.json.return_value = {"success": True, "records_ingested": 1}

    with patch("requests.post", return_value=mock_resp) as mock_post:
        success, count, msg = engine.sync_batch()
        assert success is True
        mock_post.assert_called_once()
        headers = mock_post.call_args[1]["headers"]
        # Must pass apikey header and Authorization Bearer header for valid JWT
        assert headers["apikey"] == jwt_key
        assert headers["Authorization"] == f"Bearer {jwt_key}"

def test_sync_unauthorized_key_rejected(sync_env):
    engine, buf = sync_env
    config.SUPABASE_URL = "https://example.supabase.co"
    config.SUPABASE_KEY = "test-key"

    buf.add_reading({"cpu_percent": 99.0})

    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.json.return_value = {
        "success": False,
        "error": "Unauthorized: Device API key mismatch for device"
    }

    with patch("requests.post", return_value=mock_resp):
        success, count, msg = engine.sync_batch()
        assert success is False
        assert count == 0
        assert "Cloud database rejected batch" in msg
        assert "Unauthorized" in msg

    # Record must still be pending in buffer
    assert len(buf.get_unsynced_readings()) == 1

def test_sync_revoked_machine_blocked(sync_env):
    engine, buf = sync_env
    config.SUPABASE_URL = "https://example.supabase.co"
    config.SUPABASE_KEY = "test-key"

    buf.add_reading({"cpu_percent": 75.0})

    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.json.return_value = {
        "success": False,
        "error": "Forbidden: Machine has been REVOKED by an administrator. Ingestion blocked."
    }

    with patch("requests.post", return_value=mock_resp):
        success, count, msg = engine.sync_batch()
        assert success is False
        assert count == 0
        assert "REVOKED" in msg

    # Record must remain buffered
    assert len(buf.get_unsynced_readings()) == 1

def test_sync_invalid_enrollment_token_rejected(sync_env):
    engine, buf = sync_env
    config.SUPABASE_URL = "https://example.supabase.co"
    config.SUPABASE_KEY = "test-key"

    buf.add_reading({"cpu_percent": 45.0})

    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.json.return_value = {
        "success": False,
        "error": "Unauthorized: Invalid, expired, or exhausted enrollment token. Registration refused."
    }

    with patch("requests.post", return_value=mock_resp):
        success, count, msg = engine.sync_batch()
        assert success is False
        assert count == 0
        assert "Invalid, expired, or exhausted enrollment token" in msg

def test_sync_network_failure_preserves_buffer(sync_env):
    engine, buf = sync_env
    config.SUPABASE_URL = "https://example.supabase.co"
    config.SUPABASE_KEY = "test-key"

    buf.add_reading({"cpu_percent": 50.0})

    import requests
    with patch("requests.post", side_effect=requests.exceptions.ConnectionError("Offline")):
        success, count, msg = engine.sync_batch()
        assert success is False
        assert count == 0
        assert "Network connection error" in msg

    # Unsynced count must remain 1
    assert len(buf.get_unsynced_readings()) == 1
