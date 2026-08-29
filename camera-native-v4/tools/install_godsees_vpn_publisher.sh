#!/usr/bin/env bash
set -Eeuo pipefail

SRC=${1:-$(cd "$(dirname "$0")/.." && pwd)}
ROOT=/opt/nitu-camera-v3
WORKER_DIR="$ROOT/godsees-worker"
PUBLISHER="$WORKER_DIR/godsees_vpn_publisher.py"
PUB_SERVICE=nitu-camera-godsees-vpn-publisher.service
WG_SERVICE=wg-quick@nitu360.service
WG_IF=nitu360
WG_PORT=51827
WG_NET=10.77.0.0/24
WG_SERVER=10.77.0.1/24
WG_CLIENT=10.77.0.2/32
SECRETS=/etc/nitu-camera/wireguard
WG_CONF=/etc/wireguard/${WG_IF}.conf
PUB_ENV=/etc/nitu-camera/godsees-vpn-publisher.env
PUB_STATUS=/run/nitu-camera-publisher/status.json
SYSCTL=/etc/sysctl.d/90-nitu-camera360-forward.conf
CLIENT_HOME=/home/nituadmin
CLIENT_CONF=$CLIENT_HOME/camera360-wireguard.conf
CLIENT_README=$CLIENT_HOME/camera360-wireguard-README.txt

[ "$(id -u)" -eq 0 ] || { echo "run as root/sudo" >&2; exit 2; }
[ -d "$ROOT" ] || { echo "Camera V3 missing: $ROOT" >&2; exit 2; }
[ -S /run/nitu-camera/godsees.sock ] || { echo "GodSees worker socket missing" >&2; exit 2; }
[ -f "$SRC/worker/godsees_vpn_publisher.py" ] || { echo "publisher source missing" >&2; exit 2; }
id nitu-camera >/dev/null 2>&1 || { echo "nitu-camera user missing" >&2; exit 2; }
id nituadmin >/dev/null 2>&1 || { echo "nituadmin user missing" >&2; exit 2; }

"$ROOT/venv/bin/python" "$SRC/worker/godsees_vpn_publisher.py" --self-test

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends wireguard-tools tcpdump iptables qrencode

LAN_IF=$(ip -4 route show default | awk 'NR==1{print $5}')
LAN_IP=$(ip -4 addr show dev "$LAN_IF" | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}')
[ -n "$LAN_IF" ] && [ -n "$LAN_IP" ] || { echo "Unable to determine Wipro LAN interface/address" >&2; exit 3; }

CAMERA_ID=$("$ROOT/venv/bin/python" - <<'PY'
import json,re
from pathlib import Path
p=Path('/opt/nitu-camera-v3/config/cameras.json')
data=json.loads(p.read_text())
for c in data.get('cameras',[]):
    if str(c.get('vendor','')).lower() == 'camera360':
        cid=str(c.get('id') or '').strip()
        if not re.fullmatch(r'[A-Za-z0-9_.:-]+', cid):
            raise SystemExit('camera360 id contains unsupported characters')
        print(cid)
        break
else:
    raise SystemExit('camera360 entry missing from cameras.json')
PY
)
[ -n "$CAMERA_ID" ] || { echo "Camera360 id not found" >&2; exit 3; }

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP="$ROOT/backups/godsees-vpn-publisher-$STAMP"
install -d -m 0700 "$BACKUP"
for f in "$PUBLISHER" "/etc/systemd/system/$PUB_SERVICE" "$WG_CONF" "$PUB_ENV" "$SYSCTL"; do
  [ -f "$f" ] && cp -a "$f" "$BACKUP/$(basename "$f")" || true
done

install -d -m 0755 -o nitu-camera -g nitu-camera "$WORKER_DIR"
install -m 0644 -o nitu-camera -g nitu-camera "$SRC/worker/godsees_vpn_publisher.py" "$PUBLISHER"
"$ROOT/venv/bin/python" -m py_compile "$PUBLISHER"

