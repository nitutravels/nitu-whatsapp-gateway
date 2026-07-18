const $ = id => document.getElementById(id);
let token = localStorage.getItem('gatewayAdminToken') || '';
let poll = null;
let lastStatus = null;

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>'"]/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[character]));
}

function toast(message) {
  const element = $('toast');
  element.textContent = message;
  element.classList.add('show');
  setTimeout(() => element.classList.remove('show'), 5000);
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${token}`,
      ...(options.headers || {})
    }
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || `Request failed (${response.status})`);
  return data;
}

function showLogin() {
  $('loginCard').hidden = false;
  $('dashboard').hidden = true;
  clearInterval(poll);
}

function showDashboard() {
  $('loginCard').hidden = true;
  $('dashboard').hidden = false;
  loadAll();
  clearInterval(poll);
  poll = setInterval(loadStatus, 3000);
}

function prettyStatus(status) {
  if (status.ready) return 'Ready';
  const names = { pairing: 'Pairing required', connecting: 'Connecting', reconnecting: 'Reconnecting', logged_out: 'Logged out', error: 'Error', starting: 'Starting' };
  return names[status.phase] || status.phase || 'Offline';
}

async function loadStatus() {
  try {
    const status = await api('/admin/api/status');
    lastStatus = status;
    $('status').textContent = prettyStatus(status);
    $('phase').textContent = `phase: ${status.phase || 'unknown'} · registered: ${status.registered ? 'yes' : 'no'}`;
    $('account').textContent = status.account?.wid || 'Not linked';
    $('engine').textContent = `${status.engine || 'unknown'} ${status.engineVersion || ''}`;
    const queue = status.queue || {};
    $('queued').textContent = (queue.queued || 0) + (queue.retry || 0) + (queue.sending || 0);
    $('failed').textContent = queue.failed || 0;
    $('worker').textContent = status.worker?.busy ? 'worker sending' : status.worker?.circuitOpenUntil ? 'circuit paused' : 'worker idle';
    $('heartbeat').textContent = status.lastHeartbeatAt ? `heartbeat ${new Date(status.lastHeartbeatAt).toLocaleTimeString()}` : 'no heartbeat yet';

    const showConnect = !status.ready;
    $('connectCard').hidden = !showConnect;
    $('qrWrap').hidden = !status.qrDataUrl;
    if (status.qrDataUrl) $('qr').src = status.qrDataUrl;
    $('pairingOutput').hidden = !status.pairingCode;
    if (status.pairingCode) $('pairingCode').textContent = status.pairingCode.match(/.{1,4}/g)?.join(' ') || status.pairingCode;

    const diagnostic = status.lastError || status.lastHeartbeatError || '';
    $('diagnostic').hidden = !diagnostic;
    $('diagnostic').textContent = diagnostic ? diagnostic.split('\n')[0] : '';
  } catch (error) {
    if (/Unauthorized/i.test(error.message)) {
      localStorage.removeItem('gatewayAdminToken');
      token = '';
      showLogin();
    } else {
      toast(error.message);
    }
  }
}

async function loadMessages() {
  try {
    const rows = await api('/admin/api/messages?limit=100');
    $('messages').innerHTML = rows.map(message => `<tr>
      <td>${new Date(message.createdAt).toLocaleString()}</td>
      <td>${escapeHtml(message.to)}</td>
      <td><span class="status ${escapeHtml(message.status)}">${escapeHtml(message.status)}</span></td>
      <td>${message.attempts}</td>
      <td>${message.uncertain ? 'Yes' : 'No'}</td>
      <td>${escapeHtml(message.error || '')}</td>
      <td>${message.status === 'failed' ? `<button class="secondary retryMessage" data-id="${escapeHtml(message.id)}">Retry</button>` : '—'}</td>
    </tr>`).join('');
  } catch (error) {
    toast(error.message);
  }
}

async function loadAll() {
  await Promise.all([loadStatus(), loadMessages()]);
}

$('loginForm').addEventListener('submit', async event => {
  event.preventDefault();
  token = $('token').value.trim();
  try {
    await api('/admin/api/status');
    localStorage.setItem('gatewayAdminToken', token);
    showDashboard();
  } catch (error) {
    toast(error.message);
  }
});

$('forgetToken').addEventListener('click', () => {
  localStorage.removeItem('gatewayAdminToken');
  token = '';
  showLogin();
});

$('pairForm').addEventListener('submit', async event => {
  event.preventDefault();
  const button = event.currentTarget.querySelector('button');
  button.disabled = true;
  button.textContent = 'Generating…';
  try {
    const result = await api('/admin/api/pair', { method: 'POST', body: JSON.stringify({ phoneNumber: $('phone').value }) });
    $('pairingOutput').hidden = false;
    $('pairingCode').textContent = result.pairingCode.match(/.{1,4}/g)?.join(' ') || result.pairingCode;
    toast('Pairing code generated');
  } catch (error) {
    toast(error.message);
  } finally {
    button.disabled = false;
    button.textContent = 'Generate code';
    loadStatus();
  }
});

$('reconnect').addEventListener('click', async () => {
  try {
    await api('/admin/api/reconnect', { method: 'POST', body: '{}' });
    toast('Socket reconnect requested');
    setTimeout(loadStatus, 1500);
  } catch (error) { toast(error.message); }
});

$('reset').addEventListener('click', async () => {
  if (!confirm('This deletes the stored linked-device credentials and requires a fresh QR or pairing code. Continue?')) return;
  try {
    await api('/admin/api/reset', { method: 'POST', body: '{}' });
    toast('Session reset started');
    setTimeout(loadStatus, 1500);
  } catch (error) { toast(error.message); }
});

$('testForm').addEventListener('submit', async event => {
  event.preventDefault();
  try {
    await api('/admin/api/test', { method: 'POST', body: JSON.stringify({ to: $('testTo').value, text: $('testText').value }) });
    $('testText').value = '';
    toast(lastStatus?.ready ? 'Test queued for immediate delivery' : 'Test stored; delivery waits for an open socket');
    loadMessages();
  } catch (error) { toast(error.message); }
});

$('refresh').addEventListener('click', loadAll);
$('messages').addEventListener('click', async event => {
  const button = event.target.closest('.retryMessage');
  if (!button) return;
  button.disabled = true;
  try {
    await api(`/admin/api/messages/${encodeURIComponent(button.dataset.id)}/retry`, { method: 'POST', body: '{}' });
    toast('Message returned to the durable queue');
    loadAll();
  } catch (error) {
    toast(error.message);
  } finally {
    button.disabled = false;
  }
});

if (token) showDashboard(); else showLogin();
