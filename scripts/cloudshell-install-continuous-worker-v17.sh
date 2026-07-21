#!/usr/bin/env bash
set -Eeuo pipefail

# Compatibility entry point for the v17 Manage Nitu Travels continuous queue worker.
# It accepts either:
#   1) the complete worker URL, or
#   2) only the generated worker key.
#
# Examples:
#   bash scripts/cloudshell-install-continuous-worker-v17.sh \
#     'https://manage.nitutravels.in/whatsapp-dispatch-worker.php?key=FULL_KEY&limit=25&budget=45&source=oracle-continuous&worker_version=v17.0'
#
#   bash scripts/cloudshell-install-continuous-worker-v17.sh 'FULL_KEY'

INPUT="${1:-}"
[ -n "$INPUT" ] || {
  echo "Pass either the complete Oracle worker URL or only the generated worker key." >&2
  exit 2
}

case "$INPUT" in
  http://*|https://*) FULL_WORKER_URL="$INPUT" ;;
  *) FULL_WORKER_URL="https://manage.nitutravels.in/whatsapp-dispatch-worker.php?key=${INPUT}&limit=25&budget=45&source=oracle-continuous&worker_version=v17.0" ;;
esac

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec bash "$SCRIPT_DIR/cloudshell-patch-manage-queue-worker-v17.sh" "$FULL_WORKER_URL"
