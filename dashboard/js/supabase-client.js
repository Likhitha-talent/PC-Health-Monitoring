/**
 * Supabase Client & Realtime Subscription Handler
 * Subscribes to PostgreSQL Change Data Capture (CDC) via Supabase Realtime Channels
 * Enforces per-device data isolation and passes x-dashboard-token for DB-level RLS authorization.
 */
const SupabaseService = {
  client: null,
  realtimeChannel: null,
  isConnected: false,
  pollInterval: null,
  lastIngestedTimestamp: null,
  lastAlertTimestamp: null,

  init() {
    const url = AppConfig.getSupabaseUrl();
    const key = AppConfig.getSupabaseKey();
    const token = AppConfig.getDashboardToken();

    if (url && key && window.supabase) {
      try {
        const clientOptions = {};
        if (token) {
          clientOptions.global = {
            headers: {
              'x-dashboard-token': token
            }
          };
        }
        this.client = window.supabase.createClient(url, key, clientOptions);
        CyberTerminal.log('SUPABASE', `Client initialized with endpoint: ${url.slice(0, 24)}... (Token: ${token ? 'Secured' : 'None'})`, 'ok');
      } catch (err) {
        CyberTerminal.log('SUPABASE_ERR', `Initialization failed: ${err.message}`, 'crit');
      }
    }
  },

  async testConnection(url, key) {
    if (!window.supabase) {
      return { success: false, message: 'Supabase JS library not loaded' };
    }
    try {
      const tempClient = window.supabase.createClient(url, key);
      const { data, error } = await tempClient
        .from('devices')
        .select('device_id, hostname')
        .limit(1);

      if (error && error.code !== 'PGRST116') {
        if (error.message.includes('FetchError') || error.message.includes('Failed to fetch')) {
          return { success: false, message: 'Could not connect to URL. Check project URL.' };
        }
      }
      return { success: true, message: 'Connection established to Supabase PostgreSQL!' };
    } catch (ex) {
      return { success: false, message: ex.message };
    }
  },

  async connectAndSubscribe(onMetricInsert, onAlertInsert) {
    if (!this.client) {
      this.init();
    }
    if (!this.client) return false;

    const targetDeviceId = (AppConfig.deviceInfo && AppConfig.deviceInfo.device_id && AppConfig.deviceInfo.device_id !== 'unpaired-node') 
      ? AppConfig.deviceInfo.device_id 
      : null;

    try {
      // 1. Fetch authorized device record (RLS enforces device-level isolation)
      let devQuery = this.client.from('devices').select('device_id, hostname, last_seen_at');
      if (targetDeviceId) {
        devQuery = devQuery.eq('device_id', targetDeviceId);
      }
      const { data: devices, error: devErr } = await devQuery.limit(1);

      if (devErr) {
        CyberTerminal.log('AUTH_RLS', `Device query failed or restricted by RLS: ${devErr.message}`, 'warn');
      } else if (!devices || devices.length === 0) {
        if (targetDeviceId) {
          CyberTerminal.log('AUTH_RLS', `Device [${targetDeviceId.slice(0, 8)}...] not found or access denied by PostgreSQL RLS.`, 'warn');
        }
      } else {
        CyberTerminal.log('DEVICES', `Connected to cloud node: ${devices[0].hostname} (${devices[0].device_id.slice(0, 8)}...)`, 'ok');
      }

      // 2. Fetch latest active alerts strictly for this machine
      let alertQuery = this.client.from('alerts').select('*').order('created_at', { ascending: false }).limit(10);
      if (targetDeviceId) {
        alertQuery = alertQuery.eq('device_id', targetDeviceId);
      }
      const { data: alerts, error: alertErr } = await alertQuery;

      if (alerts && onAlertInsert) {
        alerts.forEach(a => onAlertInsert(a, false)); // false = don't sound chime for historical
        if (alerts.length > 0) {
          this.lastAlertTimestamp = alerts[0].created_at;
        }
      }

      // 3. Fetch recent metrics to populate gauges and waveform immediately
      let metricQuery = this.client
        .from('metrics_raw')
        .select('*')
        .order('client_timestamp', { ascending: false })
        .limit(12);
      if (targetDeviceId) {
        metricQuery = metricQuery.eq('device_id', targetDeviceId);
      }
      const { data: recentMetrics, error: metricErr } = await metricQuery;
      if (recentMetrics && recentMetrics.length > 0) {
        // Chronological order: oldest first so charts render timeline properly
        const chronological = [...recentMetrics].reverse();
        chronological.forEach(m => {
          if (onMetricInsert) onMetricInsert(m);
        });
        this.lastIngestedTimestamp = recentMetrics[0].client_timestamp;
        CyberTerminal.log('METRICS', `Loaded ${recentMetrics.length} recent telemetry points from cloud.`, 'ok');
      }

      // 4. Fetch hourly aggregates if present to update historical 24h chart
      let hourlyQuery = this.client
        .from('metrics_hourly')
        .select('*')
        .order('hour_timestamp', { ascending: false })
        .limit(12);
      if (targetDeviceId) {
        hourlyQuery = hourlyQuery.eq('device_id', targetDeviceId);
      }
      const { data: hourlyData, error: hourlyErr } = await hourlyQuery;
      if (hourlyData && hourlyData.length > 0 && typeof TelemetryCharts !== 'undefined') {
        const hChrono = [...hourlyData].reverse();
        const labels = hChrono.map(h => new Date(h.hour_timestamp).getHours() + ':00');
        const avgCpuList = hChrono.map(h => parseFloat(h.avg_cpu));
        const peakCpuList = hChrono.map(h => parseFloat(h.max_cpu));
        TelemetryCharts.updateHistoricalData(labels, avgCpuList, peakCpuList);
      }

      // 5. Subscribe to Realtime Postgres Changes with Device Isolation
      if (this.realtimeChannel) {
        this.client.removeChannel(this.realtimeChannel);
      }

      const rawOpts = { event: 'INSERT', schema: 'public', table: 'metrics_raw' };
      const alertOpts = { event: 'INSERT', schema: 'public', table: 'alerts' };
      if (targetDeviceId) {
        rawOpts.filter = `device_id=eq.${targetDeviceId}`;
        alertOpts.filter = `device_id=eq.${targetDeviceId}`;
      }

      this.realtimeChannel = this.client
        .channel(`device-stream-${targetDeviceId || 'all'}`)
        // Stream incoming raw metrics
        .on(
          'postgres_changes',
          rawOpts,
          (payload) => {
            if (targetDeviceId && payload.new.device_id && payload.new.device_id !== targetDeviceId) return;
            this.lastIngestedTimestamp = payload.new.client_timestamp || new Date().toISOString();
            CyberTerminal.log('CDC_METRIC', `Received Realtime packet: CPU ${payload.new.cpu_percent}% | RAM ${payload.new.ram_percent}%`, 'ok');
            if (onMetricInsert) onMetricInsert(payload.new);
          }
        )
        // Stream incoming event-driven alerts
        .on(
          'postgres_changes',
          alertOpts,
          (payload) => {
            if (targetDeviceId && payload.new.device_id && payload.new.device_id !== targetDeviceId) return;
            this.lastAlertTimestamp = payload.new.created_at || new Date().toISOString();
            CyberTerminal.log('CDC_ALERT', `TRIGGER BREACH: [${payload.new.severity.toUpperCase()}] ${payload.new.message}`, 'crit');
            if (onAlertInsert) onAlertInsert(payload.new, true);
          }
        )
        .subscribe((status) => {
          if (status === 'SUBSCRIBED') {
            this.isConnected = true;
            CyberTerminal.log('REALTIME', `WebSocket pub/sub channel SUBSCRIBED for node [${targetDeviceId || 'GLOBAL'}].`, 'ok');
          }
        });

      // 6. Start Periodic Refresh Polling (every 10s) to guarantee updates regardless of WebSocket state
      this.startPolling(onMetricInsert, onAlertInsert);

      return true;
    } catch (ex) {
      CyberTerminal.log('REALTIME_ERR', `Subscription failed: ${ex.message}`, 'crit');
      return false;
    }
  },

  startPolling(onMetricInsert, onAlertInsert) {
    if (this.pollInterval) clearInterval(this.pollInterval);
    const targetDeviceId = (AppConfig.deviceInfo && AppConfig.deviceInfo.device_id && AppConfig.deviceInfo.device_id !== 'unpaired-node') 
      ? AppConfig.deviceInfo.device_id 
      : null;

    this.pollInterval = setInterval(async () => {
      if (!this.client) return;
      try {
        // Poll for latest metrics
        let q = this.client
          .from('metrics_raw')
          .select('*')
          .order('client_timestamp', { ascending: false })
          .limit(1);
        if (targetDeviceId) {
          q = q.eq('device_id', targetDeviceId);
        }
        const { data: latestMetrics } = await q;
        if (latestMetrics && latestMetrics.length > 0) {
          const latest = latestMetrics[0];
          if (!this.lastIngestedTimestamp || new Date(latest.client_timestamp) > new Date(this.lastIngestedTimestamp)) {
            this.lastIngestedTimestamp = latest.client_timestamp;
            CyberTerminal.log('POLL_METRIC', `Synced latest packet: CPU ${latest.cpu_percent}% | RAM ${latest.ram_percent}%`, 'ok');
            if (onMetricInsert) onMetricInsert(latest);
          }
        }

        // Poll for new alerts
        let aq = this.client
          .from('alerts')
          .select('*')
          .order('created_at', { ascending: false })
          .limit(1);
        if (targetDeviceId) {
          aq = aq.eq('device_id', targetDeviceId);
        }
        const { data: latestAlerts } = await aq;
        if (latestAlerts && latestAlerts.length > 0) {
          const lAlert = latestAlerts[0];
          if (!this.lastAlertTimestamp || new Date(lAlert.created_at) > new Date(this.lastAlertTimestamp)) {
            this.lastAlertTimestamp = lAlert.created_at;
            CyberTerminal.log('POLL_ALERT', `New alert: [${lAlert.severity.toUpperCase()}] ${lAlert.message}`, 'crit');
            if (onAlertInsert) onAlertInsert(lAlert, true);
          }
        }
      } catch (e) {
        // Network or fetch hiccups in background tab are silently ignored
      }
    }, 10000);
  },

  unsubscribe() {
    if (this.pollInterval) {
      clearInterval(this.pollInterval);
      this.pollInterval = null;
    }
    if (this.client && this.realtimeChannel) {
      this.client.removeChannel(this.realtimeChannel);
      this.realtimeChannel = null;
      this.isConnected = false;
      CyberTerminal.log('REALTIME', 'Unsubscribed from Supabase channel.', 'info');
    }
  }
};
