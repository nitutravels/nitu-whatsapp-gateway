#!/usr/bin/env bash
set -Eeuo pipefail
exec > >(tee -a /var/log/nitu-camera-v7-cloudinit.log /dev/console) 2>&1
export DEBIAN_FRONTEND=noninteractive
WIPRO_PUBLIC_KEY="4x7fSYEdJpvpdnzIrj3dm/xky2e8Pcv/Yh1b/5Hh3Ro="
WG_IF="nitu-v7"
WG_PORT=51829
PHONE_PORT=51828
RELAY_IP="10.89.0.1/24"
WIPRO_IP="10.89.0.2"
INNER_WG_PORT=51827

for _ in $(seq 1 60); do
  if ! fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
apt-get update
apt-get install -y --no-install-recommends wireguard-tools iptables ca-certificates
install -d -m 0700 /etc/wireguard
KEY=/etc/wireguard/nitu-v7-relay.key
PUB=/etc/wireguard/nitu-v7-relay.pub
if [ ! -s "$KEY" ]; then
  umask 077
  wg genkey > "$KEY"
fi
chmod 0600 "$KEY"
wg pubkey < "$KEY" > "$PUB"
chmod 0644 "$PUB"
PRIVATE_KEY="$(cat "$KEY")"
PUBLIC_KEY="$(cat "$PUB")"
PUBLIC_IF="$(ip -4 route show default | awk '{print $5; exit}')"
[ -n "$PUBLIC_IF" ]

cat > "/etc/wireguard/${WG_IF}.conf" <<EOF
[Interface]
Address = ${RELAY_IP}
ListenPort = ${WG_PORT}
PrivateKey = ${PRIVATE_KEY}
PostUp = iptables -t nat -A PREROUTING -i ${PUBLIC_IF} -p udp --dport ${PHONE_PORT} -j DNAT --to-destination ${WIPRO_IP}:${INNER_WG_PORT}
PostUp = iptables -t nat -A POSTROUTING -o %i -p udp -d ${WIPRO_IP} --dport ${INNER_WG_PORT} -j SNAT --to-source 10.89.0.1
PostUp = iptables -A FORWARD -i ${PUBLIC_IF} -o %i -p udp -d ${WIPRO_IP} --dport ${INNER_WG_PORT} -j ACCEPT
PostUp = iptables -A FORWARD -i %i -o ${PUBLIC_IF} -p udp -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostDown = iptables -t nat -D PREROUTING -i ${PUBLIC_IF} -p udp --dport ${PHONE_PORT} -j DNAT --to-destination ${WIPRO_IP}:${INNER_WG_PORT}
PostDown = iptables -t nat -D POSTROUTING -o %i -p udp -d ${WIPRO_IP} --dport ${INNER_WG_PORT} -j SNAT --to-source 10.89.0.1
PostDown = iptables -D FORWARD -i ${PUBLIC_IF} -o %i -p udp -d ${WIPRO_IP} --dport ${INNER_WG_PORT} -j ACCEPT
PostDown = iptables -D FORWARD -i %i -o ${PUBLIC_IF} -p udp -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

[Peer]
PublicKey = ${WIPRO_PUBLIC_KEY}
AllowedIPs = ${WIPRO_IP}/32
EOF
chmod 0600 "/etc/wireguard/${WG_IF}.conf"

cat >/etc/sysctl.d/90-nitu-camera-v7.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null
systemctl enable --now "wg-quick@${WG_IF}.service"

ip link show "$WG_IF" >/dev/null
ip -4 addr show dev "$WG_IF" | grep -q '10.89.0.1/24'
wg show "$WG_IF" | grep -q 'listening port: 51829'
wg show "$WG_IF" | grep -Fq "$WIPRO_PUBLIC_KEY"
iptables -t nat -C PREROUTING -i "$PUBLIC_IF" -p udp --dport "$PHONE_PORT" -j DNAT --to-destination "$WIPRO_IP:$INNER_WG_PORT"

echo "CAMERA_V7_RELAY_PUBLIC_KEY=$PUBLIC_KEY"
echo "CAMERA_V7_RELAY_INTERFACE=$WG_IF"
echo "CAMERA_V7_RELAY_READY=1"
echo "CAMERA_V7_RELAY_PUBLIC_KEY=$PUBLIC_KEY" >/dev/console
echo "CAMERA_V7_RELAY_READY=1" >/dev/console
