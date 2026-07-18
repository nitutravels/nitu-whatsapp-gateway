'use strict';

const { MessageMedia } = require('whatsapp-web.js');
const config = require('./config');
const db = require('./db');
const { emitWebhook } = require('./webhook');
const { validateMediaUrl } = require('./security');

const CONNECTED_STATE = 'CONNECTED';
const HARD_DOWN_STATES = new Set([
  'CONFLICT', 'DEPRECATED_VERSION', 'PROXYBLOCK', 'SMB_TOS_BLOCK',
  'TOS_BLOCK', 'UNLAUNCHED', 'UNPAIRED', 'UNPAIRED_IDLE'
]);

function withTimeout(promise, timeoutMs, message) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(message)), timeoutMs);
    Promise.resolve(promise).then(
      value => { clearTimeout(timer); resolve(value); },
      error => { clearTimeout(timer); reject(error); }
    );
  });
}

function accountFromClient(client) {
  const info = client?.info;
  if (!info?.wid) return null;
  return {
    wid: info.wid?._serialized || null,
    pushname: info.pushname || null,
    platform: info.platform || null
  };
}

function installOperationalReliability(WhatsAppGateway) {
  if (!WhatsAppGateway || WhatsAppGateway.prototype.__nituOperationalReliabilityInstalled) return;
  const prototype = WhatsAppGateway.prototype;
  Object.defineProperty(prototype, '__nituOperationalReliabilityInstalled', { value: true });

  const originalBindEvents = prototype.bindEvents;
  prototype.bindEvents = function bindEventsWithOperationalState() {
    originalBindEvents.call(this);
    const client = this.client;
    if (!client) return;

    client.on('ready', () => {
      this.transportReady = true;
      this.providerState = CONNECTED_STATE;
      this.providerStateCheckedAt = Date.now();
      this.lastProviderConnectedAt = Date.now();
      this.providerStateMisses = 0;
      this.account = accountFromClient(client) || this.account;
    });

    // whatsapp-web.js can emit loading_screen after ready. Do not let that
    // cosmetic event disable an already-connected transport and freeze queues.
    client.on('loading_screen', (percent, message) => {
      this.lastLoadingPercent = Number(percent);
      this.lastLoadingMessage = String(message || '');
      if (this.transportReady) {
        this.status = 'ready';
        this.lastError = null;
      }
    });

    client.on('authenticated', () => {
      this.providerStateMisses = 0;
    });

    client.on('disconnected', () => {
      this.transportReady = false;
      this.providerState = 'DISCONNECTED';
      this.providerStateCheckedAt = Date.now();
    });

    client.on('auth_failure', () => {
      this.transportReady = false;
      this.providerState = 'AUTH_FAILURE';
      this.providerStateCheckedAt = Date.now();
    });
  };

  prototype.reconcileProviderState = async function reconcileProviderState(force = false) {
    if (!this.client || this.stateProbeBusy) return this.transportReady === true;
    const now = Date.now();
    if (!force && this.providerStateCheckedAt && now - this.providerStateCheckedAt < 4000) {
      return this.transportReady === true;
    }

    this.stateProbeBusy = true;
    try {
      let state = null;
      if (typeof this.client.getState === 'function') {
        state = await withTimeout(this.client.getState(), 6000, 'WhatsApp state probe timed out');
      }
      state = state ? String(state) : null;
      this.providerState = state;
      this.providerStateCheckedAt = Date.now();

      const account = accountFromClient(this.client);
      if (account) this.account = account;

      if (state === CONNECTED_STATE || (account && this.status === 'ready')) {
        const wasReady = this.transportReady === true;
        this.transportReady = true;
        this.providerStateMisses = 0;
        this.lastProviderConnectedAt = Date.now();
        this.status = 'ready';
        this.lastError = null;
        if (!wasReady) this.logger?.info?.({ state, account: this.account }, 'WhatsApp transport reconciled as ready');
        return true;
      }

      if (state && HARD_DOWN_STATES.has(state)) {
        this.providerStateMisses = (this.providerStateMisses || 0) + 1;
        if (this.providerStateMisses >= 2) {
          this.transportReady = false;
          if (this.status === 'ready') this.status = 'disconnected';
        }
      }
      return this.transportReady === true;
    } catch (error) {
      this.providerStateProbeError = String(error?.message || error);
      this.providerStateCheckedAt = Date.now();
      // A failed probe is not proof of disconnection. Preserve a previously
      // proven ready state and let a bounded send determine transport health.
      return this.transportReady === true;
    } finally {
      this.stateProbeBusy = false;
    }
  };

  prototype.ensureStateReconciler = function ensureStateReconciler() {
    if (this.stateReconcilerTimer) return;
    this.stateReconcilerTimer = setInterval(() => {
      this.reconcileProviderState().catch(error => {
        this.logger?.warn?.({ err: error }, 'WhatsApp state reconciliation failed');
      });
    }, 5000);
  };

  const originalStart = prototype.start;
  prototype.start = async function startWithOperationalReliability() {
    this.transportReady = false;
    this.queueBusy = false;
    const result = await originalStart.call(this);
    this.ensureStateReconciler();
    return result;
  };

  const originalStartClientOnly = prototype.startClientOnly;
  prototype.startClientOnly = async function startClientOnlyWithOperationalReliability() {
    this.transportReady = false;
    const result = await originalStartClientOnly.call(this);
    this.ensureStateReconciler();
    return result;
  };

  const originalHandleFatal = prototype.handleFatal;
  prototype.handleFatal = function handleFatalWithOperationalReliability(error) {
    this.transportReady = false;
    this.providerState = 'ERROR';
    this.providerStateCheckedAt = Date.now();
    return originalHandleFatal.call(this, error);
  };

  const originalGetStatus = prototype.getStatus;
  prototype.getStatus = function getStatusWithOperationalReliability() {
    const status = originalGetStatus.call(this);
    const operationalReady = this.transportReady === true;
    return {
      ...status,
      ready: operationalReady,
      operationalReady,
      providerState: this.providerState || null,
      providerStateCheckedAt: this.providerStateCheckedAt ? new Date(this.providerStateCheckedAt).toISOString() : null,
      lastProviderConnectedAt: this.lastProviderConnectedAt ? new Date(this.lastProviderConnectedAt).toISOString() : null,
      providerStateProbeError: this.providerStateProbeError || null,
      queueWorkerBusy: Boolean(this.queueBusy),
      lastLoadingPercent: Number.isFinite(this.lastLoadingPercent) ? this.lastLoadingPercent : null,
      lastLoadingMessage: this.lastLoadingMessage || null
    };
  };

  prototype.processQueue = async function processQueueReliably() {
    if (this.queueBusy) return;
    if (Date.now() - this.lastRecoveryAt > 60000) {
      db.resetStuckMessages();
      this.lastRecoveryAt = Date.now();
    }

    const operational = await this.reconcileProviderState();
    if (!operational || !this.client) return;
    if (Date.now() - this.lastSendAt < config.SEND_INTERVAL_MS) return;

    this.queueBusy = true;
    const message = db.claimNextMessage();
    if (!message) {
      this.queueBusy = false;
      return;
    }

    try {
      let sent;
      if (message.type === 'text') {
        sent = await withTimeout(
          this.client.sendMessage(message.to, message.payload.text, { sendSeen: false }),
          45000,
          'WhatsApp send timed out after 45 seconds'
        );
      } else {
        const safeUrl = await validateMediaUrl(message.payload.mediaUrl);
        const media = await MessageMedia.fromUrl(safeUrl, {
          unsafeMime: true,
          filename: message.payload.filename || undefined,
          client: { timeout: 30000 }
        });
        sent = await withTimeout(
          this.client.sendMessage(message.to, media, {
            caption: message.payload.caption || '',
            sendMediaAsDocument: Boolean(message.payload.asDocument),
            sendSeen: false
          }),
          60000,
          'WhatsApp media send timed out after 60 seconds'
        );
      }

      this.lastSendAt = Date.now();
      this.transportReady = true;
      this.providerState = CONNECTED_STATE;
      this.providerStateCheckedAt = Date.now();
      this.lastProviderConnectedAt = Date.now();
      this.status = 'ready';
      const providerId = sent?.id?._serialized || null;
      const record = db.markSent(message.id, providerId);
      db.addEvent(message.id, 'message.sent', record);
      await emitWebhook('message.sent', record, this.logger);
    } catch (error) {
      this.lastSendAt = Date.now();
      const messageText = String(error?.stack || error);
      const connectionFailure = /not connected|disconnected|session closed|target closed|protocol error|execution context|timed out/i.test(messageText);
      if (connectionFailure) {
        this.transportReady = false;
        this.providerState = 'DEGRADED';
        this.providerStateCheckedAt = Date.now();
        this.status = 'degraded';
        this.lastError = messageText;
        this.scheduleRestart();
      }
      const record = db.markFailure(message.id, error, config.MAX_ATTEMPTS);
      const event = record.status === 'failed' ? 'message.failed' : 'message.retry_scheduled';
      db.addEvent(message.id, event, record);
      await emitWebhook(event, record, this.logger);
      this.logger.warn({ err: error, messageId: message.id, status: record.status }, 'Message send failed');
    } finally {
      this.queueBusy = false;
    }
  };

  const originalClose = prototype.close;
  prototype.close = async function closeWithOperationalReliability() {
    if (this.stateReconcilerTimer) clearInterval(this.stateReconcilerTimer);
    this.stateReconcilerTimer = null;
    return originalClose.call(this);
  };
}

module.exports = { installOperationalReliability, withTimeout, accountFromClient };
