"""
Cloud Synchronization Engine
Transmits batched readings from SQLite buffer to Supabase RPC 'ingest_readings'.
Hardened with cryptographic device authentication and eventual consistency.
"""

import logging
import requests
from typing import Tuple
from . import config
from .buffer import LocalBuffer

logger = logging.getLogger("pc_agent_sync")

class SyncEngine:
    def __init__(self, buffer: LocalBuffer):
        self.buffer = buffer

    def check_connectivity(self) -> bool:
        """Quick check to see if Supabase or general internet is reachable."""
        url = config.SUPABASE_URL
        key = config.SUPABASE_KEY
        if not url:
            return False
        try:
            # Ping Supabase REST health endpoint with short timeout
            ping_url = f"{url}/rest/v1/"
            headers = {"apikey": key} if key else {}
            if key and key.count(".") == 2:
                headers["Authorization"] = f"Bearer {key}"
            resp = requests.get(ping_url, headers=headers, timeout=4.0)
            return resp.status_code in (200, 401, 404, 400) # Reached cloud host
        except Exception:
            return False

    def sync_batch(self, batch_limit: int = None) -> Tuple[bool, int, str]:
        """
        Attempts to transmit unsynced buffered telemetry to Supabase.
        Authenticates with device_id and device_api_key.
        Returns: (success: bool, records_synced: int, message: str)
        """
        url = config.SUPABASE_URL
        key = config.SUPABASE_KEY
        limit = batch_limit or config.BATCH_SIZE_LIMIT

        if not url or not key:
            return False, 0, "Supabase credentials not configured in agent/.env. Buffering locally."

        # 1. Fetch pending batch from SQLite buffer
        pending_items = self.buffer.get_unsynced_readings(limit=limit)
        if not pending_items:
            return True, 0, "Buffer empty (All metrics synchronized)."

        record_ids = [item[0] for item in pending_items]
        readings_payload = [item[1] for item in pending_items]

        # 2. Prepare RPC payload matching ingest_readings() signature
        rpc_url = f"{url}/rest/v1/rpc/ingest_readings"
        headers = {
            "apikey": key,
            "Content-Type": "application/json",
            "Prefer": "return=representation"
        }
        # Support both new Supabase publishable keys (sb_publishable_...) and legacy JWT anon keys (eyJ...)
        if key and key.count(".") == 2:
            headers["Authorization"] = f"Bearer {key}"
        body = {
            "p_device_id": config.HARDWARE_INFO["device_id"],
            "p_device_api_key": config.DEVICE_API_KEY,
            "p_dashboard_token": config.DASHBOARD_TOKEN,
            "p_enrollment_token": config.ENROLLMENT_TOKEN,
            "p_hostname": config.HARDWARE_INFO["hostname"],
            "p_os_info": config.HARDWARE_INFO["os_info"],
            "p_cpu_model": config.HARDWARE_INFO["cpu_model"],
            "p_cpu_cores": config.HARDWARE_INFO["cpu_cores"],
            "p_ram_total_gb": config.HARDWARE_INFO["ram_total_gb"],
            "p_disk_total_gb": config.HARDWARE_INFO["disk_total_gb"],
            "p_readings": readings_payload
        }

        # 3. Transmit batch to cloud RPC
        try:
            response = requests.post(rpc_url, json=body, headers=headers, timeout=12.0)
            if response.status_code in (200, 201):
                try:
                    res_data = response.json()
                except Exception:
                    res_data = {}

                # Check if RPC returned an internal SQL exception or auth failure
                if isinstance(res_data, dict) and res_data.get("success") is False:
                    err_msg = res_data.get("error", "Database ingestion error")
                    return False, 0, f"Cloud database rejected batch: {err_msg}"

                # Successfully ingested into cloud database
                self.buffer.mark_as_synced(record_ids)
                count = len(record_ids)
                return True, count, f"Successfully uploaded batch of {count} metrics to cloud."
            elif response.status_code == 401:
                return False, 0, "Authentication failed (401). Verify SUPABASE_KEY (anon key) in agent/.env."
            elif response.status_code == 404:
                return False, 0, "RPC function 'ingest_readings' not found (404). Run cloud/full_database_setup.sql in Supabase."
            else:
                error_detail = response.text[:200]
                return False, 0, f"Cloud ingestion error ({response.status_code}): {error_detail}"
        except requests.exceptions.Timeout:
            return False, 0, "Cloud request timed out (12s). Buffering locally."
        except requests.exceptions.ConnectionError:
            return False, 0, "Network connection error. Buffering locally until connection resumes."
        except requests.exceptions.RequestException as ex:
            return False, 0, f"Network unreachable ({ex.__class__.__name__}). Buffering locally."
        except Exception as ex:
            return False, 0, f"Sync error: {str(ex)}"
