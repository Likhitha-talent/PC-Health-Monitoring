/**
 * Global Configuration & State Store
 * Handles URL parameter parsing and secure token delivery via URL hash fragments (RFC 3986).
 * Hash fragments are never sent to web servers in HTTP requests and are immediately stripped
 * from the browser address bar and history to prevent leakage via browser logs or referrers.
 */
const AppConfig = {
  // LocalStorage keys
  STORAGE_URL_KEY: 'aerosys_supabase_url',
  STORAGE_ANON_KEY: 'aerosys_supabase_key',
  STORAGE_AUDIO_KEY: 'aerosys_audio_enabled',
  STORAGE_DEVICE_INFO_KEY: 'aerosys_device_info',
  STORAGE_DASHBOARD_TOKEN_KEY: 'aerosys_dashboard_token',

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
    dashboard_token: '',
    hostname: 'Detecting...',
    os_info: 'Inspecting...',
    cpu_cores: 8,
    ram_total_gb: 16.0,
    disk_total_gb: 512.0
  },

  DEFAULT_SUPABASE_URL: 'https://bqnaozqefdexarvujlre.supabase.co',
  DEFAULT_SUPABASE_KEY: 'sb_publishable__GtahVqx1daGBRqkA7UgjQ_a2YPwpxD',

  getSupabaseUrl() {
    return localStorage.getItem(this.STORAGE_URL_KEY) || (window.CURRENT_DEVICE && window.CURRENT_DEVICE.supabase_url) || this.DEFAULT_SUPABASE_URL;
  },

  getSupabaseKey() {
    return localStorage.getItem(this.STORAGE_ANON_KEY) || (window.CURRENT_DEVICE && window.CURRENT_DEVICE.supabase_key) || this.DEFAULT_SUPABASE_KEY;
  },

  getDashboardToken() {
    if (this.deviceInfo && this.deviceInfo.dashboard_token) {
      return this.deviceInfo.dashboard_token;
    }
    const devId = this.deviceInfo ? this.deviceInfo.device_id : '';
    if (devId) {
      return localStorage.getItem(this.STORAGE_DASHBOARD_TOKEN_KEY + '_' + devId) || '';
    }
    return '';
  },

  saveCredentials(url, key) {
    localStorage.setItem(this.STORAGE_URL_KEY, (url || '').trim().replace(/\/$/, ''));
    localStorage.setItem(this.STORAGE_ANON_KEY, (key || '').trim());
  },

  saveDashboardToken(deviceId, token) {
    if (deviceId && token) {
      localStorage.setItem(this.STORAGE_DASHBOARD_TOKEN_KEY + '_' + deviceId, token.trim());
      if (this.deviceInfo && this.deviceInfo.device_id === deviceId) {
        this.deviceInfo.dashboard_token = token.trim();
      }
    }
  },

  /**
   * Resolves Device Identity & Security Tokens:
   * 1. Inspects URL hash fragment for #token=... (never sent to servers, stripped immediately).
   * 2. Inspects query parameters for device_id and hardware specifications (non-sensitive).
   * 3. Checks LocalStorage cache.
   * 4. Checks local desktop bridge (device_info.js) when running locally.
   */
  async resolveDeviceProfile() {
    // 1. Inspect URL hash fragment for secure token delivery (RFC 3986)
    let fragmentToken = '';
    if (window.location.hash) {
      const hashClean = window.location.hash.replace(/^#/, '');
      const hashParams = new URLSearchParams(hashClean);
      fragmentToken = hashParams.get('token') || (hashClean.startsWith('token=') ? hashClean.split('=')[1] : '');

      // Security hardening: IMMEDIATELY strip hash fragment from the browser URL and history
      if (fragmentToken && window.history && window.history.replaceState) {
        const cleanUrl = window.location.pathname + window.location.search;
        window.history.replaceState(null, '', cleanUrl);
      }
    }

    // 2. Query parameters for device_id and hardware metadata (Tokens NEVER accepted via query params)
    const urlParams = new URLSearchParams(window.location.search);
    const urlDeviceId = urlParams.get('device_id');
    const urlHostname = urlParams.get('hostname');

    if (urlDeviceId) {
      const savedToken = fragmentToken || localStorage.getItem(this.STORAGE_DASHBOARD_TOKEN_KEY + '_' + urlDeviceId) || '';
      this.deviceInfo = {
        device_id: urlDeviceId,
        dashboard_token: savedToken,
        hostname: urlHostname || 'MY-PC',
        os_info: urlParams.get('os') || 'Windows 11',
        cpu_cores: parseInt(urlParams.get('cores') || '8', 10),
        ram_total_gb: parseFloat(urlParams.get('ram') || '16.0'),
        disk_total_gb: parseFloat(urlParams.get('disk') || '512.0')
      };
      if (savedToken) {
        localStorage.setItem(this.STORAGE_DASHBOARD_TOKEN_KEY + '_' + urlDeviceId, savedToken);
      }
      localStorage.setItem(this.STORAGE_DEVICE_INFO_KEY, JSON.stringify(this.deviceInfo));
      return this.deviceInfo;
    }

    // 3. Check LocalStorage for previously paired device on this specific browser
    const cached = localStorage.getItem(this.STORAGE_DEVICE_INFO_KEY);
    if (cached) {
      try {
        this.deviceInfo = JSON.parse(cached);
        if (!this.deviceInfo.dashboard_token && this.deviceInfo.device_id) {
          this.deviceInfo.dashboard_token = localStorage.getItem(this.STORAGE_DASHBOARD_TOKEN_KEY + '_' + this.deviceInfo.device_id) || '';
        }
        return this.deviceInfo;
      } catch (e) {}
    }

    // 4. If running locally (file:/// or localhost), check local device_info.js bridge
    if ((window.location.protocol === 'file:' || window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1') && window.CURRENT_DEVICE && window.CURRENT_DEVICE.hostname) {
      this.deviceInfo = {
        device_id: window.CURRENT_DEVICE.device_id,
        dashboard_token: fragmentToken || window.CURRENT_DEVICE.dashboard_token || '',
        hostname: window.CURRENT_DEVICE.hostname,
        os_info: window.CURRENT_DEVICE.os_info,
        cpu_cores: window.CURRENT_DEVICE.cpu_cores || 8,
        ram_total_gb: window.CURRENT_DEVICE.ram_total_gb || 16.0,
        disk_total_gb: window.CURRENT_DEVICE.disk_total_gb || 512.0
      };
      if (this.deviceInfo.dashboard_token && this.deviceInfo.device_id) {
        localStorage.setItem(this.STORAGE_DASHBOARD_TOKEN_KEY + '_' + this.deviceInfo.device_id, this.deviceInfo.dashboard_token);
      }
      localStorage.setItem(this.STORAGE_DEVICE_INFO_KEY, JSON.stringify(this.deviceInfo));
      return this.deviceInfo;
    }

    // 5. Default state when opened without an agent link
    this.deviceInfo = {
      device_id: 'unpaired-node',
      dashboard_token: '',
      hostname: 'WAITING FOR AGENT LINK',
      os_info: 'Open Agent & Click "View in Web Dashboard"',
      cpu_cores: 8,
      ram_total_gb: 16.0,
      disk_total_gb: 512.0
    };
    return this.deviceInfo;
  }
};
