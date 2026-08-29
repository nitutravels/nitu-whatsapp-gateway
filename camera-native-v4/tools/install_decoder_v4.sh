#!/usr/bin/env bash
set -Eeuo pipefail
SRC=${1:-$(cd "$(dirname "$0")/.." && pwd)}
ROOT=/opt/nitu-camera-v3
SERVICE=nitu-camera-gateway
[ "$(id -u)" -eq 0 ] || { echo "run as root/sudo" >&2; exit 2; }
[ -d "$ROOT" ] || { echo "V3 not installed at $ROOT" >&2; exit 2; }
[ -x "$ROOT/venv/bin/python" ] || { echo "V3 Python venv missing" >&2; exit 2; }
for f in \
  gateway/plugins/v380_native.py \
  gateway/plugins/camera360_godsees.py \
  gateway/adapters/v380.py \
  gateway/adapters/camera360.py; do
  [ -f "$SRC/$f" ] || { echo "upgrade file missing: $f" >&2; exit 2; }
done

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP="$ROOT/backups/decoder-v4-$STAMP"
install -d -m 0700 "$BACKUP/gateway/plugins" "$BACKUP/gateway/adapters"
for f in gateway/plugins/v380_native.py gateway/plugins/camera360_godsees.py gateway/adapters/v380.py gateway/adapters/camera360.py; do
  [ -f "$ROOT/$f" ] && cp -a "$ROOT/$f" "$BACKUP/$f" || true
done

rollback(){
  echo "Decoder V4 install failed; rolling back" >&2
  for f in gateway/plugins/v380_native.py gateway/plugins/camera360_godsees.py gateway/adapters/v380.py gateway/adapters/camera360.py; do
    if [ -f "$BACKUP/$f" ]; then cp -a "$BACKUP/$f" "$ROOT/$f"; else rm -f "$ROOT/$f"; fi
  done
  systemctl restart "$SERVICE" || true
}
trap 'rc=$?; if [ $rc -ne 0 ]; then rollback; fi; exit $rc' EXIT

install -d -m 0755 "$ROOT/gateway/plugins" "$ROOT/gateway/adapters"
install -m 0644 "$SRC/gateway/plugins/v380_native.py" "$ROOT/gateway/plugins/v380_native.py"
install -m 0644 "$SRC/gateway/plugins/camera360_godsees.py" "$ROOT/gateway/plugins/camera360_godsees.py"
install -m 0644 "$SRC/gateway/adapters/v380.py" "$ROOT/gateway/adapters/v380.py"
install -m 0644 "$SRC/gateway/adapters/camera360.py" "$ROOT/gateway/adapters/camera360.py"
chown nitu-camera:nitu-camera "$ROOT/gateway/plugins/v380_native.py" "$ROOT/gateway/plugins/camera360_godsees.py" "$ROOT/gateway/adapters/v380.py" "$ROOT/gateway/adapters/camera360.py" 2>/dev/null || true

"$ROOT/venv/bin/python" -m py_compile \
  "$ROOT/gateway/plugins/v380_native.py" \
  "$ROOT/gateway/plugins/camera360_godsees.py" \
  "$ROOT/gateway/adapters/v380.py" \
  "$ROOT/gateway/adapters/camera360.py"

systemctl restart "$SERVICE"
sleep 3
systemctl is-active --quiet "$SERVICE"
if command -v nitu-camera >/dev/null 2>&1; then nitu-camera health; fi
trap - EXIT
printf '%s\n' "Decoder V4 installed successfully." "Backup: $BACKUP" "V380: native TCP/8800 decoder enabled." "360: GodSees SDK worker boundary enabled; vendor SDK worker must be present at /run/nitu-camera/godsees.sock for real 360 video."
