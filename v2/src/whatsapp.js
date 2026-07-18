import NodeCache from '@cacheable/node-cache';
import { Boom } from '@hapi/boom';
import makeWASocket, {
  Browsers,
  BufferJSON,
  DisconnectReason,
  fetchLatestBaileysVersion,
  generateMessageIDV2,
  makeCacheableSignalKeyStore
} from 'baileys';
import QRCode from 'qrcode';
import config from './config.js';
import { createSqliteAuthState } from './auth-store.js';
import {
  addEvent,
  addInbound,
  enqueueWebhook,
  ensureProviderMessageId,
  findProviderMessage,
  markAck,
  markSubmitted,
  setSetting,
  stats
} from './db.js';
import { validateMediaUrl } from './security.js';

const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const withTimeout = (promise, timeoutMs, message) => new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error(message)), timeoutMs);
  Promise.resolve(promise).then(
    value => { clearTimeout(timer); resolve(value); },
    error => { clearTimeout(timer); reject(error); }
  );
});

function disconnectCode(error) {
  if (!error) return null;
  if (error instanceof Boom) return error.output?.statusCode || null;
  return error?.output?.statusCode || error?.statusCode || error?.data?.statusCode || null;
}

function messageStatusName(status) {
  const numeric = Number(status);
  if (numeric >= 4) return 'read';
  if (numeric === 3) return 'delivered';
  if (numeric === 2) return 'sent';
  return null;
}

function messageBody(message) {
  return message?.conversation || message?.extendedTextMessage?.text ||
    message?.imageMessage?.caption || message?.videoMessage?.caption || '';
}

export class WhatsAppTransport {
  constructor(logger) {
    this.logger = logger;
    this.socket = null;
    this.auth = null;
    this.phase = 'starting';
    this.connected = false;
    this.account = null;
    this.qrDataUrl = null;
    this.pairingCode = null;
    this.lastError = null;
    this.lastDisconnectCode = null;
    this.lastOpenAt = null;
    this.lastCloseAt = null;
    this.lastHeartbeatAt = null;
    this.lastHeartbeatError = null;
    this.reconnectAt = null;
    this.reconnectAttempts = 0;
    this.generation = 0;
    this.connectPromise = null;
    this.reconnectTimer = null;
    this.heartbeatTimer = null;
    this.msgRetryCounterCache = new NodeCache({ stdTTL: 15 * 60, useClones: false });
  }

  isReady() {
    return this.connected === true && this.phase === 'open' && Boolean(this.auth?.state?.creds?.registered) && Boolean(this.socket);
  }

  async start() {
    await this.connect('startup');
    if (!this.heartbeatTimer) {
      this.heartbeatTimer = setInterval(() => this.heartbeat().catch(error => {
        this.logger.warn({ err: error }, 'WhatsApp heartbeat failed');
      }), config.HEARTBEAT_MS);
    }
  }

  async connect(reason = 'manual') {
    if (this.connectPromise) return this.connectPromise;
    this.connectPromise = this.openSocket(reason).finally(() => { this.connectPromise = null; });
    return this.connectPromise;
  }

  async openSocket(reason) {
    this.cancelReconnect();
    const generation = ++this.generation;
    await this.closeSocket(`replacing socket: ${reason}`);
    this.phase = 'connecting';
    this.connected = false;
    this.qrDataUrl = null;
    this.pairingCode = null;
    this.lastError = null;
    this.auth = createSqliteAuthState();

    let version;
    try {
      const latest = await withTimeout(fetchLatestBaileysVersion(), 10_000, 'Version lookup timed out');
      version = latest.version;
      this.logger.info({ version: version.join('.'), isLatest: latest.isLatest }, 'Resolved WhatsApp Web protocol version');
    } catch (error) {
      this.logger.warn({ err: error }, 'Using Baileys bundled protocol version');
    }

    const socket = makeWASocket({
      ...(version ? { version } : {}),
      auth: {
        creds: this.auth.state.creds,
        keys: makeCacheableSignalKeyStore(this.auth.state.keys, this.logger.child({ component: 'signal-store' }))
      },
      browser: Browsers.ubuntu('Nitu Travels Gateway'),
      logger: this.logger.child({ component: 'baileys' }),
      printQRInTerminal: false,
      syncFullHistory: false,
      markOnlineOnConnect: false,
      generateHighQualityLinkPreview: false,
      msgRetryCounterCache: this.msgRetryCounterCache,
      getMessage: async key => {
        const stored = findProviderMessage(key?.id);
        return stored?.message || undefined;
      },
      shouldIgnoreJid: jid => jid === 'status@broadcast'
    });
    this.socket = socket;
    this.bindEvents(socket, generation);
    this.logger.info({ generation, reason }, 'WhatsApp WebSocket created');
  }

