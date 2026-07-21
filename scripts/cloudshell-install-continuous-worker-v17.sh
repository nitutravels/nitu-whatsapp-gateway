#!/usr/bin/env bash
set -Eeuo pipefail

# Compatibility entry point for the v17 Manage Nitu Travels continuous queue worker.
# Run from Oracle Cloud Shell:
#   bash scripts/cloudshell-install-continuous-worker-v17.sh \
#     'https://manage.nitutravels.in/whatsapp-dispatch-worker.php?key=FULL_KEY&limit=25&budget=45&source=oracle-continuous&worker_version=v17.0'

FULL_WORKER_URL="${1:-}"
[ -n "$FULL_WORKER_URL" ] || {
  echo "Pass the complete Oracle worker URL as one quoted argument." >&2
  exit 2
}

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec bash "$SCRIPT_DIR/cloudshell-patch-manage-queue-worker-v17.sh" "$FULL_WORKER_URL"
