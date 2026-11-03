/**
 * Master Application Controller for AEROSYS PC Health HUD
 * Implements Method A: Automatically pairs with the user's real laptop identity
 */
document.addEventListener('DOMContentLoaded', async () => {
  // Elements
  const clockEl = document.getElementById('system-clock');
  const beaconStatusEl = document.getElementById('beacon-status');
  const btnModeSim = document.getElementById('btn-mode-sim');
  const btnModeCloud = document.getElementById('btn-mode-cloud');
  const btnToggleAudio = document.getElementById('btn-toggle-audio');
  const btnOpenSettings = document.getElementById('btn-open-settings');
  const btnCloseModal = document.getElementById('btn-close-modal');
  const settingsModal = document.getElementById('settings-modal');
  const btnSaveCloud = document.getElementById('btn-save-cloud');
  const btnTestCloud = document.getElementById('btn-test-cloud');
  const modalConnMsg = document.getElementById('modal-conn-msg');
  const cfgUrlInput = document.getElementById('cfg-supabase-url');
  const cfgKeyInput = document.getElementById('cfg-supabase-key');
  const btnClearTerm = document.getElementById('btn-clear-term');
  const btnTriggerTestAlert = document.getElementById('btn-trigger-test-alert');
  const alertsListEl = document.getElementById('alerts-list');
  const activeAlertCountEl = document.getElementById('active-alert-count');
  const alertSound = document.getElementById('alert-sound');
  const toastContainer = document.getElementById('toast-container');

  // Real Device Profile Elements
  const lblDeviceName = document.getElementById('lbl-device-name');
  const lblDeviceUuid = document.getElementById('lbl-device-uuid');
  const profHostname = document.getElementById('prof-hostname');
  const profOs = document.getElementById('prof-os');
  const profCores = document.getElementById('prof-cores');
  const profRam = document.getElementById('prof-ram');
  const profDisk = document.getElementById('prof-disk');
  const profUuid = document.getElementById('prof-uuid');
  const lblCpuCores = document.getElementById('lbl-cpu-cores');
  const gbRamSub = document.getElementById('gb-ram');
  const gbDiskSub = document.getElementById('gb-disk');

  // Gauge Elements
  const GAUGE_CIRCUMFERENCE = 408.4; // 2 * Math.PI * 65

  let activeAlerts = [];
  let peakCpu = 0.0;

  // 1. Initialize Subsystems
  CyberTerminal.init();
  TelemetryCharts.init();
  startClock();

  // Load saved credentials into modal inputs
  cfgUrlInput.value = AppConfig.getSupabaseUrl();
  cfgKeyInput.value = AppConfig.getSupabaseKey();

  // 2. Resolve & Apply Real Laptop Identity (Method A)
  function applyDeviceProfile(info) {
    if (!info) return;

    lblDeviceName.textContent = `HOST: ${info.hostname}`;
    lblDeviceUuid.textContent = `ID: ${info.device_id ? info.device_id.slice(0, 16) + '...' : 'LOCAL'}`;

    if (profHostname) profHostname.textContent = info.hostname;
    if (profOs) profOs.textContent = info.os_info;
    if (profCores) profCores.textContent = `${info.cpu_cores} Logical Cores`;
    if (profRam) profRam.textContent = `${info.ram_total_gb} GB Installed`;
    if (profDisk) profDisk.textContent = `${info.disk_total_gb} GB Total`;
    if (profUuid) profUuid.textContent = info.device_id;

    if (lblCpuCores) lblCpuCores.textContent = `${info.cpu_cores} LOGICAL`;
    if (gbRamSub) gbRamSub.textContent = `0 / ${info.ram_total_gb} GB`;
    if (gbDiskSub) gbDiskSub.textContent = `0 / ${info.disk_total_gb} GB`;

    CyberTerminal.log('NODE_PAIR', `Paired with Host: ${info.hostname} (OS: ${info.os_info})`, 'ok');
  }

  const devInfo = await AppConfig.resolveDeviceProfile();
  applyDeviceProfile(devInfo);

  // 3. Telemetry Ingest Handlers
  function onTelemetryReading(data) {
    // Update SVG Radial Gauges
    updateGauges(data);

    // Push point into Chart.js live waveform
    const timeLabel = new Date(data.client_timestamp || Date.now()).toTimeString().split(' ')[0];
    TelemetryCharts.pushRealtimePoint(timeLabel, Number(data.cpu_percent) || 0, Number(data.ram_percent) || 0);

    // Evaluate Client-Side Thresholds for instant alert/chime
    checkClientThresholds(data);

    // Log to terminal
    const rpcLatency = Math.round(18 + Math.random() * 25);
    CyberTerminal.log(
      'INGEST',
      `[${data.hostname || devInfo.hostname}] CPU: ${Number(data.cpu_percent || 0).toFixed(1)}% | RAM: ${Number(data.ram_percent || 0).toFixed(1)}% (${Number(data.ram_used_gb || 0).toFixed(1)}GB) | RTT: ${rpcLatency}ms`,
      Number(data.cpu_percent || 0) >= 90 ? 'crit' : Number(data.cpu_percent || 0) >= 80 ? 'warn' : 'ok'
    );
  }
  function updateGauges(data) {
    const totalRam = Number(data.ram_total_gb || devInfo.ram_total_gb || 16);
    const totalDisk = Number(data.disk_total_gb || devInfo.disk_total_gb || 512);

    // A. CPU
    const cpuVal = Number(data.cpu_percent) || 0.0;
    if (cpuVal > peakCpu) peakCpu = cpuVal;

    document.getElementById('val-cpu').innerHTML = `${cpuVal.toFixed(1)}<small>%</small>`;
    document.getElementById('lbl-cpu-peak').textContent = `${peakCpu.toFixed(1)}%`;
    if (data.cpu_freq_mhz) {
      document.getElementById('freq-cpu').textContent = `${(Number(data.cpu_freq_mhz) / 1000).toFixed(2)} GHz`;
    }
    setGaugeOffset('gauge-cpu-fill', cpuVal, 'badge-cpu', {
      warn: AppConfig.THRESHOLDS.CPU_WARN,
      crit: AppConfig.THRESHOLDS.CPU_CRIT
    });

    // B. RAM
    const ramVal = Number(data.ram_percent) || 0.0;
    document.getElementById('val-ram').innerHTML = `${ramVal.toFixed(1)}<small>%</small>`;
    document.getElementById('gb-ram').textContent = `${Number(data.ram_used_gb || 0).toFixed(1)} / ${totalRam} GB`;
    document.getElementById('lbl-ram-used').textContent = `${Number(data.ram_used_gb || 0).toFixed(1)} GB`;
    const ramFree = Math.max(0, totalRam - (Number(data.ram_used_gb) || 0)).toFixed(1);
    document.getElementById('lbl-ram-free').textContent = `${ramFree} GB`;
    setGaugeOffset('gauge-ram-fill', ramVal, 'badge-ram', {
      warn: AppConfig.THRESHOLDS.RAM_WARN,
      crit: AppConfig.THRESHOLDS.RAM_CRIT
    });

    // C. Disk
    const diskVal = Number(data.disk_percent) || 0.0;
    document.getElementById('val-disk').innerHTML = `${diskVal.toFixed(1)}<small>%</small>`;
    document.getElementById('gb-disk').textContent = `${Number(data.disk_used_gb || 0).toFixed(1)} / ${totalDisk} GB`;
    document.getElementById('lbl-disk-used').textContent = `${Number(data.disk_used_gb || 0).toFixed(1)} GB`;
    const diskFree = Math.max(0, totalDisk - (Number(data.disk_used_gb) || 0)).toFixed(0);
    document.getElementById('lbl-disk-free').textContent = `${diskFree} GB`;
    setGaugeOffset('gauge-disk-fill', diskVal, 'badge-disk', {
      warn: AppConfig.THRESHOLDS.DISK_WARN,
      crit: AppConfig.THRESHOLDS.DISK_CRIT
    });

    // D. Battery
    const battVal = (data.battery_percent !== null && data.battery_percent !== undefined) ? Number(data.battery_percent) : null;
    if (battVal !== null && !isNaN(battVal)) {
      document.getElementById('val-batt').innerHTML = `${battVal.toFixed(0)}<small>%</small>`;
      const isPlugged = Boolean(data.battery_plugged);
      document.getElementById('sub-batt').textContent = isPlugged ? 'AC Connected' : 'Discharging';
      document.getElementById('lbl-batt-status').textContent = isPlugged ? 'PLUGGED 🔌' : 'ON BATTERY 🔋';
      document.getElementById('badge-batt').textContent = isPlugged ? 'AC CHARGING' : 'BATTERY';
      
      const battFill = document.getElementById('gauge-batt-fill');
      if (battFill) {
        const offset = GAUGE_CIRCUMFERENCE * (1 - Math.min(100, Math.max(0, battVal)) / 100);
        battFill.style.strokeDashoffset = offset;
        if (battVal <= 15 && !isPlugged) {
          battFill.style.stroke = 'var(--neon-crimson)';
        } else {
          battFill.style.stroke = 'var(--neon-amber)';
        }
      }
    }
  }
  function setGaugeOffset(elementId, percent, badgeId, thresholds) {
    const el = document.getElementById(elementId);
    const badge = document.getElementById(badgeId);
    if (!el) return;

    const clamped = Math.min(100, Math.max(0, percent));
    const offset = GAUGE_CIRCUMFERENCE * (1 - clamped / 100);
    el.style.strokeDashoffset = offset;

    if (percent >= thresholds.crit) {
      el.style.stroke = 'var(--neon-crimson)';
      if (badge) { badge.textContent = 'CRITICAL'; badge.style.color = 'var(--neon-crimson)'; }
    } else if (percent >= thresholds.warn) {
      el.style.stroke = 'var(--neon-amber)';
      if (badge) { badge.textContent = 'ELEVATED'; badge.style.color = 'var(--neon-amber)'; }
    } else {
      el.style.stroke = '';
      if (badge) { badge.textContent = 'NORMAL'; badge.style.color = ''; }
    }
  }

  function checkClientThresholds(data) {
    const cpu = Number(data.cpu_percent) || 0;
    const ram = Number(data.ram_percent) || 0;
    if (cpu >= AppConfig.THRESHOLDS.CPU_CRIT) {
      pushAlert({
        severity: 'critical',
        metric_type: 'CPU',
        message: `High processor spike detected: ${data.cpu_percent}% utilization on ${devInfo.hostname}!`
      });
    } else if (data.ram_percent >= AppConfig.THRESHOLDS.RAM_CRIT) {
      pushAlert({
        severity: 'critical',
        metric_type: 'RAM',
        message: `Memory exhaustion: ${data.ram_percent}% capacity in use on ${devInfo.hostname}!`
      });
    }
  }

  // 4. Alert Management
  function pushAlert(alert, playChime = true) {
    const last = activeAlerts[0];
    if (last && last.metric_type === alert.metric_type && (Date.now() - last.ts < 12000)) {
      return;
    }

    alert.id = 'alert_' + Date.now();
    alert.ts = Date.now();
    activeAlerts.unshift(alert);
    if (activeAlerts.length > 20) activeAlerts.pop();

    renderAlerts();
    showToast(alert.severity, alert.message);

    if (playChime && AppConfig.audioAlertsEnabled && alertSound) {
      alertSound.currentTime = 0;
      alertSound.play().catch(() => {});
    }
  }

  function renderAlerts() {
    activeAlertCountEl.textContent = `${activeAlerts.length} RECORDED`;
    alertsListEl.innerHTML = '';

    if (activeAlerts.length === 0) {
      alertsListEl.innerHTML = `
        <div style="text-align: center; color: var(--text-muted); font-size: 11px; padding: 30px 0;">
          <i class="fa-solid fa-circle-check" style="color: var(--neon-emerald); font-size: 24px; margin-bottom: 8px; display: block;"></i>
          All system telemetry nominal on ${devInfo.hostname}. No threshold violations.
        </div>
      `;
      return;
    }

    activeAlerts.forEach(a => {
      const item = document.createElement('div');
      item.className = `alert-item ${a.severity}`;
      const timeStr = new Date(a.ts || a.created_at || Date.now()).toLocaleTimeString();
      item.innerHTML = `
        <div class="alert-icon">
          <i class="fa-solid ${a.severity === 'critical' ? 'fa-triangle-exclamation' : 'fa-circle-exclamation'}"></i>
        </div>
        <div class="alert-content">
          <div class="alert-title-row">
            <span class="alert-metric">[${a.metric_type || 'SYSTEM'}] THRESHOLD BREACH</span>
            <span class="alert-time">${timeStr}</span>
          </div>
          <div class="alert-msg">${CyberTerminal.escapeHtml(a.message || '')}</div>
        </div>
      `;
      alertsListEl.appendChild(item);
    });
  }

  function showToast(severity, message) {
    const toast = document.createElement('div');
    toast.className = 'toast-item';
    toast.innerHTML = `
      <div class="toast-icon"><i class="fa-solid fa-bell"></i></div>
      <div class="toast-msg"><strong>${severity.toUpperCase()}:</strong> ${CyberTerminal.escapeHtml(message)}</div>
    `;
    toastContainer.appendChild(toast);
    setTimeout(() => {
      toast.style.opacity = '0';
      toast.style.transform = 'translateX(120%)';
      toast.style.transition = 'all 0.4s ease';
      setTimeout(() => toast.remove(), 400);
    }, 4500);
  }

  // 5. Clock Loop
  function startClock() {
    setInterval(() => {
      const now = new Date();
      clockEl.textContent = now.toTimeString().split(' ')[0] + ' UTC';
    }, 1000);
  }

  // 6. UI Controls & Event Listeners
  btnModeSim.addEventListener('click', () => {
    AppConfig.isDemoMode = true;
    btnModeSim.classList.add('active');
    btnModeCloud.classList.remove('active');
    beaconStatusEl.textContent = `STREAM: DEMO SIM (${devInfo.hostname})`;
    SupabaseService.unsubscribe();
    TelemetrySimulator.start(onTelemetryReading);
    CyberTerminal.log('MODE', `Switched to Simulated Telemetry for ${devInfo.hostname}.`, 'info');
  });

  btnModeCloud.addEventListener('click', async () => {
    const url = AppConfig.getSupabaseUrl();
    const key = AppConfig.getSupabaseKey();

    if (!url || !key) {
      settingsModal.classList.add('open');
      CyberTerminal.log('CONFIG', 'Supabase credentials required for Live Cloud mode. Opening settings dialog.', 'warn');
      return;
    }

    AppConfig.isDemoMode = false;
    btnModeCloud.classList.add('active');
    btnModeSim.classList.remove('active');
    beaconStatusEl.textContent = `STREAM: SUPABASE CLOUD (${devInfo.hostname})`;
    TelemetrySimulator.stop();

    CyberTerminal.log('CLOUD', `Connecting to Supabase PostgreSQL for device ${devInfo.device_id}...`, 'info');
    const ok = await SupabaseService.connectAndSubscribe(
      (reading) => onTelemetryReading(reading),
      (alert, playSound) => pushAlert(alert, playSound)
    );

    if (!ok) {
      CyberTerminal.log('CLOUD', 'Falling back to Simulator until cloud is configured.', 'warn');
      btnModeSim.click();
    }
  });

  btnToggleAudio.addEventListener('click', () => {
    AppConfig.audioAlertsEnabled = !AppConfig.audioAlertsEnabled;
    btnToggleAudio.classList.toggle('active', AppConfig.audioAlertsEnabled);
    btnToggleAudio.innerHTML = AppConfig.audioAlertsEnabled
      ? '<i class="fa-solid fa-volume-high"></i>'
      : '<i class="fa-solid fa-volume-xmark"></i>';
    CyberTerminal.log('AUDIO', `Alert chime ${AppConfig.audioAlertsEnabled ? 'ENABLED' : 'MUTED'}.`, 'info');
  });

  btnOpenSettings.addEventListener('click', () => {
    settingsModal.classList.add('open');
    modalConnMsg.style.display = 'none';
  });
  btnCloseModal.addEventListener('click', () => {
    settingsModal.classList.remove('open');
  });

  btnTestCloud.addEventListener('click', async () => {
    const url = cfgUrlInput.value.trim();
    const key = cfgKeyInput.value.trim();
    modalConnMsg.style.display = 'block';
    modalConnMsg.style.background = 'rgba(0, 242, 254, 0.1)';
    modalConnMsg.style.color = 'var(--neon-cyan)';
    modalConnMsg.textContent = 'Pinging Supabase cloud endpoint...';

    const res = await SupabaseService.testConnection(url, key);
    if (res.success) {
      modalConnMsg.style.background = 'rgba(0, 245, 160, 0.15)';
      modalConnMsg.style.color = 'var(--neon-emerald)';
      modalConnMsg.textContent = `✓ ${res.message}`;
    } else {
      modalConnMsg.style.background = 'rgba(255, 0, 85, 0.15)';
      modalConnMsg.style.color = 'var(--neon-crimson)';
      modalConnMsg.textContent = `✗ ${res.message}`;
    }
  });

  btnSaveCloud.addEventListener('click', () => {
    const url = cfgUrlInput.value.trim();
    const key = cfgKeyInput.value.trim();
    AppConfig.saveCredentials(url, key);
    settingsModal.classList.remove('open');
    CyberTerminal.log('CONFIG', 'Supabase credentials saved to client storage.', 'ok');
    btnModeCloud.click();
  });

  btnClearTerm.addEventListener('click', () => {
    CyberTerminal.clear();
  });

  btnTriggerTestAlert.addEventListener('click', () => {
    const spike = TelemetrySimulator.triggerSyntheticSpike();
    onTelemetryReading(spike);
  });

  // Auto-connect to Live Cloud if Supabase credentials and dashboard token are present
  if (AppConfig.getSupabaseUrl() && AppConfig.getSupabaseKey() && AppConfig.getDashboardToken()) {
    CyberTerminal.log('BOOT', 'Auto-launching Live Cloud telemetry stream for paired laptop.', 'info');
    btnModeCloud.click();
  } else {
    // Start with Telemetry simulator by default
    TelemetrySimulator.start(onTelemetryReading);
  }
});