  bindEvents(socket, generation) {
    socket.ev.process(async events => {
      if (generation !== this.generation || socket !== this.socket) return;

      if (events['connection.update']) {
        await this.handleConnectionUpdate(events['connection.update'], generation);
      }
      if (events['creds.update']) {
        await this.auth.saveCreds();
      }
      if (events['messages.update']) {
        for (const { key, update } of events['messages.update']) {
          const providerId = key?.id;
          const status = messageStatusName(update?.status);
          if (!providerId || !status) continue;
          const record = markAck(providerId, status);
          if (record) {
            addEvent(record.id, `message.${status}`, record);
            enqueueWebhook(`message.${status}`, record);
          }
        }
      }
      if (events['message-receipt.update']) {
        for (const item of events['message-receipt.update']) {
          const providerId = item?.key?.id;
          if (!providerId) continue;
          const status = item?.receipt?.readTimestamp ? 'read' : item?.receipt?.receiptTimestamp ? 'delivered' : null;
          if (!status) continue;
          const record = markAck(providerId, status);
          if (record) {
            addEvent(record.id, `message.${status}`, record);
            enqueueWebhook(`message.${status}`, record);
          }
        }
      }
      if (events['messages.upsert']) {
        for (const item of events['messages.upsert'].messages || []) {
          const id = item?.key?.id;
          if (!id || !item.message) continue;
          if (item.key.fromMe) {
            const record = markAck(id, 'sent');
            if (record) enqueueWebhook('message.sent', record);
            continue;
          }
          const sender = item.key.remoteJid || 'unknown';
          const record = {
            id,
            sender,
            body: messageBody(item.message),
            hasMedia: Boolean(item.message.imageMessage || item.message.videoMessage || item.message.audioMessage || item.message.documentMessage),
            timestamp: Number(item.messageTimestamp || Math.floor(Date.now() / 1000)) * 1000,
            payload: JSON.parse(JSON.stringify(item, BufferJSON.replacer))
          };
          addInbound(record);
          enqueueWebhook('message.received', record);
        }
      }
    });
  }

  async handleConnectionUpdate(update, generation) {
    if (generation !== this.generation) return;
    const { connection, lastDisconnect, qr } = update;

    if (qr) {
      this.phase = 'pairing';
      this.connected = false;
      this.qrDataUrl = await QRCode.toDataURL(qr, { margin: 1, width: 360 });
      this.pairingCode = null;
      this.lastError = null;
      enqueueWebhook('session.pairing_required', this.status());
    }

    if (connection === 'connecting') {
      this.phase = this.qrDataUrl ? 'pairing' : 'connecting';
    }

    if (connection === 'open') {
      this.phase = 'open';
      this.connected = true;
      this.account = this.socket?.user ? {
        wid: this.socket.user.id || null,
        name: this.socket.user.name || null,
        lid: this.socket.user.lid || null
      } : null;
      this.qrDataUrl = null;
      this.pairingCode = null;
      this.lastError = null;
      this.lastDisconnectCode = null;
      this.lastOpenAt = new Date().toISOString();
      this.reconnectAttempts = 0;
      this.reconnectAt = null;
      setSetting('last_account', JSON.stringify(this.account || {}));
      enqueueWebhook('session.ready', this.status());
      this.logger.info({ account: this.account }, 'WhatsApp WebSocket is open');
      return;
    }

    if (connection === 'close') {
      const code = disconnectCode(lastDisconnect?.error);
      this.connected = false;
      this.lastDisconnectCode = code;
      this.lastCloseAt = new Date().toISOString();
      this.lastError = String(lastDisconnect?.error?.message || lastDisconnect?.error || `Disconnected (${code || 'unknown'})`);

      if (code === DisconnectReason.loggedOut) {
        this.phase = 'logged_out';
        this.qrDataUrl = null;
        this.pairingCode = null;
        enqueueWebhook('session.logged_out', this.status());
        this.logger.error({ code }, 'WhatsApp session logged out; operator pairing required');
        return;
      }

      this.phase = 'reconnecting';
      enqueueWebhook('session.disconnected', this.status());
      const immediate = code === DisconnectReason.restartRequired;
      this.scheduleReconnect(immediate ? 1000 : null);
      this.logger.warn({ code, error: this.lastError }, 'WhatsApp socket closed; reconnect scheduled');
    }
  }

