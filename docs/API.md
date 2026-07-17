# REST API and webhook contract

Base URL:

```text
https://YOUR_GATEWAY_DOMAIN
```

## Authentication

The message API accepts either:

```http
X-API-Key: GATEWAY_API_KEY
```

or:

```http
Authorization: Bearer GATEWAY_API_KEY
```

The administration API accepts only:

```http
Authorization: Bearer GATEWAY_ADMIN_TOKEN
```

Never expose either value in public frontend JavaScript.

## Queue a text message

`POST /api/v1/messages`

```json
{
  "to": "919810000000",
  "text": "Your duty starts tomorrow at 7:00 AM.",
  "idempotencyKey": "duty:4821:driver:93:departure:1",
  "scheduledAt": "2026-07-18T01:30:00+05:30",
  "metadata": {
    "dutyId": "4821",
    "driverId": "93",
    "category": "departure-reminder"
  }
}
```

Rules:

- `to`: 8–15 digits. A ten-digit Indian number automatically receives country code `91` by default.
- `text`: 1–5,000 characters.
- `idempotencyKey`: optional but strongly recommended; 3–200 characters.
- `scheduledAt`: optional ISO 8601 timestamp with timezone offset.
- `metadata`: optional string-keyed JSON object.

Response: `202 Accepted`

```json
{
  "id": "f97d22df-7d64-4ea1-a1ca-2fbf4434bb45",
  "idempotencyKey": "duty:4821:driver:93:departure:1",
  "to": "919810000000@c.us",
  "type": "text",
  "status": "queued",
  "attempts": 0,
  "scheduledAt": "2026-07-18T01:30:00.000Z"
}
```

Submitting the same idempotency key returns the existing record rather than inserting another message.

## Queue media or a document

```json
{
  "to": "919810000000",
  "mediaUrl": "https://nitutravels.in/files/duty-slip-4821.pdf",
  "caption": "Duty slip 4821",
  "filename": "Duty-Slip-4821.pdf",
  "asDocument": true,
  "idempotencyKey": "duty:4821:driver:93:document"
}
```

Security rules:

- Media URL must use HTTPS.
- Hostname must be listed in `MEDIA_ALLOWED_HOSTS` when that setting is non-empty.
- Hostname must not resolve to a loopback, link-local or private IP.

## Get message status

`GET /api/v1/messages/{id}`

Possible statuses:

```text
queued
sending
retry
sent
delivered
read
failed
```

## Manually retry a failed message

`POST /admin/api/messages/{id}/retry`

Requires the administrator bearer token. Only a message in `failed` state can be returned to the queue. Its attempt counter is reset, and a `message.manual_retry` audit event is recorded locally.

## Health endpoints

`GET /healthz`

Returns HTTP 200 when the application process is running.

`GET /readyz`

Returns HTTP 200 only when the WhatsApp linked-device session is ready; otherwise HTTP 503.

## Webhooks

Set `WEBHOOK_URL` to an HTTPS endpoint on the Nitu Travels website.

Events:

```text
session.ready
session.auth_failure
session.disconnected
message.sent
message.delivered
message.read
message.retry_scheduled
message.failed
message.received
```

Payload:

```json
{
  "event": "message.delivered",
  "data": {
    "id": "f97d22df-7d64-4ea1-a1ca-2fbf4434bb45",
    "status": "delivered"
  },
  "occurredAt": "2026-07-17T21:12:03.482Z"
}
```

Signature header:

```http
X-Gateway-Signature: sha256=HEX_HMAC
```

Verification algorithm:

```text
HMAC-SHA256(raw_request_body, GATEWAY_WEBHOOK_SECRET)
```

Compare the complete `sha256=...` value using a timing-safe function.

The gateway attempts each webhook once with a ten-second timeout. A failed webhook does not reverse the WhatsApp message status. The website should use message-status polling as a reconciliation mechanism if webhooks are business-critical.

## Recommended alert sequence

```text
1. Queue WhatsApp message with idempotency key
2. Wait for delivered/read webhook or poll status
3. Retry only through the gateway's internal retry mechanism
4. After the business-defined timeout, invoke SMS fallback
5. Stop reminders after completion or opt-out
```
