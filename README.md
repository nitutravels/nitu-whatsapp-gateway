# Nitu Travels WhatsApp Gateway

Oracle-hosted WhatsApp infrastructure and operational tooling for Manage Nitu Travels.

> **Important:** The active WAHA/linked-device integration is unofficial and is not Meta's official WhatsApp Business Platform. Use a dedicated business number, message only recipients with a legitimate operational relationship or consent, honour opt-outs, and avoid unsolicited bulk messaging.

## Current production architecture

```text
Manage Nitu Travels (BigRock PHP + MySQL outbox)
                |
                | authenticated HTTPS queue-worker call
                v
Oracle continuous worker (systemd or compose, every 10 seconds)
                |
                | website claims due rows and calls WAHA sendText
                v
WAHA Core NOWEB at wa.nitutravels.in
                |
                v
WhatsApp linked device

WAHA signed acknowledgements -> Manage Nitu Travels webhook
BigRock 15-minute cron        -> bounded 50-message fallback batch
```

A WAHA session reporting `WORKING` is ready to send, but WAHA does not pull rows from the website's MySQL outbox. The Oracle worker is therefore a required part of the production delivery path.

## v17 queue-worker fix

The v17 worker release replaces the retired one-minute systemd timer with a continuously running service:

- polls every 10 seconds by default;
- requests up to 25 rows per pass;
- uses a 45-second bounded website processing budget;
- restarts automatically through systemd;
- stores the worker key in a root-only environment file;
- records the latest website response and systemd journal;
- disables the old minute timer to avoid duplicate invocations;
- leaves BigRock's 15-minute cron as a 50-message batch fallback.

The matching Manage Nitu Travels v17 website package changes a successful WAHA response containing a provider message ID to `Successfully sent` immediately. It disappears from the Pending view while the audit row remains available for later delivery/read acknowledgement updates.

## Install or patch the Oracle worker

First open Manage Nitu Travels:

```text
Admin -> Settings & Integrations -> WhatsApp
```

Generate/save the worker key and copy the complete Oracle worker URL.

### Directly on the Oracle VM

```bash
curl -fsSL \
  https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/main/scripts/install-manage-queue-worker-v17.sh \
  -o /tmp/install-manage-queue-worker-v17.sh
sudo bash /tmp/install-manage-queue-worker-v17.sh \
  'PASTE_COMPLETE_ORACLE_WORKER_URL'
```

### From Oracle Cloud Shell

```bash
curl -fsSL \
  https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/main/scripts/cloudshell-patch-manage-queue-worker-v17.sh \
  -o /tmp/cloudshell-patch-manage-queue-worker-v17.sh
bash /tmp/cloudshell-patch-manage-queue-worker-v17.sh \
  'PASTE_COMPLETE_ORACLE_WORKER_URL'
```

Cloud Shell defaults:

- Oracle host: `137.23.58.166`
- SSH user: `ubuntu`
- SSH key: `~/.ssh/nitu_waha_rsa3072`

Use `ORACLE_HOST`, `ORACLE_USER`, or `SSH_KEY` to override those defaults.

## Verify

```bash
sudo systemctl status nitu-whatsapp-continuous-worker.service
sudo journalctl -u nitu-whatsapp-continuous-worker.service -f
sudo cat /var/log/nitu-travels/whatsapp-worker-last-status.txt
sudo cat /var/log/nitu-travels/whatsapp-worker-last-response.json
```

The website should show `Oracle worker ONLINE` within 30 seconds. A queued test should increment its attempt count, leave Pending after WAHA acceptance, and appear under Successfully sent.

## Diagnose

```bash
curl -fsSL \
  https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/main/scripts/diagnose-manage-queue-worker-v17.sh \
  -o /tmp/diagnose-manage-queue-worker-v17.sh
sudo bash /tmp/diagnose-manage-queue-worker-v17.sh
```

## Worker files

- [`scripts/install-manage-queue-worker-v17.sh`](scripts/install-manage-queue-worker-v17.sh) — direct Oracle systemd installer/update
- [`scripts/cloudshell-patch-manage-queue-worker-v17.sh`](scripts/cloudshell-patch-manage-queue-worker-v17.sh) — Cloud Shell SSH wrapper
- [`scripts/diagnose-manage-queue-worker-v17.sh`](scripts/diagnose-manage-queue-worker-v17.sh) — worker, response and WAHA diagnostics
- [`docs/MANAGE_QUEUE_WORKER_V17.md`](docs/MANAGE_QUEUE_WORKER_V17.md) — complete operating procedure

## Existing repository components

The repository also retains the earlier custom linked-device gateway, Terraform, GitHub Actions, API examples and migration history. Those files are preserved for audit and disaster-recovery reference. The current Manage Nitu Travels production path uses WAHA Core NOWEB plus the v17 continuous queue worker unless a controlled migration explicitly selects another engine.

## Operating rules

- Run one primary continuous worker: systemd **or** a compose dispatcher sidecar, not both permanently.
- Keep only one BigRock 15-minute fallback cron entry.
- Do not delete sent outbox history merely to reduce the pending counter.
- Use a dedicated business number and conservative message rates.
- Protect the WAHA API key, website worker key and webhook secret independently.
- Verify backups before changing the WAHA session or Oracle instance.

## Licence

MIT for repository code. WhatsApp, WAHA and Oracle trademarks belong to their respective owners.