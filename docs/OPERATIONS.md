# Operations guide

## Service behaviour

The Oracle instance runs two containers:

- `nitu-wa-gateway`
- `nitu-wa-caddy`

Persistent state is stored on the host under:

```text
/opt/nitu-wa/data
```

Local backups are stored under:

```text
/opt/nitu-wa/backups
```

The containers restart automatically after VM reboots or process failure.

## Updates

Every push to `main` builds an Arm64/AMD64 image tagged `latest` and with the Git commit SHA.

The VM's `nitu-wa-update.timer` runs every ten minutes:

```text
docker compose pull
docker compose up -d --remove-orphans
```

Persistent authentication and queue data are not replaced. Configuration is independently synchronized every five minutes by `nitu-wa-config-sync.timer`.

## Health monitoring

Use:

```text
https://YOUR_DOMAIN/healthz
```

for process health, and:

```text
https://YOUR_DOMAIN/readyz
```

for linked-session readiness.

A practical monitor should alert only after multiple consecutive failures to avoid false alarms during an image update.

## Dashboard

The dashboard shows:

- linked-session status
- linked account identifier
- queue and failure counts
- pairing code or QR when not linked
- recent outgoing messages
- test-message control
- unlink control

The administrator token is stored in the phone browser's local storage after login. Use a locked phone and remove the token with **Forget token** on shared devices.

## Backups

At 02:30 UTC daily:

- SQLite's online `.backup` command creates a consistent database copy.
- The authentication directory is archived on a best-effort basis.
- Files older than seven days are deleted.

Local backup does not protect against complete boot-volume loss. For critical use, copy encrypted backups to another storage system.

## Recovery after container failure

The `restart: unless-stopped` policy restarts the process automatically. A message left in `sending` is recovered to `retry` after it has remained stuck for 15 minutes.

This can produce a rare duplicate if WhatsApp accepted the message but the process terminated before recording the provider message ID. Design business alerts so that an occasional duplicate is less harmful than a missed message.

## Recovery after session logout

1. Open the administrator dashboard.
2. Confirm status is `disconnected` or `auth_failure`.
3. Generate a new pairing code.
4. Link the device from WhatsApp.
5. Confirm `/readyz` returns HTTP 200.

Queued messages remain stored while the session is offline and resume after reconnection.

## Changing configuration

Update the GitHub `production` environment variable or secret, then manually run **Build and deploy to Oracle Cloud** with infrastructure provisioning enabled. Terraform updates the encrypted values stored in its state and the `gateway_env_b64` custom instance-metadata key. The root-owned `nitu-wa-config-sync.timer` checks that value every five minutes, validates it, atomically replaces `/opt/nitu-wa/.env`, and recreates the containers only when a value changed.

The Docker network is blocked from `169.254.169.254`, so application containers cannot read OCI instance metadata. Do not disable `nitu-wa-metadata-guard.service`.

Secret rotation does not erase older values from versioned Terraform state objects. Retain strict access to the private state bucket and follow the state-retention guidance before deleting old versions.

## Controlled destruction

The `Destroy Oracle deployment` workflow requires typing:

```text
DESTROY
```

and should be protected by the `production-destroy` environment approval.

The Terraform configuration sets `preserve_boot_volume = true`; infrastructure destruction intentionally retains the boot volume. Delete that volume manually only after confirming that the queue, session and backups are no longer required.

The Object Storage Terraform-state bucket is also retained because it is bootstrapped outside the Terraform state.
