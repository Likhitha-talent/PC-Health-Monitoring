/**
 * Supabase Client & Realtime Subscription Handler
 * Subscribes to PostgreSQL Change Data Capture (CDC) via Supabase Realtime Channels
 */
const SupabaseService = {
  client: null,
  realtimeChannel: null,
  isConnected: false,

  init() {
    const url = AppConfig.getSupabaseUrl();
    const key = AppConfig.getSupabaseKey();

    if (url && key && window.supabase) {
      try {
        this.client = window.supabase.createClient(url, key);
        CyberTerminal.log('SUPABASE', `Client initialized with endpoint: ${url.slice(0, 24)}...`, 'ok');
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
        // Even if empty or RLS blocks anon, reaching server confirms valid credentials
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

    try {
      // 1. Fetch latest registered devices
      const { data: devices, error: devErr } = await this.client
        .from('devices')
        .select('*')
        .order('last_seen_at', { ascending: false });

      if (!devErr && devices && devices.length > 0) {
        CyberTerminal.log('DEVICES', `Found ${devices.length} registered cloud nodes.`, 'ok');
      }

      // 2. Fetch latest active alerts
      const { data: alerts, error: alertErr } = await this.client
        .from('alerts')
        .select('*')
        .order('created_at', { ascending: false })
        .limit(10);

      if (alerts && onAlertInsert) {
        alerts.forEach(a => onAlertInsert(a, false)); // false = don't sound chime for historical
      }

      // 3. Subscribe to Realtime Postgres Changes
      if (this.realtimeChannel) {
        this.client.removeChannel(this.realtimeChannel);
      }

      this.realtimeChannel = this.client
        .channel('schema-db-changes')
        // Stream incoming raw metrics
        .on(
          'postgres_changes',
          { event: 'INSERT', schema: 'public', table: 'metrics_raw' },
          (payload) => {
            CyberTerminal.log('CDC_METRIC', `Received Realtime packet: CPU ${payload.new.cpu_percent}% | RAM ${payload.new.ram_percent}%`, 'ok');
            if (onMetricInsert) onMetricInsert(payload.new);
          }
        )
        // Stream incoming event-driven alerts
        .on(
          'postgres_changes',
          { event: 'INSERT', schema: 'public', table: 'alerts' },
          (payload) => {
            CyberTerminal.log('CDC_ALERT', `TRIGGER BREACH: [${payload.new.severity.toUpperCase()}] ${payload.new.message}`, 'crit');
            if (onAlertInsert) onAlertInsert(payload.new, true);
          }
        )
        .subscribe((status) => {
          if (status === 'SUBSCRIBED') {
            this.isConnected = true;
            CyberTerminal.log('REALTIME', 'WebSocket pub/sub channel SUBSCRIBED to database events.', 'ok');
          }
        });

      return true;
    } catch (ex) {
      CyberTerminal.log('REALTIME_ERR', `Subscription failed: ${ex.message}`, 'crit');
      return false;
    }
  },

  unsubscribe() {
    if (this.client && this.realtimeChannel) {
      this.client.removeChannel(this.realtimeChannel);
      this.realtimeChannel = null;
      this.isConnected = false;
      CyberTerminal.log('REALTIME', 'Unsubscribed from Supabase channel.', 'info');
    }
  }
};
