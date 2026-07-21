# Manage Nitu Travels queue worker v17

The WAHA session and the Manage Nitu Travels outbox are separate components. A WAHA session in `WORKING` state is ready to send, but it does not pull rows from the website database by itself. The Oracle worker must call the website's authenticated dispatch endpoint.

## v17 operating model

- Oracle is the primary continuous worker.
- Default polling interval: 10 seconds.
- Default website batch: 25 messages.
- Default PHP time budget: 45 seconds.
- BigRock's 15-minute cron remains a 50-message bounded fallback.
- The website uses a lock so overlapping invocations cannot dispatch the same claimed row concurrently.
- When WAHA returns a provider message ID, the website marks the row `sent` immediately. It leaves the pending queue and remains in `Successfully sent` history.
- Signed WAHA acknowledgements can later promote `sent` to `delivered` or `read`.

## Install on the existing Oracle VM

In Manage Nitu Travels, open Admin → Settings & Integrations → WhatsApp, generate/save the worker key, and copy the complete Oracle worker URL.

Then run on the Oracle VM:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/main/scripts/install-manage-queue-worker-v17.sh \
  -o /tmp/install-manage-queue-worker-v17.sh
sudo bash /tmp/install-manage-queue-worker-v17.sh \
  'PASTE_COMPLETE_ORACLE_WORKER_URL'
```

The installer disables the retired one-minute systemd timer, installs a continuously running service, stores the key in a root-only environment file, enables automatic restart, and records the last website response under `/var/log/nitu-travels`.

## Install from Oracle Cloud Shell

```bash
curl -fsSL \
  https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/main/scripts/cloudshell-patch-manage-queue-worker-v17.sh \
  -o /tmp/cloudshell-patch-manage-queue-worker-v17.sh
bash /tmp/cloudshell-patch-manage-queue-worker-v17.sh \
  'PASTE_COMPLETE_ORACLE_WORKER_URL'
```

Defaults used by the Cloud Shell wrapper:

- host: `137.23.58.166`
- user: `ubuntu`
- SSH key: `~/.ssh/nitu_waha_rsa3072`

Override those through `ORACLE_HOST`, `ORACLE_USER`, or `SSH_KEY` when necessary.

## Verify

```bash
sudo systemctl status nitu-whatsapp-continuous-worker.service
sudo journalctl -u nitu-whatsapp-continuous-worker.service -f
sudo cat /var/log/nitu-travels/whatsapp-worker-last-status.txt
sudo cat /var/log/nitu-travels/whatsapp-worker-last-response.json
```

The website should show `Oracle worker ONLINE` within 30 seconds. A queued test should increment attempts, disappear from Pending after WAHA acceptance, and appear under Successfully sent.

## Diagnose

```bash
curl -fsSL \
  https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/main/scripts/diagnose-manage-queue-worker-v17.sh \
  -o /tmp/diagnose-manage-queue-worker-v17.sh
sudo bash /tmp/diagnose-manage-queue-worker-v17.sh
```

## Avoid duplicate primaries

Use either the systemd continuous worker or a Docker Compose dispatcher sidecar as the primary worker, not both. The website lock prevents concurrent queue ownership, but a single primary worker is easier to observe and maintain.