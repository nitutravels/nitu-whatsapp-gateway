# Nitu Travels WhatsApp Gateway v2 — Research Case Study and Production Blueprint

## Executive decision

The first gateway used `whatsapp-web.js`, Chromium and a persistent browser profile. It is being replaced by a Baileys WebSocket gateway. Baileys implements the WhatsApp multi-device/Web protocol directly and does not require Selenium, Puppeteer or Chromium.

This remains an unofficial WhatsApp Web integration. It is appropriate only for low-volume, consented operational messages. It must not be used for unsolicited bulk messaging, and it cannot offer the contractual reliability of Meta Cloud API.

## Incident evidence

The original service produced contradictory states:

- the dashboard displayed `ready` while the account displayed `Not linked`;
- an account identifier remained cached while the browser state had returned to `loading`;
- the worker depended on the display status being exactly `ready`;
- sending later failed inside the browser object model with `Cannot read properties of undefined (reading 'getChat')`;
- pairing and recovery requests restarted Chromium and blocked HTTP requests;
- stale profile locks and browser-process restarts caused error/502 loops.

The fundamental problem was not a single timeout. Browser lifecycle, WhatsApp lifecycle and queue lifecycle were coupled in one mutable object.

## Alternatives researched

### Continue `whatsapp-web.js`

Rejected. It retains Chromium, injected browser scripts and the same browser/profile failure class that produced the incident.

### WPPConnect Server

WPPConnect Server is an actively released REST gateway with sessions and webhooks, but it also uses a browser/Puppeteer model. It is better packaged than the original gateway, yet it does not remove the main resource and lifecycle dependency.

### Evolution API

Evolution provides an event-driven multi-provider platform with PostgreSQL and Redis. It is suitable for multi-tenant/chatbot deployments, but it is substantially larger than required for one Nitu Travels number. Its newer release line also introduced activation/licensing requirements. Running the entire platform on the existing 1 GB VM would add operational surface without improving the single-number failure boundary.

### Baileys

Selected. The current supported line is 7.x. The release is pinned to `7.0.0-rc13`, rather than tracking the repository master. Baileys communicates through WebSocket and removes the memory footprint and failure surface of Chromium. The project explicitly requires production systems to persist every credentials/key update carefully, implement their own datastore, preserve retry state outside the socket, and reconnect for all disconnect reasons except a true logout.

## Production architecture

```text
Manage Nitu Travels
        |
        | POST /api/v1/messages (idempotency key)
        v
SQLite WAL durable outbox
        |
        | one leased message at a time
        v
Queue worker ---- circuit breaker ---- reconnect supervisor
        |
        | deterministic WhatsApp message ID
        v
Baileys 7 WebSocket transport
        |
        +--> connection.update: open / close / QR
        +--> creds.update: encrypted transactional SQLite auth store
        +--> messages.update / receipts: sent / delivered / read
        +--> inbound messages
        |
        v
Durable webhook outbox --> Manage Nitu Travels callback
```

## Reliability controls

### Transport readiness

`ready` is true only when all conditions are simultaneously true:

1. the Baileys connection event is `open`;
2. encrypted credentials report `registered=true`;
3. a live socket object exists.

Cached account information can never independently make the service ready.

### Transactional authentication state

Credentials and all Signal/app-state keys are stored in SQLite and encrypted with AES-256-GCM. The encryption key is derived from `AUTH_ENCRYPTION_KEY` when supplied, otherwise from the existing gateway secrets. Every `creds.update` event is persisted. Key updates are committed in a single transaction.

The old Chromium session directory is ignored. One fresh link is required after migration.

### Durable queue and leases

The HTTP API always writes to SQLite before returning 202. The worker atomically leases one due row. If the process stops during a send, the lease expires and returns the row to retry.

### Deterministic provider IDs

A WhatsApp message ID is generated once and persisted before transmission. Retries reuse that ID. This materially lowers duplicate risk when a network timeout occurs after WhatsApp accepted a message but before the server received the response.

### Status monotonicity

Message state may move forward only:

`queued/retry -> sending -> sent -> delivered -> read`

A late `sent` receipt cannot downgrade `delivered` or `read`.

### Reconnect policy

- `loggedOut`: stop and require operator pairing;
- `restartRequired`: reconnect immediately;
- transient connection closure/loss/timeout: exponential backoff with jitter;
- heartbeat failure: replace the socket;
- three consecutive sends failing: open a circuit, pause claims and reconnect.

### Bounded operations

- pairing code: 20 seconds;
- text send: 45 seconds;
- media send: 90 seconds;
- media DNS and SSRF validation before queueing;
- webhook delivery: 12 seconds with a separate durable retry queue.

### Resource model

There is no Chromium, shared-memory browser allocation or browser cache. The service uses Node 22, Baileys and Node's built-in SQLite module. The VM's existing SQLite backup captures both the message queue and encrypted auth state.

## API compatibility

The rebuilt gateway preserves the existing endpoints used by Manage Nitu Travels:

- `GET /healthz`
- `GET /readyz`
- `POST /api/v1/messages`
- `GET /api/v1/messages/:id`
- `GET /admin/api/status`
- `GET /admin/api/messages`
- `POST /admin/api/test`
- `POST /admin/api/messages/:id/retry`
- `POST /admin/api/pair`
- `POST /admin/api/reconnect`
- `POST /admin/api/reset`

## Acceptance case study

The deployment is accepted only after this sequence:

1. `/healthz` returns HTTP 200 while unpaired.
2. `/readyz` returns 503 while unpaired.
3. A queued test remains durable across a container restart.
4. A fresh QR or pairing code links the device.
5. `/readyz` changes to 200 only after `connection=open`.
6. The queued test advances to `sent`, then `delivered` or `read`.
7. Restart the container; encrypted credentials reconnect without another QR.
8. Disconnect the VM network briefly; the queue pauses without losing rows and resumes after reconnection.
9. Submit the same idempotency key twice; both responses identify the same row.
10. Force a send timeout; retry retains the same provider message ID.

## Rollout and rollback

The rebuild is prepared on `rebuild/baileys-v2`. Merging to `main` with a `[deploy]` commit triggers image build, Terraform apply and control-plane recovery. The host retains `gateway.sqlite`; existing message history and queue records are migrated in place.

Rollback is a container image rollback. The old Chromium authentication files remain on disk but are not read by v2. Rolling back to v1 restores the old code but not a stable browser session; therefore rollback is for API availability only, not the preferred transport recovery.

## Operational rule

Do not reset the session for ordinary disconnects. Use **Reconnect socket** first. **Reset session** is destructive and is reserved for a confirmed logout or invalid credentials.
