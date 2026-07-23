#!/usr/bin/env bash
set -Eeuo pipefail

SRC='https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/558d6e8b0b533edc319b23ba4fb1d9378e4e7898/nams-deploy/one-click-cloudshell-seo-v1.sh'
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl -fsSL --retry 5 --connect-timeout 20 "$SRC" -o "$TMP"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
s=s.replace('oci iam region-subscription list --all >/dev/null\n\nTENANCY_OCID=', 'TENANCY_OCID=', 1)
needle='valid_ocid "$TENANCY_OCID" || { echo "Could not determine tenancy OCID from Cloud Shell." >&2; exit 2; }\n'
replacement=needle+'oci iam region-subscription list --region "$REGION" --tenancy-id "$TENANCY_OCID" --all >/dev/null\n'
if needle not in s:
    raise SystemExit('Installer patch target not found')
s=s.replace(needle,replacement,1)
p.write_text(s)
PY
bash -n "$TMP"
exec bash "$TMP"
