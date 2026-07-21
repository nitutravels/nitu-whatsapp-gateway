#!/usr/bin/env bash
set -Eeuo pipefail

# Compatibility entry point for the v17 Manage Nitu Travels continuous queue worker.
# It accepts either:
#   1) the complete worker URL,
#   2) only the generated worker key, or
#   3) no argument, in which case it prompts for the worker key.

INPUT="${1:-}"
if [ -z "$INPUT" ]; then
  printf 'Paste the NEW worker key only, then press Enter: '
  IFS= read -r INPUT
fi

INPUT="${INPUT//$'\r'/}"
INPUT="${INPUT//$'\n'/}"
[ -n "$INPUT" ] || {
  echo "No worker key or URL was provided." >&2
  exit 2
}

case "$INPUT" in
  http://*|https://*) FULL_WORKER_URL="$INPUT" ;;
  *'&'*|*' '*|*'?'*)
    echo "Paste only the generated key, without key=, &, spaces, or quotation marks." >&2
    exit 2
    ;;
  *) FULL_WORKER_URL="https://manage.nitutravels.in/whatsapp-dispatch-worker.php?key=${INPUT}&limit=25&budget=45&source=oracle-continuous&worker_version=v17.0" ;;
esac

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec bash "$SCRIPT_DIR/cloudshell-patch-manage-queue-worker-v17.sh" "$FULL_WORKER_URL"
