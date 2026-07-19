import config from './config.js';
import { signPayload } from './security.js';

export class WebsiteWorker {
  constructor(logger) {
    this.logger = logger;
    this.timer = null;
    this.busy = false;
    this.lastRunAt = null;
    this.lastSuccessAt = null;
    this.lastError = null;
  }

  start() {
    if (!config.WEBSITE_WORKER_URL || this.timer) return;
    const run = () => this.tick().catch(error => this.logger.error({ err: error }, 'Website worker error'));
    this.timer = setInterval(run, config.WEBSITE_WORKER_INTERVAL_MS);
    setTimeout(run, 10_000).unref();
  }

  async tick() {
    if (this.busy || !config.WEBSITE_WORKER_URL) return;
    this.busy = true;
    const body = JSON.stringify({
      action: 'drain',
      timestamp: Math.floor(Date.now() / 1000),
      source: 'nitu-whatsapp-gateway-v2'
    });
    this.lastRunAt = new Date().toISOString();
    try {
      const response = await fetch(config.WEBSITE_WORKER_URL, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'user-agent': 'NituWhatsAppGateway/2.1',
          'x-gateway-signature': signPayload(body)
        },
        body,
        signal: AbortSignal.timeout(20_000)
      });
      const responseText = await response.text();
      if (!response.ok) throw new Error(`Website worker HTTP ${response.status}: ${responseText.slice(0, 300)}`);
      this.lastSuccessAt = new Date().toISOString();
      this.lastError = null;
      this.logger.info({ response: responseText.slice(0, 300) }, 'Website queue worker completed');
    } catch (error) {
      this.lastError = String(error?.message || error);
      this.logger.warn({ err: error }, 'Website queue worker failed');
    } finally {
      this.busy = false;
    }
  }

  status() {
    return {
      enabled: Boolean(config.WEBSITE_WORKER_URL),
      busy: this.busy,
      lastRunAt: this.lastRunAt,
      lastSuccessAt: this.lastSuccessAt,
      lastError: this.lastError
    };
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }
}
