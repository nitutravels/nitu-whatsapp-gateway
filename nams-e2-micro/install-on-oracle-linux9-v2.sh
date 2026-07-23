#!/usr/bin/env bash
set -Eeuo pipefail

BASE_INSTALLER_REF="898a4a5232e8b5e6e07f9807fc999937f055bde9"
BASE_INSTALLER_URL="https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/${BASE_INSTALLER_REF}/nams-e2-micro/install-on-oracle-linux9.sh"
TMP="$(mktemp /tmp/nams-e2-installer.XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT

curl -fL --retry 6 --retry-delay 3 --connect-timeout 20 "$BASE_INSTALLER_URL" -o "$TMP"
chmod 700 "$TMP"

sed -i 's|probe(){ curl -fsS --connect-timeout 5 --max-time 20 -H "X-NAMS-Probe: $TOKEN" "$1"; }|probe(){ local url="$1"; shift; curl -fsS --connect-timeout 5 --max-time "${PROBE_TIMEOUT:-20}" -H "X-NAMS-Probe: $TOKEN" "$@" "$url"; }|' "$TMP"
sed -i 's|^  probe http://127.0.0.1/_probe/ollama/api/generate \\|  PROBE_TIMEOUT=600 probe http://127.0.0.1/_probe/ollama/api/generate \\|' "$TMP"

grep -q 'local url="$1"; shift' "$TMP"
grep -q 'PROBE_TIMEOUT=600 probe http://127.0.0.1/_probe/ollama/api/generate' "$TMP"

exec env \
  NAMS_DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}" \
  ADMIN_TOKEN="${ADMIN_TOKEN:-}" \
  NAMS_E2_RELEASE_REF="${NAMS_E2_RELEASE_REF:-main}" \
  NAMS_SOURCE_REF="${NAMS_SOURCE_REF:-c74d8660d516e9330a9ad4f24742b10c43c487c4}" \
  OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5:0.5b-instruct}" \
  bash "$TMP" "$@"
