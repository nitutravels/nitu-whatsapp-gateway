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
    if (gateway.status === 'ready') return 'ready';
    if (pageIsUsable(gateway.client) && gateway.qrDataUrl) return 'qr';
    if (gateway.status === 'error') throw new Error(gateway.lastError || 'WhatsApp browser could not start');
    await delay(500);
  }
  throw new Error('WhatsApp did not produce a QR code within the recovery window');
}

function sessionRootFor(gateway) {
  const authPath = gateway?.constructor?.configAuthPath || '';
  return authPath ? path.join(authPath, 'session-primary') : '';
}

function archiveInvalidSession(gateway, reason) {
  const sessionRoot = sessionRootFor(gateway);
  if (!sessionRoot || !fs.existsSync(sessionRoot)) return null;

  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const archived = `${sessionRoot}.backup-${stamp}`;
  try {
    fs.renameSync(sessionRoot, archived);
    gateway.logger?.warn?.({ reason, archived }, 'Archived WhatsApp session before fresh QR recovery');

    const parent = path.dirname(sessionRoot);
    const prefix = `${path.basename(sessionRoot)}.backup-`;
    const oldArchives = fs.readdirSync(parent, { withFileTypes: true })
      .filter(entry => entry.isDirectory() && entry.name.startsWith(prefix))
      .map(entry => ({ fullPath: path.join(parent, entry.name), mtime: fs.statSync(path.join(parent, entry.name)).mtimeMs }))
      .sort((a, b) => b.mtime - a.mtime)
      .slice(3);
    for (const item of oldArchives) fs.rmSync(item.fullPath, { recursive: true, force: true });
    return archived;
  } catch (error) {
    gateway.logger?.warn?.({ err: error, reason, sessionRoot }, 'Could not archive WhatsApp session');
    return null;
  }
}

async function terminateBrowser(gateway) {
  if (gateway.restartTimer) {
    clearTimeout(gateway.restartTimer);
    gateway.restartTimer = null;
  }

  const browserProcess = (() => {
    try { return gateway.client?.pupBrowser?.process?.() || null; } catch { return null; }
  })();

  if (gateway.client) {
    try {
      await withTimeout(gateway.client.destroy(), 12000, 'Timed out while closing the old WhatsApp browser');
    } catch (error) {
      gateway.logger?.warn?.({ err: error }, 'Graceful WhatsApp browser shutdown failed');
    }
  }

  if (browserProcess && !browserProcess.killed) {
    try { browserProcess.kill('SIGKILL'); } catch (error) { gateway.logger?.warn?.({ err: error }, 'Could not force-stop old Chromium process'); }
  }
  gateway.client = null;
  await delay(1500);
}

async function startFreshQrRecovery(gateway, reason = 'manual_qr_recovery') {
  if (gateway.qrRecoveryPromise) return gateway.qrRecoveryPromise;

  gateway.qrRecoveryStartedAt = new Date().toISOString();
  gateway.qrRecoveryError = null;
  gateway.lastError = null;
  gateway.status = 'recovering';
  gateway.account = null;
  gateway.qrDataUrl = null;
  gateway.pairingCode = null;
  gateway.suppressRestart = true;

  gateway.qrRecoveryPromise = (async () => {
    try {
      await terminateBrowser(gateway);
      archiveInvalidSession(gateway, reason);
      gateway.prepareProfileForLaunch();
      gateway.status = 'starting';
      await gateway.startClientOnly();
      const result = await waitForAuthenticationScreen(gateway, 90000);
      gateway.lastError = null;
      return result;
    } catch (error) {
      const message = String(error?.message || error);
      gateway.status = 'error';
      gateway.lastError = message;
      gateway.qrRecoveryError = message;
      gateway.logger?.error?.({ err: error }, 'Fresh QR recovery failed');
      throw error;
    } finally {
      gateway.suppressRestart = false;
      gateway.qrRecoveryPromise = null;
    }
  })();

  gateway.qrRecoveryPromise.catch(() => {});
  return gateway.qrRecoveryPromise;
}

function installPairingRecovery(WhatsAppGateway, config) {
  if (!WhatsAppGateway || WhatsAppGateway.prototype.__nituPairingRecoveryInstalled) return;
  const prototype = WhatsAppGateway.prototype;
  Object.defineProperty(prototype, '__nituPairingRecoveryInstalled', { value: true });
  WhatsAppGateway.configAuthPath = config.AUTH_PATH;

  const originalGetStatus = prototype.getStatus;
  prototype.getStatus = function getStatusWithRecoveryProgress() {
    const status = originalGetStatus.call(this);
    return {
      ...status,
      recoveryInProgress: Boolean(this.qrRecoveryPromise),
      recoveryStartedAt: this.qrRecoveryStartedAt || null,
      recoveryError: this.qrRecoveryError || null,
      pairingInProgress: Boolean(this.pairingRequestPromise),
      pairingRequestedAt: this.pairingRequestedAt || null
    };
  };

  prototype.startFreshQrRecovery = function startFreshQrRecoveryFromAdmin(reason) {
    return startFreshQrRecovery(this, reason);
  };

  prototype.startPairingCode = function startPairingCodeInBackground(phoneNumber) {
    if (this.pairingRequestPromise) return this.pairingRequestPromise;
    this.pairingRequestPromise = this.requestPairingCode(phoneNumber)
      .catch(error => {
        this.lastError = String(error?.message || error);
        throw error;
      })
      .finally(() => { this.pairingRequestPromise = null; });
    this.pairingRequestPromise.catch(() => {});
    return this.pairingRequestPromise;
  };

  prototype.requestPairingCode = async function requestPairingCodeAfterHealthyQr(phoneNumber) {
    if (this.status === 'ready') throw new Error('A WhatsApp account is already linked');
    const digits = String(phoneNumber || '').replace(/\D/g, '');
    if (!/^\d{8,15}$/.test(digits)) throw new Error('Enter the full international number without + or spaces');

    if (this.status === 'error' || !pageIsUsable(this.client) || !this.qrDataUrl) {
      await startFreshQrRecovery(this, 'pairing_code_requested_while_unhealthy');
    }
    if (this.status === 'ready') throw new Error('A WhatsApp account is already linked');
    if (!pageIsUsable(this.client) || typeof this.client.requestPairingCode !== 'function') {
      throw new Error('Phone-number pairing is unavailable; use the QR code');
    }

    this.pairingRequestedAt = new Date().toISOString();
    this.pairingCode = null;
    const code = await withTimeout(
      this.client.requestPairingCode(digits, true, 180000),
      30000,
      'Phone-number pairing did not respond; use the QR code'
    );
    const normalized = String(code || '').replace(/\s/g, '');
    if (!normalized) throw new Error('WhatsApp returned an empty pairing code; use the QR code');
    this.status = 'awaiting_pairing';
    this.pairingCode = normalized;
    this.lastError = null;
    return normalized;
  };
}

module.exports = {
  installPairingRecovery,
  pageIsUsable,
  waitForAuthenticationScreen,
  startFreshQrRecovery,
  terminateBrowser,
  archiveInvalidSession,
  withTimeout
};
