/**
 * Telemetry Simulator Module
 * Generates realistic hardware telemetry matching the laptop's actual hardware specs.
 */
const TelemetrySimulator = {
  timer: null,
  intervalMs: 4000,
  cpuBase: 26.0,
  ramBase: 65.0,
  diskBase: 61.0,
  batteryLevel: 75.0,
  isPlugged: true,
  packetCount: 1,

  start(onReadingCallback) {
    this.stop();
    this.timer = setInterval(() => {
      const reading = this.generateSample();
      if (onReadingCallback) {
        onReadingCallback(reading);
      }
    }, this.intervalMs);
  },

  stop() {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
  },

  generateSample() {
    this.packetCount++;
    const dev = AppConfig.deviceInfo;

    // Natural fluctuation
    const cpuDelta = (Math.random() - 0.48) * 8.0;
    this.cpuBase = Math.max(12.0, Math.min(88.0, this.cpuBase + cpuDelta));

    const ramDelta = (Math.random() - 0.49) * 1.2;
    this.ramBase = Math.max(40.0, Math.min(88.0, this.ramBase + ramDelta));

    if (!this.isPlugged) {
      this.batteryLevel = Math.max(5.0, this.batteryLevel - 0.1);
    }

    const totalRam = dev.ram_total_gb || 15.71;
    const totalDisk = dev.disk_total_gb || 474.72;
    const ramUsedGb = Number(((this.ramBase / 100) * totalRam).toFixed(2));
    const diskUsedGb = Number(((this.diskBase / 100) * totalDisk).toFixed(1));
    const freqMhz = Math.round(2200 + Math.random() * 800);

    return {
      source: 'simulator',
      device_id: dev.device_id,
      hostname: dev.hostname,
      packet_id: this.packetCount,
      cpu_percent: Number(this.cpuBase.toFixed(1)),
      cpu_freq_mhz: freqMhz,
      ram_percent: Number(this.ramBase.toFixed(1)),
      ram_used_gb: ramUsedGb,
      ram_total_gb: totalRam,
      disk_percent: Number(this.diskBase.toFixed(1)),
      disk_used_gb: diskUsedGb,
      disk_total_gb: totalDisk,
      battery_percent: Number(this.batteryLevel.toFixed(0)),
      battery_plugged: this.isPlugged,
      battery_secs_left: this.isPlugged ? null : 8400,
      timestamp: new Date()
    };
  },

  triggerSyntheticSpike() {
    this.cpuBase = 93.4;
    this.ramBase = 91.2;
    return this.generateSample();
  }
};
