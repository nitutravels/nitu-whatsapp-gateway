#!/usr/bin/env bash
set -Eeuo pipefail
for name in GATEWAY_API_KEY GATEWAY_ADMIN_TOKEN GATEWAY_WEBHOOK_SECRET; do
  printf '%s=' "$name"
  openssl rand -hex 32
 done
