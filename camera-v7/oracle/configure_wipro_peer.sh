#!/usr/bin/env bash
set -Eeuo pipefail

IFACE=nitu-camera-v7
CONF=/etc/wireguard/nitu-camera-v7.conf
KEY=/etc/wireguard/nitu-camera-v7.key
WIPRO_ADDR=10.89.0.2/32
PUBKEY="${1:-}"

[ "$(id -u)" -eq 0 ] || { echo 'run as root' >&2; exit 2; }
[ -s "$KEY" ] || { echo 'relay key missing' >&2; exit 2; }
[ -n "$PUBKEY" ] || { echo 'Wipro public key argument required' >&2; exit 64; }
[ "${#PUBKEY}" -eq 44 ] || { echo 'invalid WireGuard public key length' >&2; exit 64; }

if ! printf '%s\n' "$PUBKEY" | base64 -d >/dev/null 2>&1; then
  echo 'invalid WireGuard public key encoding' >&2
  exit 64
fi

PRIVATE_KEY=$(cat "$KEY")
cat > "$CONF" <<EOF
[Interface]
Address = 10.89.0.1/24
ListenPort = 51829
PrivateKey = $PRIVATE_KEY
PostUp = /usr/local/sbin/nitu-camera-v7-firewall up
PreDown = /usr/local/sbin/nitu-camera-v7-firewall down

[Peer]
PublicKey = $PUBKEY
AllowedIPs = $WIPRO_ADDR
EOF
chmod 0600 "$CONF"

if ip link show "$IFACE" >/dev/null 2>&1; then
  wg set "$IFACE" peer "$PUBKEY" allowed-ips "$WIPRO_ADDR"
else
  systemctl enable --now "wg-quick@$IFACE.service"
fi
systemctl restart "wg-quick@$IFACE.service"
sleep 2
systemctl is-active --quiet "wg-quick@$IFACE.service"
wg show "$IFACE" peers | grep -Fx "$PUBKEY" >/dev/null

echo "NITU_CAMERA_V7_WIPRO_PEER_CONFIG_PASS"
echo "wipro_public_key=$PUBKEY"
wg show "$IFACE" latest-handshakes