  scheduleReconnect(delayOverride = null) {
    if (this.reconnectTimer || this.phase === 'logged_out') return;
    this.reconnectAttempts += 1;
    const exponential = Math.min(120_000, config.RECONNECT_BASE_MS * Math.pow(2, Math.min(this.reconnectAttempts - 1, 6)));
    const jitter = Math.floor(Math.random() * Math.min(5000, exponential / 3));
    const wait = delayOverride ?? (exponential + jitter);
    this.reconnectAt = new Date(Date.now() + wait).toISOString();
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect('automatic reconnect').catch(error => {
        this.lastError = String(error?.stack || error);
        this.phase = 'error';
        this.logger.error({ err: error }, 'Automatic WhatsApp reconnect failed');
        this.scheduleReconnect();
      });
    }, wait);
  }

  cancelReconnect() {
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
    this.reconnectAt = null;
  }

  async heartbeat() {
    if (!this.isReady() || !this.socket) return;
    try {
      await withTimeout(this.socket.sendPresenceUpdate('unavailable'), 8000, 'Heartbeat timed out');
      this.lastHeartbeatAt = new Date().toISOString();
      this.lastHeartbeatError = null;
    } catch (error) {
      this.lastHeartbeatError = String(error?.message || error);
      this.connected = false;
      this.phase = 'reconnecting';
      await this.connect('heartbeat failure');
    }
  }

  async requestPairingCode(phoneNumber) {
    const digits = String(phoneNumber || '').replace(/\D/g, '');
    if (!/^\d{8,15}$/.test(digits)) throw new Error('Enter the full international number without + or spaces');
    if (this.isReady()) throw new Error('A WhatsApp account is already linked');
    if (!this.socket || this.phase === 'logged_out' || this.phase === 'error') await this.connect('pairing code requested');
    await delay(1200);
    if (!this.socket) throw new Error('WhatsApp socket is unavailable');
    const code = await withTimeout(this.socket.requestPairingCode(digits), 20_000, 'Pairing code request timed out; scan the QR code instead');
    this.phase = 'pairing';
    this.pairingCode = String(code || '').replace(/\s/g, '');
    this.qrDataUrl = null;
    return this.pairingCode;
  }

  async resetSession() {
    this.cancelReconnect();
    await this.closeSocket('administrator session reset');
    await this.auth?.clear?.();
    this.auth = null;
    this.account = null;
    this.connected = false;
    this.phase = 'connecting';
    this.qrDataUrl = null;
    this.pairingCode = null;
    this.lastError = null;
    await this.connect('fresh session reset');
  }

  async forceReconnect(reason = 'administrator reconnect') {
    if (this.phase === 'logged_out') throw new Error('Session is logged out; reset and pair again');
    await this.connect(reason);
  }

  async send(outboxMessage) {
    if (!this.isReady() || !this.socket) throw new Error('WhatsApp transport is not open');
    const jid = `${outboxMessage.to}@s.whatsapp.net`;
    const providerId = ensureProviderMessageId(outboxMessage.id, outboxMessage.providerMessageId || generateMessageIDV2(this.socket.user?.id));
    let content;

    if (outboxMessage.type === 'text') {
      content = { text: outboxMessage.payload.text };
    } else {
      const safeUrl = await validateMediaUrl(outboxMessage.payload.mediaUrl);
      const mime = String(outboxMessage.payload.mimetype || '').toLowerCase();
      const caption = outboxMessage.payload.caption || '';
      const filename = outboxMessage.payload.filename || 'attachment';
      if (!outboxMessage.payload.asDocument && mime.startsWith('image/')) {
        content = { image: { url: safeUrl }, caption };
      } else if (!outboxMessage.payload.asDocument && mime.startsWith('video/')) {
        content = { video: { url: safeUrl }, caption, mimetype: mime || undefined };
      } else if (!outboxMessage.payload.asDocument && mime.startsWith('audio/')) {
        content = { audio: { url: safeUrl }, mimetype: mime || 'audio/mpeg', ptt: false };
      } else {
        content = { document: { url: safeUrl }, mimetype: mime || 'application/octet-stream', fileName: filename, caption };
      }
    }

    const timeout = outboxMessage.type === 'text' ? config.MESSAGE_TIMEOUT_MS : config.MEDIA_TIMEOUT_MS;
    const sent = await withTimeout(
      this.socket.sendMessage(jid, content, { messageId: providerId }),
      timeout,
      `WhatsApp send timed out after ${Math.round(timeout / 1000)} seconds`
    );
    const serialized = JSON.parse(JSON.stringify(sent, BufferJSON.replacer));
    const record = markSubmitted(outboxMessage.id, sent?.key?.id || providerId, serialized);
    addEvent(record.id, 'message.sent', record);
    enqueueWebhook('message.sent', record);
    return record;
  }

  status() {
    return {
      engine: 'baileys-websocket',
      engineVersion: '7.0.0-rc13',
      phase: this.phase,
      status: this.isReady() ? 'ready' : this.phase,
      ready: this.isReady(),
      connected: this.connected,
      registered: Boolean(this.auth?.state?.creds?.registered),
      account: this.isReady() ? this.account : null,
      qrDataUrl: this.qrDataUrl,
      pairingCode: this.pairingCode,
      lastError: this.lastError,
      lastDisconnectCode: this.lastDisconnectCode,
      lastOpenAt: this.lastOpenAt,
      lastCloseAt: this.lastCloseAt,
      lastHeartbeatAt: this.lastHeartbeatAt,
      lastHeartbeatError: this.lastHeartbeatError,
      reconnectAttempts: this.reconnectAttempts,
      reconnectAt: this.reconnectAt,
      queue: stats()
    };
  }

  async closeSocket(reason) {
    const socket = this.socket;
    this.socket = null;
    if (!socket) return;
    try { socket.end?.(new Error(reason)); } catch (error) { this.logger.debug({ err: error }, 'Socket end returned an error'); }
    await delay(250);
  }

  async close() {
    this.cancelReconnect();
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);
    this.heartbeatTimer = null;
    this.generation += 1;
    await this.closeSocket('gateway shutdown');
  }
}

export { withTimeout, disconnectCode, messageStatusName };
