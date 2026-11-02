/**
 * Global Configuration & State Store
 * Handles URL parameter parsing (Method A: One-click launch from Agent)
 * and persists the laptop's real identity in LocalStorage.
 */
const AppConfig = {
  // LocalStorage keys
  STORAGE_URL_KEY: 'aerosys_supabase_url',
  STORAGE_ANON_KEY: 'aerosys_supabase_key',
  STORAGE_AUDIO_KEY: 'aerosys_audio_enabled',
  STORAGE_DEVICE_INFO_KEY: 'aerosys_device_info',

  // Alert Thresholds matching PostgreSQL trigger logic
  THRESHOLDS: {
    CPU_WARN: 80.0,
    CPU_CRIT: 90.0,
    RAM_WARN: 85.0,
    RAM_CRIT: 90.0,
    DISK_WARN: 85.0,
    DISK_CRIT: 92.0,
    BATT_CRIT: 15.0
  },

  // State
  isDemoMode: true,
  audioAlertsEnabled: true,
  deviceInfo: {
    device_id: '',
    hostname: 'Detecting...',
    os_info: 'Inspecting...',
    cpu_cores: 8,
    ram_total_gb: 16.0,
    disk_total_gb: 512.0
  },

  getSupabaseUrl() {
    return localStorage.getItem(this.STORAGE_URL_KEY) || '';
  },

  getSupabaseKey() {
    return localStorage.getItem(this.STORAGE_ANON_KEY) || '';
  },

  saveCredentials(url, key) {
    localStorage.setItem(this.STORAGE_URL_KEY, (url || '').trim().replace(/\/$/, ''));
    localStorage.setItem(this.STORAGE_ANON_KEY, (key || '').trim());
  },

  /**
   * Method A: Inspects URL query params first (when launched from any user's agent),
   * then LocalStorage, then local machine bridge.
   */
  async resolveDeviceProfile() {
    // 1. URL parameters ALWAYS take first priority (passed when ANY person clicks "View in Web Dashboard" on their laptop)
    const urlParams = new URLSearchParams(window.location.search);
    const urlDeviceId = urlParams.get('device_id');
    const urlHostname = urlParams.get('hostname');

    if (urlDeviceId) {
      this.deviceInfo = {
        device_id: urlDeviceId,
        hostname: urlHostname || 'MY-PC',
        os_info: urlParams.get('os') || 'Windows 11',
        cpu_cores: parseInt(urlParams.get('cores') || '8', 10),
        ram_total_gb: parseFloat(urlParams.get('ram') || '16.0'),
        disk_total_gb: parseFloat(urlParams.get('disk') || '512.0')
      };
      localStorage.setItem(this.STORAGE_DEVICE_INFO_KEY, JSON.stringify(this.deviceInfo));
      return this.deviceInfo;
    }

    // 2. Check LocalStorage for previously paired device on this specific browser
    const cached = localStorage.getItem(this.STORAGE_DEVICE_INFO_KEY);
    if (cached) {
      try {
        this.deviceInfo = JSON.parse(cached);
        return this.deviceInfo;
      } catch (e) {}
    }

    // 3. If running locally (file:/// or localhost), check local device_info.js
    if ((window.location.protocol === 'file:' || window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1') && window.CURRENT_DEVICE && window.CURRENT_DEVICE.hostname) {
      this.deviceInfo = {
        device_id: window.CURRENT_DEVICE.device_id,
        hostname: window.CURRENT_DEVICE.hostname,
        os_info: window.CURRENT_DEVICE.os_info,
        cpu_cores: window.CURRENT_DEVICE.cpu_cores || 8,
        ram_total_gb: window.CURRENT_DEVICE.ram_total_gb || 16.0,
        disk_total_gb: window.CURRENT_DEVICE.disk_total_gb || 512.0
      };
      localStorage.setItem(this.STORAGE_DEVICE_INFO_KEY, JSON.stringify(this.deviceInfo));
      return this.deviceInfo;
    }

    // 4. Default state when opened for the first time without an agent link
    this.deviceInfo = {
      device_id: 'unpaired-node',
      hostname: 'WAITING FOR AGENT LINK',
      os_info: 'Open Agent & Click "View in Web Dashboard"',
      cpu_cores: 8,
      ram_total_gb: 16.0,
      disk_total_gb: 512.0
    };
    return this.deviceInfo;
  }
};