umask 077
install -d -m 0700 "$SECRETS" /etc/wireguard
if [ ! -s "$SECRETS/server.key" ]; then wg genkey > "$SECRETS/server.key"; fi
if [ ! -s "$SECRETS/server.pub" ]; then wg pubkey < "$SECRETS/server.key" > "$SECRETS/server.pub"; fi
if [ ! -s "$SECRETS/client.key" ]; then wg genkey > "$SECRETS/client.key"; fi
if [ ! -s "$SECRETS/client.pub" ]; then wg pubkey < "$SECRETS/client.key" > "$SECRETS/client.pub"; fi
chmod 0600 "$SECRETS"/*.key "$SECRETS"/*.pub

SERVER_PRIV=$(cat "$SECRETS/server.key")
SERVER_PUB=$(cat "$SECRETS/server.pub")
CLIENT_PRIV=$(cat "$SECRETS/client.key")
CLIENT_PUB=$(cat "$SECRETS/client.pub")

cat > "$WG_CONF" <<EOF
[Interface]
Address = $WG_SERVER
ListenPort = $WG_PORT
PrivateKey = $SERVER_PRIV
PostUp = /usr/sbin/iptables -I INPUT 1 -i $LAN_IF -p udp --dport $WG_PORT -j ACCEPT; /usr/sbin/iptables -I FORWARD 1 -i $WG_IF -j ACCEPT; /usr/sbin/iptables -I FORWARD 1 -o $WG_IF -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; /usr/sbin/iptables -t nat -I POSTROUTING 1 -s $WG_NET -o $LAN_IF -j MASQUERADE
PostDown = /usr/sbin/iptables -D INPUT -i $LAN_IF -p udp --dport $WG_PORT -j ACCEPT || true; /usr/sbin/iptables -D FORWARD -i $WG_IF -j ACCEPT || true; /usr/sbin/iptables -D FORWARD -o $WG_IF -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || true; /usr/sbin/iptables -t nat -D POSTROUTING -s $WG_NET -o $LAN_IF -j MASQUERADE || true

[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = $WG_CLIENT
EOF
chmod 0600 "$WG_CONF"

cat > "$SYSCTL" <<'EOF'
# Dedicated Camera360 Android publisher path through Wipro.
net.ipv4.ip_forward=1
EOF
chmod 0644 "$SYSCTL"
sysctl --system >/dev/null

cat > "$CLIENT_CONF" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIV
Address = $WG_CLIENT
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $LAN_IP:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
chown nituadmin:nituadmin "$CLIENT_CONF"
chmod 0600 "$CLIENT_CONF"

cat > "$CLIENT_README" <<EOF
Nitu Camera360 authorized publisher
===================================

1. Import camera360-wireguard.conf into the Android WireGuard app.
2. Enable the tunnel while the phone is on the same LAN as Wipro ($LAN_IP).
3. Open the legitimate Camera360 app and start the camera live view normally.
4. Wipro observes only FastConnect UDP media records from that authorized session
   and publishes them to the local GodSees worker. HTTPS credentials are not read.
5. Disable the tunnel when Camera360 publishing is not required.

Wipro endpoint: $LAN_IP:$WG_PORT
Server interface: $WG_IF ($WG_SERVER)
Camera mapping: $CAMERA_ID
EOF
chown nituadmin:nituadmin "$CLIENT_README"
chmod 0600 "$CLIENT_README"
qrencode -t PNG -o "$CLIENT_HOME/camera360-wireguard.png" < "$CLIENT_CONF"
chown nituadmin:nituadmin "$CLIENT_HOME/camera360-wireguard.png"
chmod 0600 "$CLIENT_HOME/camera360-wireguard.png"

install -d -m 0750 -o root -g nitu-camera /etc/nitu-camera
cat > "$PUB_ENV" <<EOF
GODSEES_CAMERA_ID=$CAMERA_ID
GODSEES_VPN_INTERFACE=$WG_IF
GODSEES_SOCKET=/run/nitu-camera/godsees.sock
GODSEES_PUBLISHER_STATUS=$PUB_STATUS
EOF
chown root:nitu-camera "$PUB_ENV"
chmod 0640 "$PUB_ENV"

cat > "/etc/systemd/system/$PUB_SERVICE" <<'EOF'
[Unit]
Description=Nitu Camera360 authorized FastConnect VPN publisher
Requires=nitu-camera-godsees.service wg-quick@nitu360.service
After=nitu-camera-godsees.service wg-quick@nitu360.service network-online.target

[Service]
Type=simple
User=nitu-camera
Group=nitu-camera
Environment=PYTHONDONTWRITEBYTECODE=1
EnvironmentFile=/etc/nitu-camera/godsees-vpn-publisher.env
RuntimeDirectory=nitu-camera-publisher
RuntimeDirectoryMode=0755
ExecStart=/opt/nitu-camera-v3/venv/bin/python /opt/nitu-camera-v3/godsees-worker/godsees_vpn_publisher.py --camera-id ${GODSEES_CAMERA_ID} --interface ${GODSEES_VPN_INTERFACE} --worker-socket ${GODSEES_SOCKET}
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictRealtime=true
CapabilityBoundingSet=CAP_NET_RAW
AmbientCapabilities=CAP_NET_RAW
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_PACKET
ReadWritePaths=/run/nitu-camera-publisher
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF
chown root:root "/etc/systemd/system/$PUB_SERVICE"
chmod 0644 "/etc/systemd/system/$PUB_SERVICE"

systemctl daemon-reload
systemctl enable --now "$WG_SERVICE"
sleep 1
ip link show "$WG_IF" >/dev/null
wg show "$WG_IF" >/dev/null
rm -f "$PUB_STATUS"
systemctl enable --now "$PUB_SERVICE"
systemctl restart "$PUB_SERVICE"
sleep 2
systemctl is-active --quiet "$WG_SERVICE"
systemctl is-active --quiet "$PUB_SERVICE"
systemctl is-active --quiet nitu-camera-godsees.service
systemctl is-active --quiet nitu-camera-gateway.service
[ -S /run/nitu-camera/godsees.sock ]

printf '%s\n' \
  "Camera360 authorized VPN publisher installed." \
  "WireGuard endpoint: $LAN_IP:$WG_PORT" \
  "Android profile: $CLIENT_CONF" \
  "Android instructions: $CLIENT_README" \
  "Publisher service: $PUB_SERVICE" \
  "Publisher identity: nitu-camera + CAP_NET_RAW only" \
  "Camera mapping: $CAMERA_ID" \
  "Security: no Camera360 account password, business token, AK or SK is stored by this publisher." \
  "Activation: import/enable the Android WireGuard profile, then open the legitimate Camera360 live view." \
  "Backup: $BACKUP"
