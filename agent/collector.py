"""
Metrics Collector Module using psutil
Periodically samples CPU, RAM, Disk, Battery, and Network usage.
"""

import time
import datetime
import psutil

# Cache previous network counters to measure throughput
_prev_net = None
_prev_time = None

def collect_system_metrics() -> dict:
    """
    Collects a complete snapshot of host machine health metrics.
    Safe and robust against missing hardware (e.g. desktops with no battery).
    """
    global _prev_net, _prev_time

    current_time = time.time()
    iso_timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()

    # 1. CPU Metrics
    # non-blocking sample
    cpu_percent = psutil.cpu_percent(interval=0.1)
    cpu_freq_mhz = None
    try:
        freq = psutil.cpu_freq()
        if freq:
            cpu_freq_mhz = round(freq.current, 1)
    except Exception:
        pass

    # 2. RAM Metrics
    vm = psutil.virtual_memory()
    ram_percent = vm.percent
    ram_used_gb = round(vm.used / (1024 ** 3), 2)
    ram_total_gb = round(vm.total / (1024 ** 3), 2)

    # 3. Disk Metrics (Primary root disk)
    try:
        du = psutil.disk_usage("/")
    except Exception:
        du = psutil.disk_usage("C:\\")
    disk_percent = du.percent
    disk_used_gb = round(du.used / (1024 ** 3), 2)
    disk_total_gb = round(du.total / (1024 ** 3), 2)

    # 4. Battery Metrics
    battery_percent = None
    battery_plugged = None
    battery_secs_left = None
    try:
        batt = psutil.sensors_battery()
        if batt is not None:
            battery_percent = round(batt.percent, 1)
            battery_plugged = batt.power_plugged
            battery_secs_left = batt.secsleft if batt.secsleft not in (-1, -2) else None
    except Exception:
        pass

    # 5. Network Counters
    net_sent_kb = 0.0
    net_recv_kb = 0.0
    try:
        net_io = psutil.net_io_counters()
        if _prev_net is not None and _prev_time is not None:
            time_delta = max(0.1, current_time - _prev_time)
            bytes_sent = max(0, net_io.bytes_sent - _prev_net.bytes_sent)
            bytes_recv = max(0, net_io.bytes_recv - _prev_net.bytes_recv)
            net_sent_kb = round(bytes_sent / 1024 / time_delta, 2)
            net_recv_kb = round(bytes_recv / 1024 / time_delta, 2)
        _prev_net = net_io
        _prev_time = current_time
    except Exception:
        pass

    return {
        "client_timestamp": iso_timestamp,
        "cpu_percent": round(cpu_percent, 1),
        "cpu_freq_mhz": cpu_freq_mhz,
        "ram_percent": round(ram_percent, 1),
        "ram_used_gb": ram_used_gb,
        "ram_total_gb": ram_total_gb,
        "disk_percent": round(disk_percent, 1),
        "disk_used_gb": disk_used_gb,
        "disk_total_gb": disk_total_gb,
        "battery_percent": battery_percent,
        "battery_plugged": battery_plugged,
        "battery_secs_left": battery_secs_left,
        "net_sent_kb": net_sent_kb,
        "net_recv_kb": net_recv_kb
    }
