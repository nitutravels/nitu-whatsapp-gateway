# Phone-only deployment guide

This guide assumes you are using Chrome on Android. No local computer or purchased VPS is required. Oracle Cloud is the continuously running host; GitHub stores, builds and deploys the source.

## Before starting

You need:

- An Oracle Cloud account with Always Free resources available in its home region; Oracle may require a payment card for identity verification
- A GitHub account
- A domain or subdomain you control, for example `wa.nitutravels.in`
- A dedicated WhatsApp Business number for the gateway
- Access to edit the domain's DNS record

Do not use the company's irreplaceable primary WhatsApp number for initial testing. Oracle also documents that idle Always Free instances may be reclaimed, so this zero-cost deployment does not provide an uptime SLA.

Before provisioning, check that other A1 instances and boot volumes are not already consuming the tenancy-wide Always Free allowance. The package defaults to 1 OCPU, 4 GB RAM and a 50 GB boot volume, but Oracle can charge a Pay As You Go account when total tenancy usage exceeds the free allowance. Do not upgrade the account or change the shape unless you deliberately accept that risk.

## Part 1 — Prepare Oracle Cloud

### 1. Create a compartment

In the Oracle Console:

1. Open **Identity & Security**.
2. Open **Compartments**.
3. Create a compartment named `NituWAGateway`.
4. Copy its OCID. This becomes `OCI_COMPARTMENT_OCID` in GitHub.

### 2. Create a deployment user and group

Recommended:

1. Create a group named `NituWAGatewayDeployers`.
2. Create a non-human deployment user named `github-nitu-wa`.
3. Add that user to the group.
4. At the tenancy level, create a policy using Oracle's compartment-administrator policy template, or use this manual statement when the group is in the default identity domain:

```text
Allow group NituWAGatewayDeployers to manage all-resources in compartment NituWAGateway
Allow group NituWAGatewayDeployers to inspect compartments in tenancy
```

The second statement permits tenancy-level discovery required by OCI tooling while resource creation remains restricted to the gateway compartment.

For identity-domain-qualified groups, select the group through Policy Builder rather than guessing the domain syntax.

The policy deliberately limits the automation user to the gateway compartment.

### 3. Generate an API signing key

Open the deployment user's details:

1. Open **API keys**.
2. Choose **Add API key**.
3. Choose **Generate API key pair**.
4. Download the private key immediately.
5. Copy the configuration preview values:
   - user OCID
   - tenancy OCID
   - fingerprint
   - region
6. Keep the private key file private. Never commit it to GitHub.

### 4. Record the Object Storage namespace

Open tenancy details and copy the **Object Storage namespace**. This becomes `OCI_NAMESPACE`.

The workflow automatically creates a private, versioned state bucket on its first infrastructure run.

## Part 2 — Prepare GitHub

### 5. Create the repository

Create a new repository, preferably named:

```text
nitu-whatsapp-gateway
```

The repository may be public or private. The generated **GHCR container package must be public** for this zero-credential server-pull design. The application source contains no account secrets, and all deployment credentials remain in GitHub Secrets.

Upload the extracted contents of this package so that `README.md`, `Dockerfile`, `.github`, `infra`, `src` and `public` are at the repository root.

### 6. Create the production environment

Repository → **Settings** → **Environments** → **New environment**:

```text
production
```

Optionally require manual approval for deployment.

Create another environment for destructive runs:

```text
production-destroy
```

Require manual approval for this environment.

### 7. Generate gateway secrets

Use Oracle Cloud Shell from the mobile browser. Run the command three times:

```bash
openssl rand -hex 32
```

Store each separate result as:

- `GATEWAY_API_KEY`
- `GATEWAY_ADMIN_TOKEN`
- `GATEWAY_WEBHOOK_SECRET`

Do not reuse values.

### 8. Add GitHub environment secrets

Under the `production` environment, create:

| Secret | Value |
|---|---|
| `OCI_TENANCY_OCID` | Tenancy OCID |
| `OCI_USER_OCID` | Deployment user OCID |
| `OCI_FINGERPRINT` | API key fingerprint |
| `OCI_PRIVATE_KEY` | Entire PEM private-key text, including header and footer |
| `GATEWAY_API_KEY` | First generated random value |
| `GATEWAY_ADMIN_TOKEN` | Second generated random value |
| `GATEWAY_WEBHOOK_SECRET` | Third generated random value |

