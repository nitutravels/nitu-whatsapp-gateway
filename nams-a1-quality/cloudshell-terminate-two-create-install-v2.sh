#!/usr/bin/env bash
set -Eeuo pipefail
BASE_REF="e977de2a59fdda744f68c307b6081a17dcce6460"
SUPPORT_REF="c76d001eafe91bc3a47a65f8f80d83a1258e27e4"
TMP="$(mktemp /tmp/nams-a1-controller.XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT
curl -fL --retry 6 --retry-delay 3 --connect-timeout 20 \
  "https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/${BASE_REF}/nams-a1-quality/cloudshell-terminate-two-create-install.sh" \
  -o "$TMP"
sed -i "s/01a27dc20b5b104dfea74f62179c05e87a34a3c0/${SUPPORT_REF}/g" "$TMP"
grep -q "SUPPORT_REF=\"${SUPPORT_REF}\"" "$TMP"
exec bash "$TMP"
