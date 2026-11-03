"""
Tests for Config Module, Device Identity, and Cryptographic Key Handling
"""

import tempfile
import os
import uuid
from pathlib import Path
from agent import config

def test_device_id_is_valid_uuid():
    dev_id, dev_key, dash_token = config.get_or_create_device_identity()
    val = uuid.UUID(dev_id)
    assert str(val) == dev_id
    assert isinstance(dev_key, str)
    assert len(dev_key) >= 32
    assert isinstance(dash_token, str)
    assert len(dash_token) >= 24

def test_hardware_info_structure():
    hw = config.get_hardware_info()
    assert "device_id" in hw
    assert "device_api_key" in hw
    assert "hostname" in hw
    assert "os_info" in hw
    assert "cpu_cores" in hw
    assert "ram_total_gb" in hw
    assert "disk_total_gb" in hw
    assert hw["cpu_cores"] >= 1
    assert hw["ram_total_gb"] > 0
    assert hw["disk_total_gb"] > 0

def test_dashboard_url_token_in_hash_fragment_never_in_query_params():
    url = config.open_dashboard_in_browser()
    # 1. URL query parameters must contain device_id and metadata
    assert f"device_id={config.DEVICE_ID}" in url
    
    # 2. Query string before '#' must NEVER contain token parameter (prevents server log & referrer leakage)
    base_and_query = url.split('#')[0]
    assert "token=" not in base_and_query
    assert f"?token=" not in base_and_query
    assert f"&token=" not in base_and_query

    # 3. Token must be passed securely in URL hash fragment
    assert "#" in url
    fragment = url.split('#')[1]
    assert f"token={config.DASHBOARD_TOKEN}" in fragment

    # 4. Device write key must NEVER be exposed anywhere in the URL
    assert config.DEVICE_API_KEY not in url

def test_save_credentials_preserves_other_settings():
    fd, env_path = tempfile.mkstemp(suffix=".env")
    os.close(fd)

    with open(env_path, "w", encoding="utf-8") as f:
        f.write("COLLECTION_INTERVAL_SECS=5\nBATCH_SYNC_INTERVAL_SECS=60\n")

    orig_env = config.ENV_FILE
    try:
        config.ENV_FILE = Path(env_path)
        config.save_credentials(
            supabase_url="https://test-proj.supabase.co",
            supabase_key="secret-anon-key",
            dashboard_url="https://pc-monitor.vercel.app"
        )

        assert config.SUPABASE_URL == "https://test-proj.supabase.co"
        assert config.SUPABASE_KEY == "secret-anon-key"
        assert config.DASHBOARD_URL == "https://pc-monitor.vercel.app"
        assert config.COLLECTION_INTERVAL_SECS == 5
        assert config.BATCH_SYNC_INTERVAL_SECS == 60
    finally:
        config.ENV_FILE = orig_env
        config.reload_config()
        if os.path.exists(env_path):
            os.remove(env_path)
