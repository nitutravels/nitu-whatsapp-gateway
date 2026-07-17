const fs = require('node:fs');
const { Client, LocalAuth, MessageMedia, MessageAck } = require('whatsapp-web.js');
const QRCode = require('qrcode');
const config = require('./config');
const db = require('./db');
const { emitWebhook } = require('./webhook');
const { validateMediaUrl } = require('./security');

class WhatsAppGateway {
  constructor(logger) {
    this.logger = logger;
    this.client = null;
    this.status = 'starting';
    this.qrDataUrl = null;
    this.pairingCode = null;
    this.account = null;
    this.lastError = null;
    this.lastSendAt = 0;
    this.workerTimer = null;
    this.restarting = false;
    this.suppressRestart = false;
    this.restartTimer = null;
    this.lastRecoveryAt = 0;
  }

  buildClient(pairWithPhoneNumber = null) {
    return new Client({
      authStrategy: new LocalAuth({ clientId: 'primary', dataPath: config.AUTH_PATH }),
      authTimeoutMs: 120000,
      qrMaxRetries: 0,
      takeoverOnConflict: false,
      pairWithPhoneNumber: pairWithPhoneNumber || undefined,
      puppeteer: {
        headless: true,
        executablePath: config.CHROME_PATH,
        args: [
          '--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage',
          '--disable-gpu', '--disable-software-rasterizer', '--no-first-run',
          '--no-default-browser-check', '--disable-extensions', '--disable-background-networking',
          '--disable-sync', '--metrics-recording-only', '--mute-audio'
        ]
      }
    });
  }

  async start() {
    fs.mkdirSync(config.AUTH_PATH, { recursive: true });
    db.resetStuckMessages();
    this.client = this.buildClient();
    this.bindEvents();
    this.client.initialize().catch(error => this.handleFatal(error));
    this.workerTimer = setInterval(() => this.processQueue().catch(err => this.logger.error({ err }, 'Queue worker error')), 2000);
  }

  bindEvents() {
    this.client.on('loading_screen', (percent, message) => {
      this.status = 'loading';
      this.logger.info({ percent, message }, 'WhatsApp loading');
    });
    this.client.on('qr', async qr => {
      this.status = 'awaiting_pairing';
      this.pairingCode = null;
      this.qrDataUrl = await QRCode.toDataURL(qr, { margin: 1, width: 320 });
    });
    this.client.on('code', code => {
      this.status = 'awaiting_pairing';
      this.pairingCode = code;
      this.qrDataUrl = null;
    });
    this.client.on('authenticated', () => {
      this.status = 'authenticated';
      this.lastError = null;
      this.logger.info('WhatsApp authenticated');
    });
    this.client.on('ready', async () => {
      this.status = 'ready';
      this.qrDataUrl = null;
      this.pairingCode = null;
      const info = this.client.info;
      this.account = info ? { wid: info.wid?._serialized || null, pushname: info.pushname || null, platform: info.platform || null } : null;
      this.logger.info({ account: this.account }, 'WhatsApp client ready');
      await emitWebhook('session.ready', this.getStatus(), this.logger);
    });
    this.client.on('auth_failure', message => {
      this.status = 'auth_failure';
      this.lastError = String(message);
      this.logger.error({ message }, 'WhatsApp authentication failure');
      emitWebhook('session.auth_failure', this.getStatus(), this.logger);
    });
    this.client.on('disconnected', reason => {
      this.status = 'disconnected';
      this.lastError = String(reason);
      this.logger.warn({ reason }, 'WhatsApp disconnected');
      emitWebhook('session.disconnected', this.getStatus(), this.logger);
      if (!this.suppressRestart) this.scheduleRestart();
    });
    this.client.on('message_ack', async (message, ack) => {
      const providerId = message.id?._serialized;
      if (!providerId) return;
      const map = {
        [MessageAck.ACK_SERVER]: 'sent',
        [MessageAck.ACK_DEVICE]: 'delivered',
        [MessageAck.ACK_READ]: 'read',
        [MessageAck.ACK_PLAYED]: 'read'
      };
      const status = map[ack];
      if (!status) return;
      const id = db.markAck(providerId, status);
      if (id) {
        const record = db.getMessage(id);
        db.addEvent(id, `message.${status}`, record);
        await emitWebhook(`message.${status}`, record, this.logger);
      }
    });
    this.client.on('message', async message => {
      if (message.fromMe || message.from === 'status@broadcast') return;
      const id = message.id?._serialized || `${message.from}-${message.timestamp}`;
      const record = {
        id,
        sender: message.from,
        body: message.body || '',
        hasMedia: Boolean(message.hasMedia),
        timestamp: Number(message.timestamp || Math.floor(Date.now()/1000)) * 1000,
        payload: { type: message.type, from: message.from, to: message.to, author: message.author || null }
      };
      db.addInbound(record);
      await emitWebhook('message.received', record, this.logger);
    });
  }

