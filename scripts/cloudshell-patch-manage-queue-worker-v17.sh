#!/usr/bin/env bash
set -Eeuo pipefail

# Run in Oracle Cloud Shell:
#   bash cloudshell-patch-manage-queue-worker-v17.sh \
#     'https://manage.nitutravels.in/whatsapp-dispatch-worker.php?key=FULL_KEY'

FULL_WORKER_URL="${1:-}"
ORACLE_HOST="${ORACLE_HOST:-137.23.58.166}"
ORACLE_USER="${ORACLE_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/nitu_waha_rsa3072}"
INSTALLER_URL="https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/main/scripts/install-manage-queue-worker-v17.sh"

[ -n "$FULL_WORKER_URL" ] || { echo 'Pass the complete worker URL copied from Admin -> WhatsApp delivery.' >&2; exit 2; }
[ -r "$SSH_KEY" ] || { echo "SSH key not found: $SSH_KEY" >&2; exit 2; }

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL "$INSTALLER_URL" -o "$tmp"
bash -n "$tmp"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$ORACLE_USER@$ORACLE_HOST" \
  "sudo bash -s -- '$FULL_WORKER_URL'" < "$tmp"