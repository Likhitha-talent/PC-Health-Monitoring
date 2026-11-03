"""
SQLite Local Buffer Module
Provides offline data buffering and persistence to guarantee zero data loss
during network outages (Eventual Consistency).
"""

import sqlite3
import json
import threading
from contextlib import contextmanager
from typing import List, Tuple, Dict, Any, Generator
from .config import SQLITE_DB_PATH

_lock = threading.Lock()

class LocalBuffer:
    def __init__(self, db_path: str = SQLITE_DB_PATH):
        self.db_path = db_path
        self._init_db()

    @contextmanager
    def _connection(self) -> Generator[sqlite3.Connection, None, None]:
        """Provides a managed SQLite connection that closes reliably upon block exit."""
        conn = sqlite3.connect(self.db_path, timeout=10.0)
        conn.row_factory = sqlite3.Row
        try:
            yield conn
        finally:
            conn.close()

    def _init_db(self):
        with _lock, self._connection() as conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS buffered_metrics (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    payload TEXT NOT NULL,
                    client_timestamp TEXT NOT NULL,
                    is_synced INTEGER DEFAULT 0,
                    synced_at TEXT,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)
            conn.execute("""
                CREATE INDEX IF NOT EXISTS idx_buffered_metrics_synced 
                ON buffered_metrics(is_synced, id ASC)
            """)
            conn.commit()

    def add_reading(self, reading: Dict[str, Any]) -> int:
        """Appends a new metric reading into the local SQLite buffer."""
        payload_str = json.dumps(reading)
        timestamp = reading.get("client_timestamp", "")
        with _lock, self._connection() as conn:
            cursor = conn.execute("""
                INSERT INTO buffered_metrics (payload, client_timestamp, is_synced)
                VALUES (?, ?, 0)
            """, (payload_str, timestamp))
            conn.commit()
            return cursor.lastrowid

    def get_unsynced_readings(self, limit: int = 120) -> List[Tuple[int, Dict[str, Any]]]:
        """
        Retrieves a batch of unsynced records ordered by id.
        Returns list of (record_id, metric_dict).
        """
        with _lock, self._connection() as conn:
            cursor = conn.execute("""
                SELECT id, payload 
                FROM buffered_metrics 
                WHERE is_synced = 0 
                ORDER BY id ASC 
                LIMIT ?
            """, (limit,))
            rows = cursor.fetchall()
            
            results = []
            for row in rows:
                try:
                    results.append((row["id"], json.loads(row["payload"])))
                except Exception:
                    pass
            return results

    def mark_as_synced(self, ids: List[int]):
        """Marks the given record IDs as synced after successful cloud ingestion."""
        if not ids:
            return
        placeholders = ",".join("?" for _ in ids)
        with _lock, self._connection() as conn:
            conn.execute(f"""
                UPDATE buffered_metrics 
                SET is_synced = 1, synced_at = CURRENT_TIMESTAMP 
                WHERE id IN ({placeholders})
            """, ids)
            conn.commit()

    def get_stats(self) -> Dict[str, int]:
        """Returns buffer counts for UI display."""
        with _lock, self._connection() as conn:
            cursor = conn.execute("""
                SELECT 
                    COUNT(CASE WHEN is_synced = 0 THEN 1 END) AS unsynced,
                    COUNT(*) AS total
                FROM buffered_metrics
            """)
            row = cursor.fetchone()
            return {
                "unsynced_count": row["unsynced"] if row else 0,
                "total_count": row["total"] if row else 0
            }

    def prune_synced(self, keep_days: int = 2):
        """Removes synced records older than keep_days to manage local disk space."""
        with _lock, self._connection() as conn:
            conn.execute("""
                DELETE FROM buffered_metrics 
                WHERE is_synced = 1 
                  AND created_at < datetime('now', '-' || ? || ' days')
            """, (keep_days,))
            conn.commit()