  async requestPairingCode(phoneNumber) {
    if (!this.client) throw new Error('Client not initialized');
    if (this.status === 'ready') throw new Error('A WhatsApp account is already linked');
    const digits = String(phoneNumber || '').replace(/\D/g, '');
    if (!/^\d{8,15}$/.test(digits)) throw new Error('Enter the full international number without + or spaces');

    this.suppressRestart = true;
    try { await this.client.destroy(); } catch {}
    this.client = this.buildClient({ phoneNumber: digits, showNotification: true, intervalMs: 180000 });
    this.status = 'loading';
    this.qrDataUrl = null;
    this.pairingCode = null;
    this.bindEvents();

    const codePromise = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Pairing code was not generated within 45 seconds')), 45000);
      this.client.once('code', code => {
        clearTimeout(timer);
        resolve(code);
      });
    });
    this.client.initialize().catch(error => this.handleFatal(error));
    try {
      return await codePromise;
    } finally {
      this.suppressRestart = false;
    }
  }

  async logout() {
    if (!this.client) return;
    try { await this.client.logout(); } catch (error) { this.logger.warn({ err: error }, 'Logout returned an error'); }
    try { await this.client.destroy(); } catch {}
    fs.rmSync(config.AUTH_PATH, { recursive: true, force: true });
    this.status = 'disconnected';
    this.account = null;
    this.qrDataUrl = null;
    this.pairingCode = null;
    setTimeout(() => this.recreateClient(), 2000);
  }

  async recreateClient() {
    if (this.restarting) return;
    if (this.restartTimer) {
      clearTimeout(this.restartTimer);
      this.restartTimer = null;
    }
    this.restarting = true;
    try {
      if (this.client) { try { await this.client.destroy(); } catch {} }
      this.client = null;
      this.restarting = false;
      await this.startClientOnly();
    } catch (error) {
      this.restarting = false;
      this.handleFatal(error);
    }
  }

  async startClientOnly() {
    this.client = this.buildClient();
    this.bindEvents();
    this.client.initialize().catch(error => this.handleFatal(error));
  }

  scheduleRestart() {
    if (this.restarting || this.restartTimer) return;
    this.restartTimer = setTimeout(() => this.recreateClient(), 15000);
  }

  handleFatal(error) {
    this.status = 'error';
    this.lastError = String(error?.stack || error);
    this.logger.error({ err: error }, 'WhatsApp client fatal error');
    this.scheduleRestart();
  }

  getStatus() {
    return {
      status: this.status,
      ready: this.status === 'ready',
      account: this.account,
      pairingCode: this.pairingCode,
      qrDataUrl: this.qrDataUrl,
      lastError: this.lastError,
      queue: db.stats()
    };
  }

  async processQueue() {
    if (Date.now() - this.lastRecoveryAt > 60000) {
      db.resetStuckMessages();
      this.lastRecoveryAt = Date.now();
    }
    if (this.status !== 'ready' || !this.client) return;
    if (Date.now() - this.lastSendAt < config.SEND_INTERVAL_MS) return;
    const message = db.claimNextMessage();
    if (!message) return;
    try {
      let sent;
      if (message.type === 'text') {
        sent = await this.client.sendMessage(message.to, message.payload.text, { sendSeen: false });
      } else {
        const safeUrl = await validateMediaUrl(message.payload.mediaUrl);
        const media = await MessageMedia.fromUrl(safeUrl, {
          unsafeMime: true,
          filename: message.payload.filename || undefined,
          client: { timeout: 30000 }
        });
        sent = await this.client.sendMessage(message.to, media, {
          caption: message.payload.caption || '',
          sendMediaAsDocument: Boolean(message.payload.asDocument),
          sendSeen: false
        });
      }
      this.lastSendAt = Date.now();
      const providerId = sent?.id?._serialized || null;
      const record = db.markSent(message.id, providerId);
      db.addEvent(message.id, 'message.sent', record);
      await emitWebhook('message.sent', record, this.logger);
    } catch (error) {
      this.lastSendAt = Date.now();
      const record = db.markFailure(message.id, error, config.MAX_ATTEMPTS);
      const event = record.status === 'failed' ? 'message.failed' : 'message.retry_scheduled';
      db.addEvent(message.id, event, record);
      await emitWebhook(event, record, this.logger);
      this.logger.warn({ err: error, messageId: message.id, status: record.status }, 'Message send failed');
    }
  }

  async close() {
    if (this.workerTimer) clearInterval(this.workerTimer);
    if (this.restartTimer) clearTimeout(this.restartTimer);
    if (this.client) { try { await this.client.destroy(); } catch {} }
  }
}

module.exports = { WhatsAppGateway };
