# Nitu Travels WhatsApp Gateway v2

Self-hosted, single-number WhatsApp Web gateway using Baileys 7 WebSocket transport, an encrypted SQLite auth store and a durable message queue.

## Key properties

- no Chromium, Puppeteer or browser profile;
- compatible with the existing Manage Nitu Travels gateway API;
- AES-256-GCM encrypted auth state;
- deterministic message IDs across retries;
- leased SQLite WAL outbox;
- monotonic sent/delivered/read state;
- reconnect backoff, heartbeat and send circuit breaker;
- durable signed webhook delivery.

## Development

```bash
npm install
npm run check
npm test
```

## Required environment

`API_KEY`, `ADMIN_TOKEN` and `WEBHOOK_SECRET` must each contain at least 32 characters. See `src/config.js` for optional tuning.

## Important

This project uses an unofficial WhatsApp Web protocol implementation. Use it only for consented operational communication, not unsolicited or bulk messaging. Meta Cloud API remains the appropriate option when contractual support and policy compliance are required.

See `docs/BAILEYS_V2_CASE_STUDY.md` for the research decision, failure analysis and acceptance plan.
