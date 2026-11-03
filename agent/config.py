"""
Configuration Module for Desktop Monitoring Agent
Loads environment variables, persists device identity and cryptographic authentication keys,
and inspects hardware metadata.
"""

import os
import sys
import uuid
import secrets
import json
import socket
import platform
import psutil
import webbrowser
import urllib.parse
from pathlib import Path

try:
    from dotenv import load_dotenv as _dotenv_load
except ImportError:
    _dotenv_load = None

# Paths
AGENT_DIR = Path(__file__).resolve().parent
ENV_FILE = AGENT_DIR / ".env"
DEVICE_IDENTITY_FILE = AGENT_DIR / "device_identity.json"
SQLITE_DB_PATH = str(AGENT_DIR / "local_buffer.db")

def load_environment(filepath: Path = ENV_FILE):
    """Loads and cleans environment variables from .env file."""
    if _dotenv_load and filepath.exists():
        _dotenv_load(filepath, override=True)
    elif filepath.exists():
        try:
            with open(filepath, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    k, v = line.split("=", 1)
                    k = k.strip()
                    v = v.strip().strip("'\"")
                    os.environ[k] = v
        except Exception:
            pass

load_environment(ENV_FILE)

# Timings (Per Synopsis Specifications)
COLLECTION_INTERVAL_SECS = int(os.environ.get("COLLECTION_INTERVAL_SECS", 5)) # Poll every 5s
BATCH_SYNC_INTERVAL_SECS = int(os.environ.get("BATCH_SYNC_INTERVAL_SECS", 60)) # Cloud upload every 60s
BATCH_SIZE_LIMIT = int(os.environ.get("BATCH_SIZE_LIMIT", 120))

# Cloud Credentials & Dashboard URLs (Quotes stripped & sanitized)
SUPABASE_URL = os.environ.get("SUPABASE_URL", "").strip().strip("'\"").rstrip("/")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "").strip().strip("'\"")
DASHBOARD_URL = os.environ.get("DASHBOARD_URL", "").strip().strip("'\"").rstrip("/")
DASHBOARD_LOCAL_FILE = AGENT_DIR.parent / "dashboard" / "index.html"
CURRENT_DEVICE_JSON = AGENT_DIR.parent / "dashboard" / "current_device.json"
CURRENT_DEVICE_JS = AGENT_DIR.parent / "dashboard" / "js" / "device_info.js"
CURRENT_DEVICE_LOCAL_JS = AGENT_DIR.parent / "dashboard" / "js" / "device_info.local.js"

