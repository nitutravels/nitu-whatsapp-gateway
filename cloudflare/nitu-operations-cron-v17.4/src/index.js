const DEFAULT_WHATSAPP_ENDPOINT =
  "https://manage.nitutravels.in/whatsapp-dispatch-worker.php";
const DEFAULT_TBTRACK_ENDPOINT =
  "https://manage.nitutravels.in/tbtrack-sync-worker.php";

async function postWithTimeout({ name, endpoint, secret, header, timeoutMs, params }) {
  if (!secret) {
    throw new Error(`${name} secret is not configured`);
  }

  const url = new URL(endpoint);
  for (const [key, value] of Object.entries(params)) {
    url.searchParams.set(key, String(value));
  }

  const controller = new AbortController();
  const timeout = setTimeout(
    () => controller.abort(`${name} request timeout`),
    timeoutMs,
  );

  try {
    const response = await fetch(url.toString(), {
      method: "POST",
      headers: {
        Accept: "application/json",
        "User-Agent": "Nitu-Cloudflare-Operations-Cron/v17.4",
        [header]: secret,
      },
      signal: controller.signal,
    });

    const body = await response.text();
    if (!response.ok) {
      throw new Error(
        `${name} returned HTTP ${response.status}: ${body.slice(0, 1200)}`,
      );
    }

    const result = {
      ok: true,
      name,
      status: response.status,
      response: body.slice(0, 5000),
    };
    console.log(JSON.stringify(result));
    return result;
  } finally {
    clearTimeout(timeout);
  }
}

async function runAll(env, scheduledTime) {
  const workerId = `cloudflare-${scheduledTime}`;
  const jobs = [
    postWithTimeout({
      name: "whatsapp",
      endpoint: env.NITU_WHATSAPP_ENDPOINT || DEFAULT_WHATSAPP_ENDPOINT,
      secret: env.NITU_WORKER_KEY,
      header: "X-Nitu-Worker-Key",
      timeoutMs: 55_000,
      params: {
        limit: 25,
        budget: 45,
        source: "cloudflare-cron",
        worker_id: workerId,
        worker_version: "v17.4-cloudflare",
      },
    }),
    postWithTimeout({
      name: "tbtrack",
      endpoint: env.NITU_TBTRACK_ENDPOINT || DEFAULT_TBTRACK_ENDPOINT,
      secret: env.NITU_TBTRACK_KEY,
      header: "X-Nitu-TBTrack-Key",
      timeoutMs: 145_000,
      params: {
        source: "cloudflare-tbtrack-cron",
        worker_id: workerId,
        worker_version: "v17.4-cloudflare",
      },
    }),
  ];

  const settled = await Promise.allSettled(jobs);
  const summary = settled.map((item, index) => ({
    job: index === 0 ? "whatsapp" : "tbtrack",
    status: item.status,
    value: item.status === "fulfilled" ? item.value : undefined,
    error:
      item.status === "rejected"
        ? String(item.reason?.message || item.reason)
        : undefined,
  }));

  console.log(JSON.stringify({ ok: settled.every((x) => x.status === "fulfilled"), summary }));

  const failures = summary.filter((item) => item.status === "rejected");
  if (failures.length) {
    throw new Error(
      failures.map((item) => `${item.job}: ${item.error}`).join(" | "),
    );
  }

  return summary;
}

export default {
  async scheduled(controller, env, ctx) {
    ctx.waitUntil(runAll(env, String(controller.scheduledTime)));
  },

  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/health") {
      return Response.json({
        ok: true,
        service: "Nitu Travels operations cron",
        schedule: "every minute",
        whatsapp: {
          endpoint: env.NITU_WHATSAPP_ENDPOINT || DEFAULT_WHATSAPP_ENDPOINT,
          secret_configured: Boolean(env.NITU_WORKER_KEY),
        },
        tbtrack: {
          endpoint: env.NITU_TBTRACK_ENDPOINT || DEFAULT_TBTRACK_ENDPOINT,
          secret_configured: Boolean(env.NITU_TBTRACK_KEY),
        },
      });
    }

    return new Response(
      "Nitu Travels Cloudflare Operations Cron. Open /health.",
      {
        status: 200,
        headers: { "content-type": "text/plain; charset=UTF-8" },
      },
    );
  },
};
