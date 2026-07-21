const DEFAULT_ENDPOINT = "https://manage.nitutravels.in/whatsapp-dispatch-worker.php";

async function runQueue(env, trigger = "scheduled") {
  const endpoint = env.NITU_ENDPOINT || DEFAULT_ENDPOINT;
  const url = new URL(endpoint);
  url.searchParams.set("limit", "25");
  url.searchParams.set("budget", "45");
  url.searchParams.set("source", "cloudflare-cron");
  url.searchParams.set("worker_id", `cloudflare-${trigger}`);
  url.searchParams.set("worker_version", "v17.2-cloudflare");

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort("queue request timeout"), 55000);
  try {
    const response = await fetch(url.toString(), {
      method: "POST",
      headers: {
        Accept: "application/json",
        "User-Agent": "Nitu-Cloudflare-WhatsApp-Cron/v17.2",
        "X-Nitu-Worker-Key": env.NITU_WORKER_KEY,
      },
      signal: controller.signal,
    });
    const body = await response.text();
    if (!response.ok) {
      throw new Error(`Manage queue returned HTTP ${response.status}: ${body.slice(0, 1000)}`);
    }
    console.log(JSON.stringify({ ok: true, trigger, status: response.status, response: body.slice(0, 4000) }));
    return body;
  } finally {
    clearTimeout(timeout);
  }
}

export default {
  async scheduled(controller, env, ctx) {
    ctx.waitUntil(runQueue(env, String(controller.scheduledTime)));
  },

  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/health") {
      return Response.json({
        ok: true,
        service: "Nitu Travels WhatsApp queue cron",
        schedule: "every minute",
        endpoint: env.NITU_ENDPOINT || DEFAULT_ENDPOINT,
      });
    }
    return new Response("Nitu Travels WhatsApp Cron Worker. Use /health.", { status: 200 });
  },
};
