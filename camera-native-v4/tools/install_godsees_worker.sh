#!/usr/bin/env bash
set -Eeuo pipefail

SRC=${1:-$(cd "$(dirname "$0")/.." && pwd)}
ROOT=/opt/nitu-camera-v3
WORKER_DIR="$ROOT/godsees-worker"
SERVICE=nitu-camera-godsees.service
UNIT=/etc/systemd/system/$SERVICE
ENV_DIR=/etc/nitu-camera
ENV_FILE="$ENV_DIR/godsees-worker.env"

[ "$(id -u)" -eq 0 ] || { echo "run as root/sudo" >&2; exit 2; }
[ -d "$ROOT" ] || { echo "V3 not installed at $ROOT" >&2; exit 2; }
[ -x "$ROOT/venv/bin/python" ] || { echo "V3 Python venv missing" >&2; exit 2; }
id nitu-camera >/dev/null 2>&1 || { echo "nitu-camera service user missing" >&2; exit 2; }
[ -f "$SRC/worker/godsees_worker.py" ] || { echo "worker source missing" >&2; exit 2; }
[ -f "$SRC/tools/selftest_godsees_worker.py" ] || { echo "worker self-test missing" >&2; exit 2; }

"$ROOT/venv/bin/python" "$SRC/tools/selftest_godsees_worker.py"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP="$ROOT/backups/godsees-worker-$STAMP"
install -d -m 0700 "$BACKUP"
[ -f "$WORKER_DIR/godsees_worker.py" ] && cp -a "$WORKER_DIR/godsees_worker.py" "$BACKUP/" || true
[ -f "$UNIT" ] && cp -a "$UNIT" "$BACKUP/" || true

install -d -m 0755 -o nitu-camera -g nitu-camera "$WORKER_DIR"
install -m 0644 -o nitu-camera -g nitu-camera "$SRC/worker/godsees_worker.py" "$WORKER_DIR/godsees_worker.py"
"$ROOT/venv/bin/python" -m py_compile "$WORKER_DIR/godsees_worker.py"

install -d -m 0750 -o root -g nitu-camera "$ENV_DIR"
if [ ! -f "$ENV_FILE" ]; then
  cat >"$ENV_FILE" <<'EOF'
# Optional official 360/QHVCNetGodSees bridge.
# The current official GodSees viewer SDK is Android/iOS; Wipro Debian uses this
# local worker boundary and can proxy to an authorized SDK bridge when provided.
#
# Unix example:
# GODSEES_OFFICIAL_BRIDGE_UNIX=/run/nitu-camera/godsees-official-bridge.sock
#
# Loopback TCP example:
# GODSEES_OFFICIAL_BRIDGE_TCP=127.0.0.1:38991
# GODSEES_OFFICIAL_BRIDGE_TOKEN_FILE=/etc/nitu-camera/godsees-bridge.token
EOF
  chown root:nitu-camera "$ENV_FILE"
  chmod 0640 "$ENV_FILE"
fi

cat >"$UNIT" <<'EOF'
[Unit]
Description=Nitu Camera authorized 360 FastConnect/GodSees worker
After=network-online.target
Wants=network-online.target
Before=nitu-camera-gateway.service

[Service]
Type=simple
User=nitu-camera
Group=nitu-camera
Environment=PYTHONDONTWRITEBYTECODE=1
EnvironmentFile=-/etc/nitu-camera/godsees-worker.env
RuntimeDirectory=nitu-camera
RuntimeDirectoryMode=0750
ExecStart=/opt/nitu-camera-v3/venv/bin/python /opt/nitu-camera-v3/godsees-worker/godsees_worker.py --serve --socket /run/nitu-camera/godsees.sock
Restart=on-failure
RestartSec=2
UMask=0007
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictRealtime=true
CapabilityBoundingSet=
AmbientCapabilities=
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=/run/nitu-camera

[Install]
WantedBy=multi-user.target
EOF
chown root:root "$UNIT"
chmod 0644 "$UNIT"

systemctl daemon-reload
systemctl enable --now "$SERVICE"

for _ in $(seq 1 40); do
  if [ -S /run/nitu-camera/godsees.sock ]; then
    break
  fi
  sleep 0.25
done
[ -S /run/nitu-camera/godsees.sock ] || {
  systemctl status "$SERVICE" --no-pager || true
  journalctl -u "$SERVICE" -n 80 --no-pager || true
  echo "GodSees worker socket was not created" >&2
  exit 70
}

"$ROOT/venv/bin/python" "$WORKER_DIR/godsees_worker.py" --health --socket /run/nitu-camera/godsees.sock
systemctl is-active --quiet "$SERVICE"

# The existing V4 gateway does not retry a plugin that failed before the socket
# existed, so restart it once after the worker is healthy.
systemctl restart nitu-camera-gateway.service
sleep 2
systemctl is-active --quiet nitu-camera-gateway.service
command -v nitu-camera >/dev/null 2>&1 && nitu-camera health

printf '%s\n' \
  "GodSees authorized worker installed." \
  "Socket: /run/nitu-camera/godsees.sock" \
  "Service: $SERVICE" \
  "Security: local Unix socket, nitu-camera service account, fail-closed live authorization." \
  "Official SDK bridge: not configured unless GODSEES_OFFICIAL_BRIDGE_* is set." \
  "Backup: $BACKUP"
