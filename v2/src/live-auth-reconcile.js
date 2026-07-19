function normalizeAccount(source) {
  if (!source || typeof source !== 'object') return null;
  const wid = source.id || source.jid || source.lid || null;
  if (!wid) return null;
  return {
    wid,
    name: source.name || source.notify || source.verifiedName || null,
    lid: source.lid || null
  };
}

export function installLiveAuthReconciliation(WhatsAppTransport) {
  const prototype = WhatsAppTransport?.prototype;
  if (!prototype || prototype.__liveAuthReconciliationInstalled) return;
  Object.defineProperty(prototype, '__liveAuthReconciliationInstalled', { value: true });

  prototype.attachQueueWorker = function attachQueueWorker(worker) {
    this.queueWorker = worker || null;
    return this;
  };

  prototype.liveCreds = function liveCreds() {
    return this.socket?.authState?.creds || this.auth?.state?.creds || null;
  };

  prototype.reconcileLiveIdentity = function reconcileLiveIdentity() {
    const creds = this.liveCreds();
    const candidate = this.socket?.user || creds?.me || this.account;
    const account = normalizeAccount(candidate);
    if (account) this.account = account;
    return {
      registered: Boolean(creds?.registered),
      account: this.account,
      hasIdentity: Boolean(account || creds?.me)
    };
  };

  prototype.cancelIncompleteAuthRepair = function cancelIncompleteAuthRepair() {
    if (this.incompleteAuthRepairTimer) clearTimeout(this.incompleteAuthRepairTimer);
    this.incompleteAuthRepairTimer = null;
  };

  prototype.scheduleIncompleteAuthRepair = function scheduleIncompleteAuthRepair(generation) {
    if (this.incompleteAuthRepairTimer || this.authRepairInProgress) return;
    this.authRepairScheduledAt = new Date().toISOString();
    this.incompleteAuthRepairTimer = setTimeout(async () => {
      this.incompleteAuthRepairTimer = null;
      if (generation !== this.generation || this.phase !== 'auth_incomplete') return;
      const live = this.reconcileLiveIdentity();
      if (live.registered) return;

      this.authRepairInProgress = true;
      this.authRepairStartedAt = new Date().toISOString();
      try {
        this.queueWorker?.pause?.('Paused automatically while rebuilding incomplete WhatsApp authentication');
        this.logger.error({ generation }, 'Open Baileys socket has no registered credentials; rebuilding local auth and requesting a fresh QR');
        await this.resetSession();
      } catch (error) {
        this.lastError = `Automatic authentication repair failed: ${String(error?.message || error)}`;
        this.phase = 'error';
        this.logger.error({ err: error }, 'Automatic incomplete-auth repair failed');
      } finally {
        this.authRepairInProgress = false;
      }
    }, 5000);
    this.incompleteAuthRepairTimer.unref?.();
  };

  prototype.isReady = function isReadyFromLiveSocket() {
    const live = this.reconcileLiveIdentity();
    return this.connected === true && this.phase === 'open' && live.registered && Boolean(this.socket);
  };

  const originalBindEvents = prototype.bindEvents;
  prototype.bindEvents = function bindEventsWithCredentialMerge(socket, generation) {
    originalBindEvents.call(this, socket, generation);
    socket.ev.on('creds.update', async update => {
      if (generation !== this.generation || socket !== this.socket) return;
      try {
        const liveUpdate = update && typeof update === 'object'
          ? update
          : socket.authState?.creds || {};
        await this.auth?.saveCreds?.(liveUpdate);
        const live = this.reconcileLiveIdentity();
        if (live.registered) {
          this.cancelIncompleteAuthRepair();
          if (this.connected) this.phase = 'open';
          this.lastError = null;
        }
      } catch (error) {
        this.lastError = `Credential persistence failed: ${String(error?.message || error)}`;
        this.logger.error({ err: error }, 'Could not persist live WhatsApp credentials');
      }
    });
  };

  const originalHandleConnectionUpdate = prototype.handleConnectionUpdate;
  prototype.handleConnectionUpdate = async function handleConnectionUpdateWithReconciliation(update, generation) {
    await originalHandleConnectionUpdate.call(this, update, generation);
    if (generation !== this.generation) return;

    if (update?.qr) {
      this.cancelIncompleteAuthRepair();
      this.authRepairScheduledAt = null;
      return;
    }

    if (update?.connection === 'open') {
      const live = this.reconcileLiveIdentity();
      if (live.registered) {
        this.cancelIncompleteAuthRepair();
        this.phase = 'open';
        this.lastError = null;
        try {
          await this.auth?.saveCreds?.(this.liveCreds() || {});
        } catch (error) {
          this.lastError = `Credential persistence failed after socket open: ${String(error?.message || error)}`;
        }
        this.logger.info({ account: live.account }, 'Reconciled registered WhatsApp identity from live socket');
      } else {
        this.phase = 'auth_incomplete';
        this.lastError = 'WhatsApp opened the transport but the server has no registered device credentials. Delivery is paused and a fresh QR is being prepared automatically.';
        this.scheduleIncompleteAuthRepair(generation);
      }
    }

    if (update?.connection === 'close') this.cancelIncompleteAuthRepair();
  };

  const originalStatus = prototype.status;
  prototype.status = function statusFromLiveSocket() {
    const base = originalStatus.call(this);
    const live = this.reconcileLiveIdentity();
    const ready = this.connected === true && this.phase === 'open' && live.registered && Boolean(this.socket);
    const authIncomplete = this.phase === 'auth_incomplete' || (this.connected === true && !live.registered);
    return {
      ...base,
      gatewayVersion: '2.1.3',
      status: ready ? 'ready' : this.phase,
      ready,
      connected: this.connected,
      registered: live.registered,
      account: ready ? live.account : null,
      authSource: this.socket?.authState?.creds ? 'live-socket' : 'stored-state',
      authIncomplete,
      authRepairInProgress: Boolean(this.authRepairInProgress),
      authRepairScheduledAt: this.authRepairScheduledAt || null,
      authRepairStartedAt: this.authRepairStartedAt || null
    };
  };

  const originalClose = prototype.close;
  prototype.close = async function closeWithRepairCleanup() {
    this.cancelIncompleteAuthRepair();
    return originalClose.call(this);
  };
}
