"""
Tests for Metrics Collector Module
"""

import pytest
import datetime
from agent.collector import collect_system_metrics

def test_collector_returns_valid_structure():
    data = collect_system_metrics()
    assert isinstance(data, dict)
    
    required_keys = [
        "client_timestamp",
        "cpu_percent",
        "cpu_freq_mhz",
        "ram_percent",
        "ram_used_gb",
        "ram_total_gb",
        "disk_percent",
        "disk_used_gb",
        "disk_total_gb",
        "battery_percent",
        "battery_plugged",
        "battery_secs_left",
        "net_sent_kb",
        "net_recv_kb"
    ]
    for key in required_keys:
        assert key in data, f"Missing required key '{key}' in collector output"

def test_collector_metric_ranges():
    data = collect_system_metrics()
    assert 0.0 <= data["cpu_percent"] <= 100.0
    assert 0.0 <= data["ram_percent"] <= 100.0
    assert data["ram_used_gb"] >= 0.0
    assert data["ram_total_gb"] > 0.0
    assert 0.0 <= data["disk_percent"] <= 100.0
    assert data["disk_used_gb"] >= 0.0
    assert data["disk_total_gb"] > 0.0
    assert data["net_sent_kb"] >= 0.0
    assert data["net_recv_kb"] >= 0.0

def test_collector_timestamp_iso():
    data = collect_system_metrics()
    ts = data["client_timestamp"]
    parsed = datetime.datetime.fromisoformat(ts)
    assert parsed.tzinfo is not None, "Timestamp must be timezone-aware (UTC)"

