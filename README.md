# Nitu Travels WhatsApp Linked-Device Gateway

A complete, self-hosted WhatsApp linked-device gateway designed for an Oracle Cloud Always Free Ampere A1 instance and deployed from GitHub Actions. It does not require a laptop, an always-on computer, MacroDroid, or a paid gateway subscription.

> **Important:** This is an unofficial WhatsApp Web integration. It is not Meta's official WhatsApp Business Platform. Use a dedicated business number, message only recipients who have consented, honour opt-outs, and do not use it for scraping or unsolicited bulk messaging.

## What is included

- Phone-number pairing code and QR pairing dashboard
- Persistent linked-device session
- REST API for text, image and document messages
- Durable SQLite queue with scheduling, retries and idempotency
- Delivery/read acknowledgement tracking
- Incoming-message and delivery webhooks signed with HMAC-SHA256
- Global send throttling with a minimum five-second interval
- HTTPS through Caddy with automatic certificate renewal
- Multi-architecture Docker image for Oracle Arm and local x86 testing
- Terraform provisioning for OCI networking, compute and a reserved public IP
- GitHub Actions build, deployment and controlled destroy workflows
- Automatic image updates, five-minute configuration sync and daily local backups
- No public SSH port

## Architecture

```text
Nitu Travels application
        |
        | HTTPS + API key
        v
Caddy reverse proxy
        |
        v
Fastify gateway + SQLite queue
        |
        v
whatsapp-web.js + Chromium
        |
        v
WhatsApp linked device

GitHub Actions ---- Terraform ---- Oracle Cloud A1
       |                              |
       +---- GHCR container image ----+
```

## Deployment target

The Terraform defaults create:

- `VM.Standard.A1.Flex`
- 1 OCPU
- 4 GB RAM
- 50 GB boot volume
- Ubuntu 24.04
- Reserved public IPv4 address
- Ports 80/TCP, 443/TCP and 443/UDP only

These right-sized values fit inside Oracle's documented Always Free A1 allowance at the time this package was generated and leave unused free-tier capacity available. Availability is not guaranteed; Oracle may return an out-of-host-capacity error, and Oracle documents that idle Always Free compute instances may be reclaimed.

## Pinned toolchain

Generated and reviewed on 17 July 2026 using pinned, supported versions selected from the current official release lines:

- Terraform `1.15.8` (the `1.16` line was still pre-release)
- Oracle OCI Terraform provider `8.23.0`
- `whatsapp-web.js` `1.34.7`
- Node.js `22`
- Ubuntu `24.04 LTS`
- Caddy `2.11.1`
- GitHub Actions: Checkout `v7`, Docker QEMU/Buildx/Login `v4`, Docker Build-Push `v7`, Setup Terraform `v4`

Dependency versions are locked in `package-lock.json`; Dependabot is configured to propose future application and GitHub Actions updates rather than silently changing production.

## Start here

1. Read [`docs/PHONE_SETUP.md`](docs/PHONE_SETUP.md).
2. Create the GitHub repository and upload this package.
3. Add the listed GitHub secrets and variables.
4. Run the workflow once in build-only mode.
5. Make the generated GHCR package public.
6. Run the workflow again with infrastructure provisioning enabled.
7. Point your DNS record to the reserved IP shown in the workflow summary.
8. Open the HTTPS dashboard and link WhatsApp using the pairing code.
9. Integrate the message API using [`docs/API.md`](docs/API.md).

## API example

```bash
curl -X POST 'https://wa.nitutravels.in/api/v1/messages' \
  -H 'content-type: application/json' \
  -H 'x-api-key: YOUR_GATEWAY_API_KEY' \
  -d '{
    "to": "919810000000",
    "text": "Your duty starts tomorrow at 7:00 AM.",
    "idempotencyKey": "duty-4821-driver-reminder-1",
    "metadata": {"dutyId":"4821","category":"departure-reminder"}
  }'
```

A successful request returns `202 Accepted`. The message is queued and sent only when the linked session is ready.

## Repository layout

```text
.github/workflows/       Build, deploy and destroy workflows
infra/terraform/         OCI network, VM and bootstrap configuration
src/                     Gateway, queue, authentication and webhook code
public/                  Mobile-friendly administration dashboard
examples/php/            PHP integration examples
docs/                    Setup, operations, security and API guides
```

## Automatic updates and configuration sync

Every push to `main` builds and publishes `:latest`. The Oracle instance checks for a new image every ten minutes and applies it with Docker Compose. Changes to GitHub deployment variables or gateway secrets are written by Terraform to OCI custom instance metadata; a root-only service checks every five minutes, validates the generated environment file and restarts the containers only when configuration changed. Docker containers are blocked from reaching the OCI metadata endpoint. The WhatsApp authentication directory and SQLite database are mounted outside the container and survive container replacement.

## Backups

The server creates a consistent SQLite backup and a best-effort authentication-directory archive every day at 02:30 UTC, retaining seven days under `/opt/nitu-wa/backups`. These are local backups on the same boot volume. For disaster recovery from complete volume loss, add an external encrypted backup destination before treating the gateway as mission-critical.

## Operational limits

- One linked WhatsApp account per deployment
- One queued message dispatched at a time
- Minimum default spacing: six seconds
- Default maximum attempts: three
- Media must be served over HTTPS from an allow-listed hostname
- No group scraping, number enumeration or campaign blasting features
- Linked-device compatibility can break when WhatsApp Web changes

## Verification

```bash
npm run check
npm test
terraform -chdir=infra/terraform fmt -recursive
terraform -chdir=infra/terraform init -backend=false
terraform -chdir=infra/terraform validate
```

The included GitHub deployment workflow runs Terraform formatting and validation before applying infrastructure.

`MANIFEST.sha256` provides a checksum for every packaged source file.

## Documentation

- [`PHONE_SETUP.md`](docs/PHONE_SETUP.md) — complete Android/browser deployment
- [`API.md`](docs/API.md) — REST and webhook contract
- [`OPERATIONS.md`](docs/OPERATIONS.md) — updates, logs, backup and recovery
- [`SECURITY.md`](docs/SECURITY.md) — credentials, access controls and risk boundaries
- [`TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — common OCI, DNS and pairing failures
- [`OFFICIAL_REFERENCES.md`](docs/OFFICIAL_REFERENCES.md) — official documentation used
- [`VALIDATION_REPORT.md`](docs/VALIDATION_REPORT.md) — completed checks and remaining live-deployment gates

## Licence

MIT. The WhatsApp and Oracle trademarks belong to their respective owners.
