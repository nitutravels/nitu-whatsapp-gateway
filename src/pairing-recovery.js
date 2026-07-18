'use strict';

const fs = require('node:fs');
const path = require('node:path');

const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

function withTimeout(promise, timeoutMs, message) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(message)), timeoutMs);
    Promise.resolve(promise).then(
      value => { clearTimeout(timer); resolve(value); },
      error => { clearTimeout(timer); reject(error); }
    );
  });
}

function pageIsUsable(client) {
  try {
    return Boolean(client?.pupPage && !client.pupPage.isClosed());
  } catch {
    return false;
  }
}

async function waitForAuthenticationScreen(gateway, timeoutMs = 70000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (gateway.status === 'ready') throw new Error('A WhatsApp account is already linked');
    if (pageIsUsable(gateway.client) && (gateway.qrDataUrl || gateway.status === 'awaiting_pairing')) return;
    if (gateway.status === 'error') {
      throw new Error(gateway.lastError || 'WhatsApp browser could not start');
    }
    await delay(500);
  }
  throw new Error('WhatsApp is still starting. The QR code remains available; retry the pairing code after 30 seconds.');
}

function archiveInvalidSession(gateway, reason) {
  const sessionRoot = path.join(gateway?.constructor?.configAuthPath || '', 'session-primary');
  if (!sessionRoot || sessionRoot === 'session-primary' || !fs.existsSync(sessionRoot)) return null;

  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const archived = `${sessionRoot}.invalid-${stamp}`;
  try {
    fs.renameSync(sessionRoot, archived);
    gateway.logger?.warn?.({ reason, archived }, 'Archived invalid WhatsApp session before relinking');

    const parent = path.dirname(sessionRoot);
    const prefix = `${path.basename(sessionRoot)}.invalid-`;
    const oldArchives = fs.readdirSync(parent, { withFileTypes: true })
      .filter(entry => entry.isDirectory() && entry.name.startsWith(prefix))
      .map(entry => ({ name: entry.name, fullPath: path.join(parent, entry.name), mtime: fs.statSync(path.join(parent, entry.name)).mtimeMs }))
      .sort((a, b) => b.mtime - a.mtime)
      .slice(2);
    for (const item of oldArchives) fs.rmSync(item.fullPath, { recursive: true, force: true });
    return archived;
  } catch (error) {
    gateway.logger?.warn?.({ err: error, reason, sessionRoot }, 'Could not archive invalid WhatsApp session');
    return null;
  }
}

async function restartForRelink(gateway, reason) {
  gateway.suppressRestart = true;
  if (gateway.restartTimer) {
    clearTimeout(gateway.restartTimer);
    gateway.restartTimer = null;
  }
  try {
    if (gateway.client) {
      try { await gateway.client.destroy(); } catch (error) { gateway.logger?.warn?.({ err: error }, 'WhatsApp browser destroy failed before relinking'); }
    }
    gateway.client = null;
    await delay(1500);
    archiveInvalidSession(gateway, reason);
    gateway.status = 'starting';
    gateway.qrDataUrl = null;
    gateway.pairingCode = null;
    await gateway.startClientOnly();
  } finally {
    gateway.suppressRestart = false;
  }
}

function installPairingRecovery(WhatsAppGateway, config) {
  if (!WhatsAppGateway || WhatsAppGateway.prototype.__nituPairingRecoveryInstalled) return;
  const prototype = WhatsAppGateway.prototype;
  Object.defineProperty(prototype, '__nituPairingRecoveryInstalled', { value: true });
  WhatsAppGateway.configAuthPath = config.AUTH_PATH;

  const originalGetStatus = prototype.getStatus;
  prototype.getStatus = function getStatusWithPairingProgress() {
    const status = originalGetStatus.call(this);
    return {
      ...status,
      pairingInProgress: Boolean(this.pairingRequestPromise),
      pairingRequestedAt: this.pairingRequestedAt || null
    };
  };

  prototype.requestPairingCode = async function requestPairingCodeWithoutBrowserRestart(phoneNumber) {
    if (!this.client) throw new Error('WhatsApp browser is not initialized');
    if (this.status === 'ready') throw new Error('A WhatsApp account is already linked');

    const digits = String(phoneNumber || '').replace(/\D/g, '');
    if (!/^\d{8,15}$/.test(digits)) throw new Error('Enter the full international number without + or spaces');
    if (this.pairingRequestPromise) return this.pairingRequestPromise;

    const previousStatus = this.status;
    const previousError = String(this.lastError || '');
    const deadline = Date.now() + 80000;
    this.pairingRequestedAt = new Date().toISOString();
    this.lastError = null;
    this.pairingCode = null;

    this.pairingRequestPromise = (async () => {
      const loggedOut = /logout/i.test(previousError);
      if (previousStatus === 'auth_failure' || (previousStatus === 'disconnected' && loggedOut)) {
        await restartForRelink(this, previousStatus);
      } else if (!pageIsUsable(this.client)) {
        this.qrDataUrl = null;
        await this.recreateClient();
      }

      const startupBudget = Math.max(1000, Math.min(50000, deadline - Date.now()));
      await waitForAuthenticationScreen(this, startupBudget);
      if (!pageIsUsable(this.client)) throw new Error('WhatsApp browser closed while generating the pairing code');
      if (typeof this.client.requestPairingCode !== 'function') {
        throw new Error('The installed WhatsApp library does not support phone-number pairing');
      }

      const codeBudget = Math.max(1000, deadline - Date.now());
      const code = await withTimeout(
        this.client.requestPairingCode(digits, true, 180000),
        codeBudget,
        'Pairing code generation timed out'
      );
      const normalized = String(code || '').replace(/\s/g, '');
      if (!normalized) throw new Error('WhatsApp returned an empty pairing code');

      this.status = 'awaiting_pairing';
      this.pairingCode = normalized;
      this.qrDataUrl = null;
      this.lastError = null;
      return normalized;
    })();

    try {
      return await this.pairingRequestPromise;
    } catch (error) {
      const message = String(error?.message || error);
      this.lastError = message;
      if (this.qrDataUrl) this.status = 'awaiting_pairing';
      throw new Error(`${message}. You can still scan the QR code shown on this page from WhatsApp > Linked devices.`);
    } finally {
      this.pairingRequestPromise = null;
    }
  };
}

module.exports = { installPairingRecovery, pageIsUsable, waitForAuthenticationScreen, restartForRelink, withTimeout };