# Persistent Device Identification & Cryptographic Secret Keys
def get_or_create_device_identity() -> tuple:
    """
    Returns persistent (device_id, device_api_key, dashboard_token) for this machine.
    Generates cryptographically strong random keys upon first launch:
    - device_api_key: 256-bit secret key used exclusively for telemetry write ingestion
    - dashboard_token: 256-bit read token used by the dashboard for authorized viewing
    """
    dev_id = None
    dev_key = os.environ.get("DEVICE_API_KEY", "").strip().strip("'\"")
    dash_token = os.environ.get("DASHBOARD_TOKEN", "").strip().strip("'\"")

    if DEVICE_IDENTITY_FILE.exists():
        try:
            with open(DEVICE_IDENTITY_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                dev_id = data.get("device_id")
                if not dev_key:
                    dev_key = data.get("device_api_key", "")
                if not dash_token:
                    dash_token = data.get("dashboard_token", "")
        except Exception:
            pass

    if not dev_id:
        dev_id = str(uuid.uuid4())
    if not dev_key:
        dev_key = secrets.token_hex(32) # 256-bit cryptographic hex key (write authorization)
    if not dash_token:
        dash_token = secrets.token_hex(24) # Cryptographic viewer hex key (read authorization)

    try:
        with open(DEVICE_IDENTITY_FILE, "w", encoding="utf-8") as f:
            json.dump({
                "device_id": dev_id,
                "device_api_key": dev_key,
                "dashboard_token": dash_token,
                "created_at": str(platform.node())
            }, f, indent=2)
    except Exception:
        pass

    return dev_id, dev_key, dash_token

DEVICE_ID, DEVICE_API_KEY, DASHBOARD_TOKEN = get_or_create_device_identity()
ENROLLMENT_TOKEN = os.environ.get("ENROLLMENT_TOKEN", "").strip().strip("'\"")
HOSTNAME = socket.gethostname() or platform.node() or "Unknown-PC"

def reload_config():
    """Reloads configuration from .env file at runtime."""
    global SUPABASE_URL, SUPABASE_KEY, DASHBOARD_URL, COLLECTION_INTERVAL_SECS, BATCH_SYNC_INTERVAL_SECS, BATCH_SIZE_LIMIT, DEVICE_API_KEY, DASHBOARD_TOKEN, ENROLLMENT_TOKEN
    load_environment(ENV_FILE)
    SUPABASE_URL = os.environ.get("SUPABASE_URL", "").strip().strip("'\"").rstrip("/")
    SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "").strip().strip("'\"")
    DASHBOARD_URL = os.environ.get("DASHBOARD_URL", "").strip().strip("'\"").rstrip("/")
    COLLECTION_INTERVAL_SECS = int(os.environ.get("COLLECTION_INTERVAL_SECS", 5))
    BATCH_SYNC_INTERVAL_SECS = int(os.environ.get("BATCH_SYNC_INTERVAL_SECS", 60))
    BATCH_SIZE_LIMIT = int(os.environ.get("BATCH_SIZE_LIMIT", 120))
    ENROLLMENT_TOKEN = os.environ.get("ENROLLMENT_TOKEN", "").strip().strip("'\"")
    env_key = os.environ.get("DEVICE_API_KEY", "").strip().strip("'\"")
    if env_key:
        DEVICE_API_KEY = env_key
    env_dash = os.environ.get("DASHBOARD_TOKEN", "").strip().strip("'\"")
    if env_dash:
        DASHBOARD_TOKEN = env_dash

def save_credentials(supabase_url: str, supabase_key: str, dashboard_url: str = ""):
    """Saves updated credentials to .env file preserving other configuration."""
    clean_url = supabase_url.strip().strip("'\"").rstrip("/")
    clean_key = supabase_key.strip().strip("'\"")
    clean_dash = dashboard_url.strip().strip("'\"").rstrip("/")

    # Read existing settings or create defaults
    lines = []
    keys_written = set()
    if ENV_FILE.exists():
        try:
            with open(ENV_FILE, "r", encoding="utf-8") as f:
                for line in f:
                    stripped = line.strip()
                    if stripped.startswith("SUPABASE_URL="):
                        lines.append(f"SUPABASE_URL={clean_url}\n")
                        keys_written.add("SUPABASE_URL")
                    elif stripped.startswith("SUPABASE_KEY="):
                        lines.append(f"SUPABASE_KEY={clean_key}\n")
                        keys_written.add("SUPABASE_KEY")
                    elif stripped.startswith("DASHBOARD_URL="):
                        lines.append(f"DASHBOARD_URL={clean_dash}\n")
                        keys_written.add("DASHBOARD_URL")
                    else:
                        lines.append(line)
        except Exception:
            pass

    if "SUPABASE_URL" not in keys_written:
        lines.append(f"SUPABASE_URL={clean_url}\n")
    if "SUPABASE_KEY" not in keys_written:
        lines.append(f"SUPABASE_KEY={clean_key}\n")
    if "DASHBOARD_URL" not in keys_written:
        lines.append(f"DASHBOARD_URL={clean_dash}\n")

    with open(ENV_FILE, "w", encoding="utf-8") as f:
        f.writelines(lines)

    reload_config()