Add the same OCI and gateway secrets to `production-destroy` only when you intend to retain the destroy workflow.

### 9. Add GitHub environment variables

Under `production`, create:

| Variable | Example |
|---|---|
| `OCI_COMPARTMENT_OCID` | `ocid1.compartment.oc1..…` |
| `OCI_REGION` | `ap-mumbai-1` |
| `OCI_NAMESPACE` | Your Object Storage namespace |
| `OCI_TF_STATE_BUCKET` | `nitu-wa-terraform-state` |
| `GATEWAY_DOMAIN` | `wa.nitutravels.in` |
| `DEFAULT_COUNTRY_CODE` | `91` |
| `MEDIA_ALLOWED_HOSTS` | `nitutravels.in,www.nitutravels.in` |
| `AVAILABILITY_DOMAIN_INDEX` | `0` |
| `WEBHOOK_URL` | Leave empty until your website webhook is ready |

Use a state-bucket name that is unique within your Object Storage namespace. Copy the same environment variables to `production-destroy` if the destroy workflow will remain enabled.

## Part 3 — Build and provision

### 10. Build the container without provisioning

Repository → **Actions** → **Build and deploy to Oracle Cloud** → **Run workflow**.

Set:

```text
Create or update Oracle infrastructure: false
```

This creates the first GHCR package.

### 11. Make the GHCR package public

Open the repository's package page, then:

1. Open **Package settings**.
2. Change visibility to **Public**.
3. Confirm the change.

A public image lets the Oracle server pull updates without storing a GitHub token in Terraform state or on the VM.

### 12. Provision Oracle infrastructure

Run the same workflow again with:

```text
Create or update Oracle infrastructure: true
```

The workflow will:

- create or secure the Terraform state bucket
- validate Terraform
- create the VCN, subnet, gateway and security list
- create the A1 instance and reserved public IP
- install Docker from Docker's official repository
- launch Caddy and the gateway
- publish the public IP and dashboard URL in the workflow summary

### 13. Configure DNS

Create an `A` record:

| Field | Value |
|---|---|
| Name/Host | `wa` |
| Type | `A` |
| Value | Reserved public IP from the workflow summary |
| TTL | 300 or automatic |

Do not create a proxy/CDN record during first certificate issuance unless you know its TLS mode is compatible. A direct DNS record is easiest.

Caddy obtains HTTPS automatically after the DNS name resolves to the Oracle IP. Certificate issuance may fail until DNS propagation completes; Caddy retries automatically.

## Part 4 — Link WhatsApp

### 14. Open the dashboard

Open:

```text
https://wa.nitutravels.in/admin
```

Enter the exact `GATEWAY_ADMIN_TOKEN` saved in GitHub.

### 15. Generate the pairing code

1. Enter the full WhatsApp number without `+`, spaces or dashes.
2. Tap **Generate pairing code**.
3. On WhatsApp, open **Linked devices**.
4. Tap **Link a device**.
5. Choose **Link with phone number**.
6. Enter the displayed eight-character code.

The dashboard status should change to `ready`.

### 16. Send a test

Enter a recipient with country code and send a test message from the dashboard. Confirm that the message moves through `queued`, `sent`, `delivered` and, where available, `read`.

## Part 5 — Connect the Nitu Travels website

Use the PHP example in:

```text
examples/php/send_message.php
```

Keep `GATEWAY_API_KEY` on the website server only. Never place it in browser JavaScript.

Use a unique idempotency key for every logical alert, such as:

```text
duty:4821:driver:93:departure-reminder:1
```

This prevents repeated website requests from creating duplicate queued messages.

## Updates after deployment

Push code changes to `main`. GitHub builds a new `latest` image; the Oracle server checks every ten minutes and applies it automatically.

For a configuration or secret change, edit the `production` environment value and rerun the workflow with provisioning enabled. Terraform updates OCI instance metadata, and the server applies the change within approximately five minutes without SSH or instance replacement.

No SSH session or local computer is required for routine updates.
