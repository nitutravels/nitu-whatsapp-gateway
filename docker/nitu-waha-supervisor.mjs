const baseUrl = 'http://127.0.0.1:3000';
const apiKey = process.env.WAHA_API_KEY || '';
const session = process.env.WAHA_SESSION || 'nitu-travels';
const workerUrl = process.env.WEBSITE_WORKER_URL || '';
const workerKey = process.env.WAHA_WORKER_KEY || apiKey;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function request(url, options = {}, timeoutMs = 15000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

async function waitForWaha() {
  for (;;) {
    try {
      const response = await request(`${baseUrl}/health`, {}, 5000);
      if (response.ok) return;
    } catch {}
    await sleep(3000);
  }
}

async function ensureSession() {
  try {
    let response = await request(`${baseUrl}/api/sessions/${encodeURIComponent(session)}`, {
      headers: { 'X-Api-Key': apiKey },
    });

    if (response.status === 404) {
      response = await request(`${baseUrl}/api/sessions`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Api-Key': apiKey,
        },
        body: JSON.stringify({ name: session }),
      }, 30000);
      if (!response.ok && response.status !== 409) {
        console.error(`session create failed: HTTP ${response.status}`);
        return;
      }
      await sleep(2000);
    }

    response = await request(`${baseUrl}/api/sessions/${encodeURIComponent(session)}`, {
      headers: { 'X-Api-Key': apiKey },
    });
    if (!response.ok) return;

    const payload = await response.json().catch(() => ({}));
    const status = String(payload.status || 'UNKNOWN');
    if (status === 'STOPPED') {
      await request(`${baseUrl}/api/sessions/${encodeURIComponent(session)}/start`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Api-Key': apiKey,
        },
        body: '{}',
      }, 30000).catch(() => {});
    } else if (status === 'FAILED') {
      await request(`${baseUrl}/api/sessions/${encodeURIComponent(session)}/restart`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Api-Key': apiKey,
        },
        body: '{}',
      }, 30000).catch(() => {});
    }
  } catch (error) {
    console.error(`session supervisor error: ${error?.message || error}`);
  }
}

async function drainWebsite() {
  if (!workerUrl || !workerKey) return;
  try {
    const response = await request(workerUrl, {
      method: 'POST',
      headers: {
        'X-Worker-Key': workerKey,
        'X-Api-Key': workerKey,
        'User-Agent': 'Nitu-WAHA-Worker/1.0',
      },
    }, 25000);
    if (!response.ok && response.status !== 404) {
      console.error(`website worker returned HTTP ${response.status}`);
    }
  } catch (error) {
    console.error(`website worker error: ${error?.message || error}`);
  }
}

await waitForWaha();
await ensureSession();
await drainWebsite();

let lastSessionCheck = 0;
for (;;) {
  const now = Date.now();
  if (now - lastSessionCheck >= 30000) {
    await ensureSession();
    lastSessionCheck = now;
  }
  await drainWebsite();
  await sleep(60000);
}
