"""
PC Health Monitoring Agent - Main Entry Point
Orchestrates Metric Collection (5s), SQLite Buffering, Cloud Sync (60s), and Tkinter UI.
"""

import sys
import time
import threading
import tkinter as tk
from . import config
from .collector import collect_system_metrics
from .buffer import LocalBuffer
from .sync import SyncEngine
from .gui import AgentGUI

class AgentApp:
    def __init__(self):
        self.buffer = LocalBuffer()
        self.sync_engine = SyncEngine(self.buffer)
        
        self.root = tk.Tk()
        self.gui = AgentGUI(self.root, on_manual_sync=self.trigger_manual_sync)
        
        self.running = True
        self._sync_event = threading.Event()
        self.is_online = False

    def collector_loop(self):
        """Background thread: Samples metrics every 5 seconds and buffers to SQLite."""
        while self.running:
            try:
                # 1. Collect hardware stats
                reading = collect_system_metrics()

                # 2. Persist to local SQLite buffer
                row_id = self.buffer.add_reading(reading)

                # 3. Queue update to Tkinter GUI thread
                stats = self.buffer.get_stats()
                self.root.after(0, self._on_metric_collected, reading, stats)

            except Exception as ex:
                self.root.after(0, self.gui.append_log, f"Collector warning: {str(ex)}")

            time.sleep(config.COLLECTION_INTERVAL_SECS)

    def sync_loop(self):
        """Background thread: Uploads batch to cloud every 60 seconds (or on manual sync)."""
        while self.running:
            # Wait for either the sync interval (60s) or manual trigger event
            self._sync_event.wait(timeout=config.BATCH_SYNC_INTERVAL_SECS)
            self._sync_event.clear()

            if not self.running:
                break

            self._perform_sync()

    def _perform_sync(self):
        try:
            # Check cloud connectivity
            connected = self.sync_engine.check_connectivity()
            self.is_online = connected

            success, count, message = self.sync_engine.sync_batch()
            stats = self.buffer.get_stats()

            # Schedule UI status update
            self.root.after(0, self.gui.update_status, connected and success, stats["unsynced_count"])
            if count > 0:
                self.root.after(0, self.gui.append_log, f"☁️ Cloud Sync: {message}")
            elif not success:
                self.root.after(0, self.gui.append_log, f"⚠️ Cloud Sync: {message}")
            else:
                self.root.after(0, self.gui.append_log, f"ℹ️ {message}")
        except Exception as ex:
            self.root.after(0, self.gui.append_log, f"Sync worker error: {str(ex)}")

    def trigger_manual_sync(self):
        """Called by GUI 'Sync Now' button."""
        self._sync_event.set()

    def _on_metric_collected(self, reading: dict, stats: dict):
        self.gui.update_metrics(reading)
        self.gui.update_status(self.is_online, stats["unsynced_count"])

    def on_closing(self):
        self.running = False
        self._sync_event.set()
        self.root.destroy()
        sys.exit(0)

    def run(self):
        self.root.protocol("WM_DELETE_WINDOW", self.on_closing)

        # Start collection thread (daemon)
        collector_t = threading.Thread(target=self.collector_loop, daemon=True, name="CollectorThread")
        collector_t.start()

        # Start sync thread (daemon)
        sync_t = threading.Thread(target=self.sync_loop, daemon=True, name="SyncThread")
        sync_t.start()

        self.gui.append_log("Desktop Agent initialized.")
        self.gui.append_log(f"Sampling every {config.COLLECTION_INTERVAL_SECS}s | Upload batch every {config.BATCH_SYNC_INTERVAL_SECS}s")

        # Initial quick sync check
        self.trigger_manual_sync()

        # Open local dashboard in default browser on launch
        try:
            config.open_dashboard_in_browser()
            self.gui.append_log("Opened local web dashboard linked to this device ID.")
        except Exception:
            pass

        # Run main Tkinter GUI loop
        self.root.mainloop()

def main():
    app = AgentApp()
    app.run()

if __name__ == "__main__":
    main()
