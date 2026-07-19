import config from './config.js';
import { claimWebhook, markWebhookFailure, markWebhookSent } from './db.js';
import { signPayload } from './security.js';

export class WebhookWorker {
  constructor(logger) {
    this.logger = logger;
    this.timer = null;
    this.busy = false;
  }

  start() {
    if (!config.WEBHOOK_URL || this.timer) return;
    this.timer = setInterval(() => this.tick().catch(error => this.logger.error({ err: error }, 'Webhook worker error')), 2000);
  }

  async tick() {
    if (this.busy) return;
    const item = claimWebhook();
    if (!item) return;
    this.busy = true;
    const body = JSON.stringify({ event: item.event_type, data: item.payload, occurredAt: new Date().toISOString() });
    try {
      const response = await fetch(config.WEBHOOK_URL, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'user-agent': 'NituWhatsAppGateway/2.2',
          'x-api-key': config.API_KEY,
          'x-gateway-signature': signPayload(body)
        },
        body,
        signal: AbortSignal.timeout(12_000)
      });
      const responseText = await response.text();
      if (!response.ok) throw new Error(`Webhook HTTP ${response.status}: ${responseText.slice(0, 300)}`);
      markWebhookSent(item.id);
    } catch (error) {
      markWebhookFailure(item.id, error);
      this.logger.warn({ err: error, event: item.event_type }, 'Webhook delivery failed');
    } finally {
      this.busy = false;
    }
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }
}
