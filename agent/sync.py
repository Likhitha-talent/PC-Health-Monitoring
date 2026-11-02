"""
Cloud Synchronization Engine
Transmits batched readings from SQLite buffer to Supabase RPC 'ingest_readings'.
Maintains loose coupling and delivers eventual consistency during intermittent connectivity.
"""

import logging
import requests
from typing import Tuple
from .config import SUPABASE_URL, SUPABASE_KEY, HARDWARE_INFO, BATCH_SIZE_LIMIT
from .buffer import LocalBuffer

logger = logging.getLogger("pc_agent_sync")

class SyncEngine:
    def __init__(self, buffer: LocalBuffer):
        self.buffer = buffer

    def check_connectivity(self) -> bool:
        """Quick check to see if Supabase or general internet is reachable."""
        if not SUPABASE_URL:
            return False
        try:
            # Ping Supabase REST health endpoint with short timeout
            url = f"{SUPABASE_URL}/rest/v1/"
            headers = {"apikey": SUPABASE_KEY} if SUPABASE_KEY else {}
            resp = requests.get(url, headers=headers, timeout=4.0)
            return resp.status_code in (200, 401, 404, 400) # Reached cloud host
        except Exception:
            return False

    def sync_batch(self, batch_limit: int = BATCH_SIZE_LIMIT) -> Tuple[bool, int, str]:
        """
        Attempts to transmit unsynced buffered telemetry to Supabase.
        Returns: (success: bool, records_synced: int, message: str)
        """
        if not SUPABASE_URL or not SUPABASE_KEY:
            return False, 0, "Supabase credentials not configured. Buffering locally."

        # 1. Fetch pending batch from SQLite buffer
        pending_items = self.buffer.get_unsynced_readings(limit=batch_limit)
        if not pending_items:
            return True, 0, "Buffer empty (All metrics synchronized)."

        record_ids = [item[0] for item in pending_items]
        readings_payload = [item[1] for item in pending_items]

        # 2. Prepare RPC payload matching ingest_readings() signature
        rpc_url = f"{SUPABASE_URL}/rest/v1/rpc/ingest_readings"
        headers = {
            "apikey": SUPABASE_KEY,
            "Authorization": f"Bearer {SUPABASE_KEY}",
            "Content-Type": "application/json",
            "Prefer": "return=representation"
        }
        body = {
            "p_device_id": HARDWARE_INFO["device_id"],
            "p_hostname": HARDWARE_INFO["hostname"],
            "p_os_info": HARDWARE_INFO["os_info"],
            "p_cpu_model": HARDWARE_INFO["cpu_model"],
            "p_cpu_cores": HARDWARE_INFO["cpu_cores"],
            "p_ram_total_gb": HARDWARE_INFO["ram_total_gb"],
            "p_disk_total_gb": HARDWARE_INFO["disk_total_gb"],
            "p_readings": readings_payload
        }

        # 3. Transmit batch to cloud RPC
        try:
            response = requests.post(rpc_url, json=body, headers=headers, timeout=12.0)
            if response.status_code in (200, 201):
                # Successfully ingested into cloud database
                self.buffer.mark_as_synced(record_ids)
                count = len(record_ids)
                return True, count, f"Successfully uploaded batch of {count} metrics to cloud."
            else:
                error_detail = response.text[:200]
                return False, 0, f"Cloud ingestion error ({response.status_code}): {error_detail}"
        except requests.exceptions.RequestException as ex:
            return False, 0, f"Network unreachable ({ex.__class__.__name__}). Buffering locally."
        except Exception as ex:
            return False, 0, f"Sync error: {str(ex)}"
