import config from './config.js';
import {
  addEvent,
  claimNextMessage,
  enqueueWebhook,
  markFailure,
  requeueExpiredLeases
} from './db.js';

function classify(error) {
  const text = String(error?.stack || error || 'Unknown send failure');
  const loggedOut = /logged.?out|401|unauthori[sz]ed/i.test(text);
  const permanent = /invalid mobile|not registered|bad request|forbidden|media host is not allowlisted|private or unsafe address/i.test(text);
  const uncertain = /timed out|timeout|connection closed|socket|stream errored|restart required|disconnected/i.test(text);
  return { text, retryable: !loggedOut && !permanent, uncertain };
}

export class QueueWorker {
  constructor(transport, logger) {
    this.transport = transport;
    this.logger = logger;
    this.timer = null;
    this.busy = false;
    this.lastSendAt = 0;
    this.lastLeaseRecoveryAt = 0;
    this.consecutiveFailures = 0;
    this.circuitOpenUntil = 0;
  }

  start() {
    if (this.timer) return;
    requeueExpiredLeases();
    this.timer = setInterval(() => this.tick().catch(error => this.logger.error({ err: error }, 'Queue worker tick failed')), 1000);
  }

  async tick() {
    if (this.busy) return;
    const now = Date.now();
    if (now - this.lastLeaseRecoveryAt > 30_000) {
      const recovered = requeueExpiredLeases();
      if (recovered) this.logger.warn({ recovered }, 'Recovered expired message leases');
      this.lastLeaseRecoveryAt = now;
    }
    if (now < this.circuitOpenUntil || !this.transport.isReady()) return;
    if (now - this.lastSendAt < config.SEND_INTERVAL_MS) return;

    const message = claimNextMessage();
    if (!message) return;
    this.busy = true;
    try {
      await this.transport.send(message);
      this.lastSendAt = Date.now();
      this.consecutiveFailures = 0;
    } catch (error) {
      this.lastSendAt = Date.now();
      this.consecutiveFailures += 1;
      const result = classify(error);
      const record = markFailure(message.id, result.text, { uncertain: result.uncertain, retryable: result.retryable });
      const event = record?.status === 'failed' ? 'message.failed' : 'message.retry_scheduled';
      if (record) {
        addEvent(record.id, event, record);
        enqueueWebhook(event, record);
      }
      this.logger.warn({ err: error, messageId: message.id, status: record?.status }, 'WhatsApp send failed');

      if (this.consecutiveFailures >= 3) {
        const pause = Math.min(5 * 60_000, 30_000 * this.consecutiveFailures);
        this.circuitOpenUntil = Date.now() + pause;
        this.logger.error({ pause, failures: this.consecutiveFailures }, 'Send circuit opened; reconnecting transport');
        this.transport.forceReconnect('send circuit breaker').catch(reconnectError => {
          this.logger.error({ err: reconnectError }, 'Circuit-breaker reconnect failed');
        });
      }
    } finally {
      this.busy = false;
    }
  }

  status() {
    return {
      busy: this.busy,
      lastSendAt: this.lastSendAt ? new Date(this.lastSendAt).toISOString() : null,
      consecutiveFailures: this.consecutiveFailures,
      circuitOpenUntil: this.circuitOpenUntil > Date.now() ? new Date(this.circuitOpenUntil).toISOString() : null
    };
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }
}
