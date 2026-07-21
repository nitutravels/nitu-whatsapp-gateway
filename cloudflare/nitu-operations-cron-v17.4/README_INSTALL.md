# Nitu Travels Cloudflare Operations Cron v17.4

This single Worker runs every minute and calls both protected Manage Nitu Travels endpoints:

- WhatsApp queue preparation and WAHA delivery
- Reliable TBTrack private-snapshot import and collector dispatch

## Required website keys

1. Open **Admin → WhatsApp Delivery** and generate the Cloudflare/BigRock worker key.
2. Open **Admin → Reliable TBTrack Sync** and generate the TBTrack Cloudflare/BigRock key.

The keys are separate. Do not put either key in source code or a plaintext variable.

## Deploy with Wrangler

```bash
npm install
npx wrangler login
npx wrangler secret put NITU_WORKER_KEY
npx wrangler secret put NITU_TBTRACK_KEY
npx wrangler deploy
```

Paste the WhatsApp key for `NITU_WORKER_KEY` and the TBTrack key for `NITU_TBTRACK_KEY`.

The included Cron Trigger is:

```text
* * * * *
```

## Dashboard deployment

Create a Worker named `nitu-operations-cron`, paste `src/index.js`, add the two endpoint text variables from `wrangler.jsonc`, add both encrypted secrets, and create the one-minute Cron Trigger.

## Verify

Open:

```text
https://YOUR-WORKER.workers.dev/health
```

Both `secret_configured` values must be `true`. Then review **Observability → Logs**. Manage Nitu Travels should report both Cloudflare heartbeats online within a few successful runs.

## BigRock backups

Keep the website-generated WhatsApp and TBTrack backup commands in cPanel every 15 minutes. Each backup skips automatically while its corresponding Cloudflare heartbeat is healthy.
