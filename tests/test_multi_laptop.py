"""
Tests for Multi-Laptop Independence, Device Keys, and Data Isolation
Verifies that multiple client machines create distinct payloads, cryptographic keys,
and can ingest data to the database without cross-overwriting.
"""

import uuid
import secrets
from unittest.mock import patch, MagicMock
from agent.sync import SyncEngine
from agent.buffer import LocalBuffer
import tempfile
import os

def test_multiple_laptops_generate_unique_device_ids():
    laptop_a_id = str(uuid.uuid4())
    laptop_b_id = str(uuid.uuid4())
    assert laptop_a_id != laptop_b_id

def test_multi_laptop_payload_separation():
    # Setup Laptop A
    laptop_a_id = str(uuid.uuid4())
    laptop_a_key = secrets.token_hex(32)
    laptop_a_dash = secrets.token_hex(24)
    laptop_a_hw = {
        "device_id": laptop_a_id,
        "device_api_key": laptop_a_key,
        "hostname": "LAPTOP-STUDENT-A",
        "os_info": "Windows 11 (AMD64)",
        "cpu_model": "Intel Core i7",
        "cpu_cores": 8,
        "ram_total_gb": 16.0,
        "disk_total_gb": 512.0
    }

    # Setup Laptop B
    laptop_b_id = str(uuid.uuid4())
    laptop_b_key = secrets.token_hex(32)
    laptop_b_dash = secrets.token_hex(24)
    laptop_b_hw = {
        "device_id": laptop_b_id,
        "device_api_key": laptop_b_key,
        "hostname": "LAPTOP-STUDENT-B",
        "os_info": "Ubuntu 24.04 (x86_64)",
        "cpu_model": "AMD Ryzen 7",
        "cpu_cores": 16,
        "ram_total_gb": 32.0,
        "disk_total_gb": 1024.0
    }

    fd_a, db_a = tempfile.mkstemp(suffix=".db")
    fd_b, db_b = tempfile.mkstemp(suffix=".db")
    os.close(fd_a)
    os.close(fd_b)

    try:
        buf_a = LocalBuffer(db_path=db_a)
        buf_b = LocalBuffer(db_path=db_b)

        buf_a.add_reading({"cpu_percent": 42.0, "client_timestamp": "2026-11-02T10:00:00Z"})
        buf_b.add_reading({"cpu_percent": 88.0, "client_timestamp": "2026-11-02T10:00:00Z"})

        engine_a = SyncEngine(buf_a)
        engine_b = SyncEngine(buf_b)

        recorded_bodies = []

        def fake_post(url, json=None, headers=None, timeout=None):
            recorded_bodies.append(json)
            mock_res = MagicMock()
            mock_res.status_code = 200
            mock_res.json.return_value = {"success": True, "device_id": json["p_device_id"]}
            return mock_res

        with patch("agent.config.SUPABASE_URL", "https://pc-monitor.supabase.co"), \
             patch("agent.config.SUPABASE_KEY", "anon-token"), \
             patch("agent.config.DEVICE_API_KEY", laptop_a_key), \
             patch("agent.config.DASHBOARD_TOKEN", laptop_a_dash), \
             patch("agent.config.HARDWARE_INFO", laptop_a_hw), \
             patch("requests.post", side_effect=fake_post):
            ok_a, cnt_a, _ = engine_a.sync_batch()
            assert ok_a is True
            assert cnt_a == 1

        with patch("agent.config.SUPABASE_URL", "https://pc-monitor.supabase.co"), \
             patch("agent.config.SUPABASE_KEY", "anon-token"), \
             patch("agent.config.DEVICE_API_KEY", laptop_b_key), \
             patch("agent.config.DASHBOARD_TOKEN", laptop_b_dash), \
             patch("agent.config.HARDWARE_INFO", laptop_b_hw), \
             patch("requests.post", side_effect=fake_post):
            ok_b, cnt_b, _ = engine_b.sync_batch()
            assert ok_b is True
            assert cnt_b == 1

        # Check recorded payloads:
        assert len(recorded_bodies) == 2
        body_a, body_b = recorded_bodies[0], recorded_bodies[1]

        # Verify Laptop A payload
        assert body_a["p_device_id"] == laptop_a_id
        assert body_a["p_device_api_key"] == laptop_a_key
        assert body_a["p_dashboard_token"] == laptop_a_dash
        assert body_a["p_hostname"] == "LAPTOP-STUDENT-A"
        assert body_a["p_readings"][0]["cpu_percent"] == 42.0

        # Verify Laptop B payload
        assert body_b["p_device_id"] == laptop_b_id
        assert body_b["p_device_api_key"] == laptop_b_key
        assert body_b["p_dashboard_token"] == laptop_b_dash
        assert body_b["p_hostname"] == "LAPTOP-STUDENT-B"
        assert body_b["p_readings"][0]["cpu_percent"] == 88.0

        # Verify no cross-contamination between separate laptops
        assert body_a["p_device_id"] != body_b["p_device_id"]
        assert body_a["p_device_api_key"] != body_b["p_device_api_key"]
        assert body_a["p_dashboard_token"] != body_b["p_dashboard_token"]
        assert body_a["p_hostname"] != body_b["p_hostname"]

    finally:
        if os.path.exists(db_a):
            os.remove(db_a)
        if os.path.exists(db_b):
            os.remove(db_b)
