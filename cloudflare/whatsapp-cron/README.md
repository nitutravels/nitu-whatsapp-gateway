# Nitu Travels Cloudflare WhatsApp Cron v17.2

This Worker calls the Manage Nitu Travels authenticated WhatsApp queue endpoint every minute. The worker key is stored as a Cloudflare encrypted secret and is never placed in the Worker source or request URL.

## Deploy

1. In Manage Nitu Travels, open **Admin → WhatsApp delivery**.
2. Click **Generate Cloudflare/BigRock key + URLs** and copy the generated key characters.
3. From this directory run:

```bash
npm install
npx wrangler login
npx wrangler secret put NITU_WORKER_KEY
npx wrangler deploy
```

Paste the generated Manage worker key when prompted.

The included configuration installs this Cron Trigger:

```text
* * * * *
```

## Verify

Open Cloudflare Dashboard → Workers & Pages → `nitu-whatsapp-cron` → Observability → Logs. Manage Nitu Travels should show **Cloudflare cron ONLINE** within three minutes.

The public Worker route exposes only `/health`; it does not expose the secret or provide a public queue-run endpoint.

## BigRock backup

Keep the cPanel command displayed in Manage Nitu Travels scheduled every 15 minutes. The website checks the Cloudflare heartbeat first. While Cloudflare is healthy, the BigRock run exits successfully without processing the queue. When Cloudflare has been stale for more than three minutes, BigRock processes a bounded batch of up to 50 messages.
