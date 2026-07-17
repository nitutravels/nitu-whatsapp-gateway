# Security and acceptable-use boundaries

## Trust model

This deployment has four sensitive credential classes:

1. OCI API signing key — permits GitHub Actions to manage resources in the gateway compartment.
2. Gateway API key — permits the Nitu Travels backend to enqueue messages.
3. Administrator token — permits dashboard and session administration.
4. Webhook HMAC secret — authenticates gateway callbacks to the website.

Store them only in GitHub environment secrets and the intended server-side systems. Never commit them to the repository, place them in screenshots, or paste them into public support chats.

## Infrastructure controls

The package uses:

- a dedicated OCI compartment
- a dedicated deployment user/group
- no inbound SSH rule
- only HTTP/HTTPS ingress
- a reserved public IP
- private, versioned Terraform state in OCI Object Storage
- Caddy HTTPS and security headers
- Docker `no-new-privileges`
- dropped Linux capabilities for the application container
- an unprivileged Node user inside the gateway container
- persistent data outside the image
- OCI metadata blocked from Docker containers through the `DOCKER-USER` firewall chain
- root-only five-minute configuration synchronization from OCI IMDSv2

The Chromium process requires `--no-sandbox` because the container drops privileges/capabilities and runs within Docker. This is still a weaker browser isolation boundary than Chrome's full sandbox. Do not expose arbitrary browsing functionality and keep media hosts allow-listed.

## API controls

- API and administrator credentials require at least 32 characters.
- Credential comparisons are timing-safe.
- Request bodies are limited to 1 MB.
- Global HTTP rate limiting is enabled.
- Outgoing message throughput is separately throttled.
- Media fetches reject HTTP, private networks and unapproved hostnames.
- Webhooks use HMAC-SHA256 over the exact raw JSON sent by the gateway.

## WhatsApp account safety

This gateway is an unofficial linked-device client. It cannot guarantee account safety or uninterrupted compatibility.

Use it only for transactional and operational messages to known recipients, such as:

- confirmed booking information
- duty slips
- driver departure reminders
- payment reminders connected to an existing transaction
- staff task reminders

Do not use it for:

- purchased contact lists
- unsolicited bulk advertising
- group-member extraction
- random-number checking
- high-concurrency blasting
- attempts to evade blocks, reports or rate limits

Maintain consent and opt-out records in the Nitu Travels application. Stop messaging recipients who opt out or repeatedly reject the messages.

## Recommended number strategy

Use a separate WhatsApp Business number during pilot operation. Keep the main customer-facing number outside the experiment until the gateway has demonstrated stable operation and acceptable recipient feedback.

## Secret rotation

Rotate immediately when a value may have leaked:

- OCI API key: delete the old public key from the OCI user, generate a new pair and update GitHub.
- Gateway API/admin/webhook secrets: generate new values, update GitHub and every dependent system, then run the provisioning workflow. The server synchronizes the new environment within five minutes.

Terraform records gateway configuration in state because it is part of instance metadata. Marking variables `sensitive` redacts routine CLI output but does not remove them from state. The workflow therefore uses a private, versioned OCI Object Storage bucket; access to that bucket is security-critical.

## Repository visibility

A public GHCR image is used so the VM can pull without storing a GitHub token. The source repository itself may remain private when GitHub package settings permit independent package visibility. Review every file before publication. This package intentionally contains placeholders only; actual secrets are injected at deployment.
