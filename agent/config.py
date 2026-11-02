"""
Configuration Module for Desktop Monitoring Agent
Loads environment variables, persists device identity, and inspects hardware metadata.
"""

import os
import sys
import uuid
import json
import socket
import platform
import psutil
import webbrowser
import urllib.parse
from pathlib import Path

# Paths
AGENT_DIR = Path(__file__).resolve().parent
ENV_FILE = AGENT_DIR / ".env"
DEVICE_IDENTITY_FILE = AGENT_DIR / "device_identity.json"
SQLITE_DB_PATH = str(AGENT_DIR / "local_buffer.db")

# Load simple key=value pairs from .env if present
def load_dotenv(filepath: Path):
    if not filepath.exists():
        return
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())
    except Exception:
        pass

load_dotenv(ENV_FILE)

# Timings (Per Synopsis Specifications)
COLLECTION_INTERVAL_SECS = int(os.environ.get("COLLECTION_INTERVAL_SECS", 5)) # Poll every 5s
BATCH_SYNC_INTERVAL_SECS = int(os.environ.get("BATCH_SYNC_INTERVAL_SECS", 60)) # Cloud upload every 60s
BATCH_SIZE_LIMIT = int(os.environ.get("BATCH_SIZE_LIMIT", 120))

# Cloud Credentials & Dashboard URLs
SUPABASE_URL = os.environ.get("SUPABASE_URL", "").rstrip("/")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "")
DASHBOARD_URL = os.environ.get("DASHBOARD_URL", "").rstrip("/")
DASHBOARD_LOCAL_FILE = AGENT_DIR.parent / "dashboard" / "index.html"
CURRENT_DEVICE_JSON = AGENT_DIR.parent / "dashboard" / "current_device.json"

# Persistent Device Identification
def get_or_create_device_id() -> str:
    """Returns a persistent UUID for this machine across reboots."""
    if DEVICE_IDENTITY_FILE.exists():
        try:
            with open(DEVICE_IDENTITY_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                if "device_id" in data and data["device_id"]:
                    return data["device_id"]
        except Exception:
            pass

    # Generate new device UUID
    new_id = str(uuid.uuid4())
    try:
        with open(DEVICE_IDENTITY_FILE, "w", encoding="utf-8") as f:
            json.dump({"device_id": new_id, "created_at": str(platform.node())}, f, indent=2)
    except Exception:
        pass
    return new_id

DEVICE_ID = get_or_create_device_id()
HOSTNAME = socket.gethostname() or platform.node() or "Unknown-PC"

# System Hardware Specifications
def get_hardware_info() -> dict:
    # CPU
    cpu_cores = psutil.cpu_count(logical=True) or 1
    cpu_model = platform.processor() or "Generic Processor"
    
    # RAM
    ram_bytes = psutil.virtual_memory().total
    ram_gb = round(ram_bytes / (1024 ** 3), 2)
    
    # Disk (Root drive)
    try:
        disk_bytes = psutil.disk_usage(os.path.abspath(os.sep)).total
        disk_gb = round(disk_bytes / (1024 ** 3), 2)
    except Exception:
        disk_gb = 100.0

    # OS Info
    os_info = f"{platform.system()} {platform.release()} ({platform.machine()})"

    info = {
        "device_id": DEVICE_ID,
        "hostname": HOSTNAME,
        "os_info": os_info,
        "cpu_model": cpu_model,
        "cpu_cores": cpu_cores,
        "ram_total_gb": ram_gb,
        "disk_total_gb": disk_gb,
        "agent_version": "1.0.0"
    }

    # Save to dashboard directory so webpage can auto-read this laptop's real specs
    try:
        CURRENT_DEVICE_JSON.parent.mkdir(parents=True, exist_ok=True)
        with open(CURRENT_DEVICE_JSON, "w", encoding="utf-8") as f:
            json.dump(info, f, indent=2)
    except Exception:
        pass

    return info

HARDWARE_INFO = get_hardware_info()

def open_dashboard_in_browser():
    """Opens the web dashboard in the default browser passing real laptop identity parameters."""
    params = urllib.parse.urlencode({
        "device_id": DEVICE_ID,
        "hostname": HOSTNAME,
        "cores": HARDWARE_INFO["cpu_cores"],
        "ram": HARDWARE_INFO["ram_total_gb"],
        "disk": HARDWARE_INFO["disk_total_gb"],
        "os": HARDWARE_INFO["os_info"]
    })
    if DASHBOARD_URL:
        target = f"{DASHBOARD_URL}?{params}"
    else:
        target = f"{DASHBOARD_LOCAL_FILE.as_uri()}?{params}"
    webbrowser.open(target)
    return target

