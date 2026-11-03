"""
Desktop Agent Tkinter Graphical Interface
Displays live hardware metrics, buffer state, and cloud sync status.
"""

import time
import tkinter as tk
from tkinter import ttk, messagebox
import datetime
from typing import Callable, Optional
from . import config
from .config import HARDWARE_INFO, open_dashboard_in_browser

# Aesthetic Color Palette (Dark High-Tech Theme)
BG_DARK = "#0e131f"
CARD_BG = "#161d2e"
CARD_BORDER = "#232f4a"
TEXT_PRIMARY = "#f0f4fc"
TEXT_MUTED = "#8292ab"
CYAN_ACCENT = "#00d2ff"
EMERALD_GREEN = "#00e676"
AMBER_WARNING = "#ffab00"
RED_CRITICAL = "#ff1744"

class AgentGUI:
    def __init__(self, root: tk.Tk, on_manual_sync: Callable[[], None]):
        self.root = root
        self.on_manual_sync = on_manual_sync
        self._last_alert_times = {}
        
        self.root.title("PC Health Monitoring Agent - Cloud Sync")
        self.root.geometry("640x740")
        self.root.minsize(580, 650)
        self.root.configure(bg=BG_DARK)

        self._build_styles()
        self._build_ui()

    def _build_styles(self):
        self.style = ttk.Style()
        self.style.theme_use("clam")

        # Custom progress bars
        self.style.configure(
            "Cyan.Horizontal.TProgressbar",
            troughcolor=CARD_BORDER,
            background=CYAN_ACCENT,
            thickness=14
        )
        self.style.configure(
            "Emerald.Horizontal.TProgressbar",
            troughcolor=CARD_BORDER,
            background=EMERALD_GREEN,
            thickness=14
        )
        self.style.configure(
            "Amber.Horizontal.TProgressbar",
            troughcolor=CARD_BORDER,
            background=AMBER_WARNING,
            thickness=14
        )
        self.style.configure(
            "Red.Horizontal.TProgressbar",
            troughcolor=CARD_BORDER,
            background=RED_CRITICAL,
            thickness=14
        )

    def _build_ui(self):
        # 1. Header Frame
        header = tk.Frame(self.root, bg=CARD_BG, padx=20, pady=16, highlightthickness=1, highlightbackground=CARD_BORDER)
        header.pack(fill="x", padx=16, pady=(16, 10))

        title_lbl = tk.Label(
            header,
            text="PC HEALTH MONITOR AGENT",
            font=("Segoe UI", 14, "bold"),
            fg=CYAN_ACCENT,
            bg=CARD_BG
        )
        title_lbl.pack(anchor="w")

        sub_info = f"Host: {HARDWARE_INFO['hostname']} | OS: {HARDWARE_INFO['os_info'][:35]} | ID: {HARDWARE_INFO['device_id'][:8]}..."
        sub_lbl = tk.Label(header, text=sub_info, font=("Segoe UI", 8), fg=TEXT_MUTED, bg=CARD_BG)
        sub_lbl.pack(anchor="w", pady=(2, 8))

        # Status Pill Bar
        status_bar = tk.Frame(header, bg=CARD_BG)
        status_bar.pack(fill="x")

        self.status_indicator = tk.Label(
            status_bar,
            text="● INITIALIZING",
            font=("Segoe UI", 9, "bold"),
            fg=AMBER_WARNING,
            bg="#2a2412",
            padx=10,
            pady=3
        )
        self.status_indicator.pack(side="left")

        self.buffer_badge = tk.Label(
            status_bar,
            text="Buffer: 0 items queued",
            font=("Segoe UI", 9),
            fg=TEXT_MUTED,
            bg=CARD_BG,
            padx=10
        )
        self.buffer_badge.pack(side="left")

        # 2. Metrics Cards Frame
        metrics_container = tk.Frame(self.root, bg=BG_DARK)
        metrics_container.pack(fill="x", padx=16, pady=6)

        # CPU Card
        self.cpu_frame, self.cpu_val, self.cpu_sub, self.cpu_bar = self._create_metric_card(
            metrics_container, "CPU UTILIZATION", "0.0%", "Freq: -- MHz"
        )
        self.cpu_frame.pack(fill="x", pady=4)

        # RAM Card
        self.ram_frame, self.ram_val, self.ram_sub, self.ram_bar = self._create_metric_card(
            metrics_container, "RAM USAGE", "0.0%", f"0 / {HARDWARE_INFO['ram_total_gb']} GB"
        )
        self.ram_frame.pack(fill="x", pady=4)

        # Disk Card
        self.disk_frame, self.disk_val, self.disk_sub, self.disk_bar = self._create_metric_card(
            metrics_container, "STORAGE USAGE", "0.0%", f"0 / {HARDWARE_INFO['disk_total_gb']} GB"
        )
        self.disk_frame.pack(fill="x", pady=4)

        # Battery Card
        self.batt_frame, self.batt_val, self.batt_sub, self.batt_bar = self._create_metric_card(
            metrics_container, "BATTERY STATUS", "--", "Status: Checking..."
        )
        self.batt_frame.pack(fill="x", pady=4)

        # 3. Actions / Controls Bar
        action_bar = tk.Frame(self.root, bg=BG_DARK)
        action_bar.pack(fill="x", padx=16, pady=10)

        self.btn_web = tk.Button(
            action_bar,
            text="🌐 VIEW IN WEB DASHBOARD",
            font=("Segoe UI", 9, "bold"),
            bg="#0f3e36",
            fg=EMERALD_GREEN,
            activebackground=EMERALD_GREEN,
            activeforeground="#000000",
            relief="flat",
            padx=14,
            pady=8,
            cursor="hand2",
            command=self._on_open_dashboard
        )
        self.btn_web.pack(side="left", padx=(0, 10))

        self.btn_sync = tk.Button(
            action_bar,
            text="⚡ SYNC NOW",
            font=("Segoe UI", 9, "bold"),
            bg="#1d3d63",
            fg=CYAN_ACCENT,
            activebackground=CYAN_ACCENT,
            activeforeground="#000000",
            relief="flat",
            padx=14,
            pady=8,
            cursor="hand2",
            command=self._on_sync_click
        )
        self.btn_sync.pack(side="left", padx=(0, 10))

        self.btn_config = tk.Button(
            action_bar,
            text="⚙ Settings",
            font=("Segoe UI", 9),
            bg=CARD_BG,
            fg=TEXT_PRIMARY,
            relief="flat",
            padx=10,
            pady=8,
            cursor="hand2",
            command=self._open_config_dialog
        )
        self.btn_config.pack(side="left")

        # 4. Activity Terminal / Log View
        log_frame = tk.Frame(self.root, bg=CARD_BG, padx=12, pady=10, highlightthickness=1, highlightbackground=CARD_BORDER)
        log_frame.pack(fill="both", expand=True, padx=16, pady=(0, 16))

        log_lbl = tk.Label(log_frame, text="AGENT EVENT LOG & BUFFER ACTIVITY", font=("Segoe UI", 8, "bold"), fg=TEXT_MUTED, bg=CARD_BG)
        log_lbl.pack(anchor="w", pady=(0, 4))

        self.log_text = tk.Text(
            log_frame,
            bg="#090d15",
            fg="#a6b7d4",
            insertbackground="#00d2ff",
            font=("Consolas", 8),
            height=7,
            relief="flat",
            wrap="word"
        )
        self.log_text.pack(fill="both", expand=True)

    def _create_metric_card(self, parent, title: str, init_val: str, init_sub: str):
        card = tk.Frame(parent, bg=CARD_BG, padx=14, pady=10, highlightthickness=1, highlightbackground=CARD_BORDER)
        
        # Row 1: Title and Main Value
        row1 = tk.Frame(card, bg=CARD_BG)
        row1.pack(fill="x")

        lbl_title = tk.Label(row1, text=title, font=("Segoe UI", 8, "bold"), fg=TEXT_MUTED, bg=CARD_BG)
        lbl_title.pack(side="left")

        lbl_val = tk.Label(row1, text=init_val, font=("Segoe UI", 11, "bold"), fg=TEXT_PRIMARY, bg=CARD_BG)
        lbl_val.pack(side="right")

        # Row 2: Progress Bar
        bar = ttk.Progressbar(card, orient="horizontal", mode="determinate", style="Cyan.Horizontal.TProgressbar")
        bar.pack(fill="x", pady=(6, 4))

        # Row 3: Subtext details
        lbl_sub = tk.Label(card, text=init_sub, font=("Segoe UI", 8), fg=TEXT_MUTED, bg=CARD_BG)
        lbl_sub.pack(anchor="w")

        return card, lbl_val, lbl_sub, bar

    def _get_bar_style_for_val(self, percent: float) -> str:
        if percent >= 90:
            return "Red.Horizontal.TProgressbar"
        if percent >= 80:
            return "Amber.Horizontal.TProgressbar"
        return "Cyan.Horizontal.TProgressbar"

    def _check_and_log_alert(self, metric_type: str, message: str, cooldown: float = 30.0):
        now = time.time()
        last_t = self._last_alert_times.get(metric_type, 0.0)
        if now - last_t >= cooldown:
            self._last_alert_times[metric_type] = now
            self.append_log(message)

    def update_metrics(self, data: dict):
        """Thread-safe UI update of live hardware figures."""
        # CPU
        cpu = data.get("cpu_percent", 0.0)
        self.cpu_val.config(text=f"{cpu}%")
        self.cpu_bar["value"] = cpu
        self.cpu_bar.configure(style=self._get_bar_style_for_val(cpu))
        freq_str = f"Freq: {data.get('cpu_freq_mhz', '--')} MHz | Cores: {HARDWARE_INFO['cpu_cores']}"
        self.cpu_sub.config(text=freq_str)
        if cpu >= 90.0:
            self._check_and_log_alert("CPU_CRIT", f"🚨 CRITICAL CPU SPIKE: {cpu}% utilization!")
        elif cpu >= 80.0:
            self._check_and_log_alert("CPU_WARN", f"⚠️ HIGH CPU LOAD: {cpu}% utilization.")

        # RAM
        ram = data.get("ram_percent", 0.0)
        self.ram_val.config(text=f"{ram}%")
        self.ram_bar["value"] = ram
        self.ram_bar.configure(style=self._get_bar_style_for_val(ram))
        self.ram_sub.config(text=f"Used: {data.get('ram_used_gb', 0)} GB / {data.get('ram_total_gb', 0)} GB")
        if ram >= 90.0:
            self._check_and_log_alert("RAM_CRIT", f"🚨 CRITICAL RAM EXHAUSTION: {ram}% ({data.get('ram_used_gb', 0)} GB used)!")
        elif ram >= 85.0:
            self._check_and_log_alert("RAM_WARN", f"⚠️ ELEVATED RAM USAGE: {ram}%.")

        # Disk
        disk = data.get("disk_percent", 0.0)
        self.disk_val.config(text=f"{disk}%")
        self.disk_bar["value"] = disk
        self.disk_bar.configure(style=self._get_bar_style_for_val(disk))
        self.disk_sub.config(text=f"Used: {data.get('disk_used_gb', 0)} GB / {data.get('disk_total_gb', 0)} GB")
        if disk >= 92.0:
            self._check_and_log_alert("DISK_CRIT", f"🚨 CRITICAL DISK FULL: {disk}% capacity used!")
        elif disk >= 85.0:
            self._check_and_log_alert("DISK_WARN", f"⚠️ HIGH DISK OCCUPANCY: {disk}% capacity used.")

        # Battery
        batt = data.get("battery_percent")
        if batt is not None:
            plugged = "AC Connected 🔌" if data.get("battery_plugged") else "On Battery 🔋"
            self.batt_val.config(text=f"{batt}%")
            self.batt_bar["value"] = batt
            self.batt_bar.configure(style="Emerald.Horizontal.TProgressbar" if batt > 20 else "Red.Horizontal.TProgressbar")
            self.batt_sub.config(text=f"Status: {plugged}")
            if batt <= 15.0 and not data.get("battery_plugged"):
                self._check_and_log_alert("BATT_CRIT", f"🚨 CRITICAL BATTERY: {batt}% remaining! Connect AC adapter.")
        else:
            self.batt_val.config(text="N/A")
            self.batt_bar["value"] = 100
            self.batt_sub.config(text="Desktop system (No battery sensor)")

    def update_status(self, is_online: bool, unsynced_count: int, message: str = ""):
        """Updates the status pill and queue counter."""
        if is_online:
            self.status_indicator.config(
                text="● CLOUD SYNCHRONIZED",
                fg=EMERALD_GREEN,
                bg="#0b281b"
            )
        else:
            self.status_indicator.config(
                text="● OFFLINE - BUFFERING",
                fg=AMBER_WARNING,
                bg="#2a200f"
            )

        self.buffer_badge.config(text=f"Buffer: {unsynced_count} records pending sync")

    def append_log(self, text: str):
        now = datetime.datetime.now().strftime("%H:%M:%S")
        self.log_text.insert("end", f"[{now}] {text}\n")
        self.log_text.see("end")

    def _on_sync_click(self):
        self.append_log("Triggering manual synchronization batch...")
        if self.on_manual_sync:
            self.on_manual_sync()

    def _on_open_dashboard(self):
        target = open_dashboard_in_browser()
        self.append_log("Opened web dashboard linked to this device ID.")

    def _open_config_dialog(self):
        dialog = tk.Toplevel(self.root)
        dialog.title("Cloud Configuration (Supabase & Dashboard)")
        dialog.geometry("520x420")
        dialog.configure(bg=CARD_BG)
        dialog.transient(self.root)
        dialog.grab_set()

        lbl_hdr = tk.Label(dialog, text="Cloud Settings & Endpoints", font=("Segoe UI", 12, "bold"), fg=CYAN_ACCENT, bg=CARD_BG)
        lbl_hdr.pack(anchor="w", padx=20, pady=(18, 10))

        tk.Label(dialog, text="Supabase Project URL:", font=("Segoe UI", 9), fg=TEXT_MUTED, bg=CARD_BG).pack(anchor="w", padx=20)
        ent_url = tk.Entry(dialog, bg="#0e131f", fg=TEXT_PRIMARY, insertbackground=CYAN_ACCENT, font=("Segoe UI", 9))
        ent_url.pack(fill="x", padx=20, pady=(4, 10))
        ent_url.insert(0, config.SUPABASE_URL)

        tk.Label(dialog, text="Supabase anon / public Key:", font=("Segoe UI", 9), fg=TEXT_MUTED, bg=CARD_BG).pack(anchor="w", padx=20)
        ent_key = tk.Entry(dialog, bg="#0e131f", fg=TEXT_PRIMARY, insertbackground=CYAN_ACCENT, font=("Segoe UI", 9))
        ent_key.pack(fill="x", padx=20, pady=(4, 10))
        ent_key.insert(0, config.SUPABASE_KEY)

        tk.Label(dialog, text="Web Dashboard URL (Leave blank for local dashboard):", font=("Segoe UI", 9), fg=TEXT_MUTED, bg=CARD_BG).pack(anchor="w", padx=20)
        ent_dash = tk.Entry(dialog, bg="#0e131f", fg=TEXT_PRIMARY, insertbackground=CYAN_ACCENT, font=("Segoe UI", 9))
        ent_dash.pack(fill="x", padx=20, pady=(4, 18))
        ent_dash.insert(0, config.DASHBOARD_URL)

        def save():
            new_url = ent_url.get().strip()
            new_key = ent_key.get().strip()
            new_dash = ent_dash.get().strip()
            config.save_credentials(new_url, new_key, new_dash)
            self.append_log("Configuration updated and saved to agent/.env.")
            messagebox.showinfo("Saved", "Configuration saved! Settings updated dynamically.", parent=dialog)
            dialog.destroy()

        btn_save = tk.Button(dialog, text="Save Configuration", bg=CYAN_ACCENT, fg="#000", font=("Segoe UI", 9, "bold"), relief="flat", padx=16, pady=6, command=save)
        btn_save.pack(pady=10)