# System Hardware Specifications
def get_hardware_info() -> dict:
    cpu_cores = psutil.cpu_count(logical=True) or 1
    cpu_model = platform.processor() or "Generic Processor"
    
    ram_bytes = psutil.virtual_memory().total
    ram_gb = round(ram_bytes / (1024 ** 3), 2)
    
    try:
        disk_bytes = psutil.disk_usage(os.path.abspath(os.sep)).total
        disk_gb = round(disk_bytes / (1024 ** 3), 2)
    except Exception:
        try:
            disk_bytes = psutil.disk_usage("/").total
            disk_gb = round(disk_bytes / (1024 ** 3), 2)
        except Exception:
            disk_gb = 100.0

    os_info = f"{platform.system()} {platform.release()} ({platform.machine()})"

    info = {
        "device_id": DEVICE_ID,
        "device_api_key": DEVICE_API_KEY,
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
        # Note: Do not write device_api_key to public files for defense-in-depth.
        safe_info = {k: v for k, v in info.items() if k != "device_api_key"}
        safe_info["dashboard_token"] = DASHBOARD_TOKEN
        if SUPABASE_URL:
            safe_info["supabase_url"] = SUPABASE_URL
        if SUPABASE_KEY:
            safe_info["supabase_key"] = SUPABASE_KEY

        # 1. Local JSON cache (Git-ignored)
        with open(CURRENT_DEVICE_JSON, "w", encoding="utf-8") as f:
            json.dump(safe_info, f, indent=2)

        # 2. Local-only JS bridge (Git-ignored: never committed to GitHub or Vercel)
        CURRENT_DEVICE_LOCAL_JS.parent.mkdir(parents=True, exist_ok=True)
        with open(CURRENT_DEVICE_LOCAL_JS, "w", encoding="utf-8") as f:
            f.write(f"// Local-only bridge for offline/localhost development (Git-ignored)\nwindow.CURRENT_DEVICE = {json.dumps(safe_info, indent=2)};\n")

        # 3. Public production template (Tracked in Git): ensure it exists with safe sanitized template
        if not CURRENT_DEVICE_JS.exists():
            template = {
                "device_id": "unpaired-node",
                "hostname": "WAITING FOR AGENT LINK",
                "os_info": "Open Agent & Click 'View in Web Dashboard'",
                "cpu_model": "Generic Processor",
                "cpu_cores": 8,
                "ram_total_gb": 16.0,
                "disk_total_gb": 512.0,
                "agent_version": "1.0.0",
                "dashboard_token": ""
            }
            with open(CURRENT_DEVICE_JS, "w", encoding="utf-8") as f:
                f.write(f"// Public production template - Real tokens are passed exclusively via URL hash fragments (#token=...)\nwindow.CURRENT_DEVICE = {json.dumps(template, indent=2)};\n")
    except Exception:
        pass

    return info

HARDWARE_INFO = get_hardware_info()

def open_dashboard_in_browser():
    """
    Opens the web dashboard in the default browser passing laptop metadata in query params
    and sensitive dashboard read token securely via URL hash fragment (RFC 3986).
    Hash fragments are never transmitted to web servers, preventing leakage in server logs,
    intermediate proxies, and HTTP Referer headers.
    """
    params = urllib.parse.urlencode({
        "device_id": DEVICE_ID,
        "hostname": HOSTNAME,
        "cores": HARDWARE_INFO["cpu_cores"],
        "ram": HARDWARE_INFO["ram_total_gb"],
        "disk": HARDWARE_INFO["disk_total_gb"],
        "os": HARDWARE_INFO["os_info"]
    })
    fragment = f"#token={DASHBOARD_TOKEN}"
    if DASHBOARD_URL:
        target = f"{DASHBOARD_URL}?{params}{fragment}"
    else:
        target = f"{DASHBOARD_LOCAL_FILE.as_uri()}?{params}{fragment}"
    webbrowser.open(target)
    return target
