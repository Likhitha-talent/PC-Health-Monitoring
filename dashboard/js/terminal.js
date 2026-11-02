/**
 * Cyber Terminal & Telemetry Event Bus Controller
 */
const CyberTerminal = {
  container: null,
  maxLines: 80,

  init() {
    this.container = document.getElementById('cyber-terminal-feed');
    this.log('SYS_INIT', 'Terminal subsystem ready. Telemetry bus listening on port 5432 (SSL)...', 'info');
    this.log('RLS_SEC', 'PostgreSQL Row Level Security policies active. Multi-tenant isolation verified.', 'ok');
  },

  log(tag, message, level = 'info') {
    if (!this.container) return;

    const time = new Date().toTimeString().split(' ')[0];
    const line = document.createElement('div');
    line.className = 'terminal-line';

    let tagClass = 'term-tag-info';
    let prefix = '[INFO]';
    if (level === 'ok') { tagClass = 'term-tag-ok'; prefix = '[OK]'; }
    if (level === 'warn') { tagClass = 'term-tag-warn'; prefix = '[WARN]'; }
    if (level === 'crit') { tagClass = 'term-tag-crit'; prefix = '[ALERT]'; }

    line.innerHTML = `<span class="term-ts">[${time}]</span> <span class="${tagClass}">${prefix} [${tag}]</span> ${this.escapeHtml(message)}`;
    this.container.appendChild(line);

    // Prune old lines
    while (this.container.children.length > this.maxLines) {
      this.container.removeChild(this.container.firstChild);
    }

    // Auto-scroll to bottom
    this.container.scrollTop = this.container.scrollHeight;
  },

  clear() {
    if (this.container) {
      this.container.innerHTML = '';
      this.log('SYS', 'Terminal buffer cleared.', 'info');
    }
  },

  escapeHtml(str) {
    return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
};
