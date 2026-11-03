"""
Tests for Local SQLite Buffer Module
"""

import tempfile
import os
import pytest
from agent.buffer import LocalBuffer

@pytest.fixture
def temp_buffer():
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    buffer = LocalBuffer(db_path=path)
    yield buffer
    if os.path.exists(path):
        os.remove(path)

def test_buffer_add_and_get(temp_buffer):
    sample = {
        "client_timestamp": "2026-11-02T12:00:00+00:00",
        "cpu_percent": 45.2,
        "ram_percent": 60.1
    }
    row_id = temp_buffer.add_reading(sample)
    assert row_id == 1

    readings = temp_buffer.get_unsynced_readings(limit=10)
    assert len(readings) == 1
    assert readings[0][0] == row_id
    assert readings[0][1]["cpu_percent"] == 45.2

def test_buffer_mark_synced(temp_buffer):
    sample = {"client_timestamp": "2026-11-02T12:00:00+00:00", "cpu_percent": 10.0}
    r1 = temp_buffer.add_reading(sample)
    r2 = temp_buffer.add_reading(sample)

    assert len(temp_buffer.get_unsynced_readings(limit=10)) == 2
    temp_buffer.mark_as_synced([r1])

    unsynced = temp_buffer.get_unsynced_readings(limit=10)
    assert len(unsynced) == 1
    assert unsynced[0][0] == r2

def test_buffer_stats(temp_buffer):
    stats = temp_buffer.get_stats()
    assert stats["total_count"] == 0
    assert stats["unsynced_count"] == 0

    temp_buffer.add_reading({"cpu_percent": 25.0})
    temp_buffer.add_reading({"cpu_percent": 30.0})

    stats = temp_buffer.get_stats()
    assert stats["total_count"] == 2
    assert stats["unsynced_count"] == 2

    temp_buffer.mark_as_synced([1])
    stats = temp_buffer.get_stats()
    assert stats["total_count"] == 2
    assert stats["unsynced_count"] == 1

