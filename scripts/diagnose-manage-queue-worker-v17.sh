#!/usr/bin/env bash
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || { echo 'Run with sudo.' >&2; exit 1; }

echo '=== HOST ==='
date -Is
hostnamectl 2>/dev/null || hostname

echo '=== CONTINUOUS MANAGE QUEUE WORKER ==='
systemctl --no-pager --full status nitu-whatsapp-continuous-worker.service || true
systemctl is-enabled nitu-whatsapp-continuous-worker.service || true
systemctl is-active nitu-whatsapp-continuous-worker.service || true

echo '=== OLD MINUTE TIMER (SHOULD BE ABSENT/INACTIVE) ==='
systemctl is-enabled nitu-whatsapp-worker.timer 2>/dev/null || true
systemctl is-active nitu-whatsapp-worker.timer 2>/dev/null || true

echo '=== LAST WEBSITE RESPONSE ==='
cat /var/log/nitu-travels/whatsapp-worker-last-status.txt 2>/dev/null || true
python3 -m json.tool /var/log/nitu-travels/whatsapp-worker-last-response.json 2>/dev/null || cat /var/log/nitu-travels/whatsapp-worker-last-response.json 2>/dev/null || true

echo '=== RECENT WORKER JOURNAL ==='
journalctl -u nitu-whatsapp-continuous-worker.service --since '-30 minutes' --no-pager -n 250 || true

echo '=== WAHA STACK ==='
if [ -d /opt/nitu-waha ]; then
  cd /opt/nitu-waha
  docker compose ps || true
  docker compose logs --tail=120 waha caddy dispatcher 2>/dev/null || docker compose logs --tail=120 || true
else
  echo '/opt/nitu-waha was not found. Locate the active WAHA compose directory manually.'
fi