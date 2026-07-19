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
      account: this.account
    };
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
        await this.auth?.saveCreds?.(update || socket.authState?.creds || {});
        this.reconcileLiveIdentity();
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
    if (update?.connection === 'open') {
      const live = this.reconcileLiveIdentity();
      if (live.registered) {
        this.lastError = null;
        this.logger.info({ account: live.account }, 'Reconciled registered WhatsApp identity from live socket');
      }
    }
  };

  const originalStatus = prototype.status;
  prototype.status = function statusFromLiveSocket() {
    const base = originalStatus.call(this);
    const live = this.reconcileLiveIdentity();
    const ready = this.connected === true && this.phase === 'open' && live.registered && Boolean(this.socket);
    return {
      ...base,
      status: ready ? 'ready' : this.phase,
      ready,
      connected: this.connected,
      registered: live.registered,
      account: ready ? live.account : null,
      authSource: this.socket?.authState?.creds ? 'live-socket' : 'stored-state'
    };
  };
}
