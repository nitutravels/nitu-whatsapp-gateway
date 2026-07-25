#!/usr/bin/env bash
set -Eeuo pipefail

BASE_REF="f4cfd31916e268a3e8e6eaeee3c057dccab3833b"
BASE_URL="https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/${BASE_REF}/nams-e2-micro/cloudshell-delete-reinstall.sh"
TMP="$(mktemp /tmp/nams-delete-reinstall.XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT

curl -fL --retry 6 --retry-delay 3 --connect-timeout 20 "$BASE_URL" -o "$TMP"
chmod 700 "$TMP"
sed -i 's/case "$STATE" in ACCEPTED|IN_PROGRESS) ;;& \*) continue;; esac/case "$STATE" in ACCEPTED|IN_PROGRESS) ;; *) continue;; esac/' "$TMP"
grep -Fq 'case "$STATE" in ACCEPTED|IN_PROGRESS) ;; *) continue;; esac' "$TMP"

exec env \
  OCI_REGION="${OCI_REGION:-ap-mumbai-1}" \
  NAMS_INSTANCE_NAME="${NAMS_INSTANCE_NAME:-instance-20260723-2200}" \
  NAMS_EXPECTED_IP="${NAMS_EXPECTED_IP:-130.210.31.138}" \
  NAMS_DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}" \
  bash "$TMP" "$@"
