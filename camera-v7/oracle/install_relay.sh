#!/usr/bin/env bash
set -Eeuo pipefail

IFACE=nitu-camera-v7
WG_PORT=51829
PHONE_PORT=51828
WG_ADDR=10.89.0.1/24
WIPRO_ADDR=10.89.0.2
WIPRO_INNER_PORT=51827
KEY=/etc/wireguard/nitu-camera-v7.key
PUB=/etc/wireguard/nitu-camera-v7.pub
CONF=/etc/wireguard/nitu-camera-v7.conf
FW=/usr/local/sbin/nitu-camera-v7-firewall
SYSCTL=/etc/sysctl.d/90-nitu-camera-v7.conf

[ "$(id -u)" -eq 0 ] || { echo 'run as root' >&2; exit 2; }
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends wireguard-tools iptables ca-certificates

install -d -m 0700 /etc/wireguard
if [ ! -s "$KEY" ]; then
  umask 077
  wg genkey > "$KEY"
fi
chmod 0600 "$KEY"
wg pubkey < "$KEY" > "$PUB"
chmod 0644 "$PUB"

cat > "$SYSCTL" <<'EOF'
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null

cat > "$FW" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
IPT=/usr/sbin/iptables
IFACE=nitu-camera-v7
WG_PORT=51829
PHONE_PORT=51828
WIPRO_ADDR=10.89.0.2
WIPRO_INNER_PORT=51827
RELAY_ADDR=10.89.0.1

add_rule(){
  local table="$1"; shift
  if ! "$IPT" -w 10 -t "$table" -C "$@" 2>/dev/null; then
    "$IPT" -w 10 -t "$table" -I "$@"
  fi
}
del_rule(){
  local table="$1"; shift
  while "$IPT" -w 10 -t "$table" -C "$@" 2>/dev/null; do
    "$IPT" -w 10 -t "$table" -D "$@" || break
  done
}

case "${1:-}" in
  up)
    add_rule filter INPUT 1 -p udp --dport "$WG_PORT" -j ACCEPT
    add_rule nat PREROUTING 1 -p udp --dport "$PHONE_PORT" -j DNAT --to-destination "$WIPRO_ADDR:$WIPRO_INNER_PORT"
    add_rule nat POSTROUTING 1 -o "$IFACE" -p udp -d "$WIPRO_ADDR" --dport "$WIPRO_INNER_PORT" -j SNAT --to-source "$RELAY_ADDR"
    add_rule filter FORWARD 1 -p udp -d "$WIPRO_ADDR" --dport "$WIPRO_INNER_PORT" -j ACCEPT
    add_rule filter FORWARD 1 -p udp -s "$WIPRO_ADDR" --sport "$WIPRO_INNER_PORT" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ;;
  down)
    del_rule filter INPUT -p udp --dport "$WG_PORT" -j ACCEPT
    del_rule nat PREROUTING -p udp --dport "$PHONE_PORT" -j DNAT --to-destination "$WIPRO_ADDR:$WIPRO_INNER_PORT"
    del_rule nat POSTROUTING -o "$IFACE" -p udp -d "$WIPRO_ADDR" --dport "$WIPRO_INNER_PORT" -j SNAT --to-source "$RELAY_ADDR"
    del_rule filter FORWARD -p udp -d "$WIPRO_ADDR" --dport "$WIPRO_INNER_PORT" -j ACCEPT
    del_rule filter FORWARD -p udp -s "$WIPRO_ADDR" --sport "$WIPRO_INNER_PORT" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ;;
  *) echo "usage: $0 {up|down}" >&2; exit 64 ;;
esac
EOF
chmod 0755 "$FW"

PRIVATE_KEY=$(cat "$KEY")
cat > "$CONF" <<EOF
[Interface]
Address = $WG_ADDR
ListenPort = $WG_PORT
PrivateKey = $PRIVATE_KEY
PostUp = $FW up
PreDown = $FW down
EOF
chmod 0600 "$CONF"

systemctl daemon-reload
systemctl enable --now "wg-quick@$IFACE.service"
sleep 1
systemctl is-active --quiet "wg-quick@$IFACE.service"
[ "$(wg show "$IFACE" listen-port)" = "$WG_PORT" ]
ip link show "$IFACE" >/dev/null

PUBLIC_KEY=$(cat "$PUB")
echo "NITU_CAMERA_V7_RELAY_INSTALL_PASS"
echo "relay_interface=$IFACE"
echo "relay_wireguard_port=$WG_PORT"
echo "android_public_udp_port=$PHONE_PORT"
echo "relay_tunnel_ip=10.89.0.1"
echo "wipro_tunnel_ip=$WIPRO_ADDR"
echo "NITU_CAMERA_V7_RELAY_PUBLIC_KEY=$PUBLIC_KEY"
