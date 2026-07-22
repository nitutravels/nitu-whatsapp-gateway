#!/usr/bin/env bash
set -Eeuo pipefail

# One-command entry point for Oracle Cloud Shell.
# It patches the previously audited controller with a valid installer revision
# and a shape-compatible Ubuntu ARM64 image before execution.
BASE_REF="8fd62cbe9349fcb946a609f2a2db30f832669e39"
INSTALLER_REF="bfa7862d272185abfee0c8f7be020383b22d52ab"
RAW="https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway"
WORK="${HOME}/nams-one-install-v2"
SCRIPT="${WORK}/controller.sh"

mkdir -p "$WORK"
curl -fL --retry 8 --retry-delay 5 --connect-timeout 20 \
  "$RAW/$BASE_REF/nams-deploy/cloudshell-one-install.sh" -o "$SCRIPT"

python3 - "$SCRIPT" "$INSTALLER_REF" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
installer_ref = sys.argv[2]
s = p.read_text()
s = s.replace(
    'INSTALLER_REF="${NAMS_INSTALLER_REF:-89fe9e7fc70ff4f9f7977fc81d09905c94269e9c}"',
    f'INSTALLER_REF="${{NAMS_INSTALLER_REF:-{installer_ref}}}"'
)
s = s.replace(
    'IMAGE_ID="$(oci compute instance get --region "$REGION" --instance-id "$REFERENCE_ID" --query \'data."image-id"\' --raw-output)"',
    'IMAGE_ID="$(oci compute image list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --shape "$SHAPE" --operating-system \'Canonical Ubuntu\' --operating-system-version \'24.04\' --sort-by TIMECREATED --sort-order DESC --all --query \'data[0].id\' --raw-output)"'
)
if installer_ref not in s:
    raise SystemExit('Failed to apply installer revision correction')
if 'oci compute image list' not in s:
    raise SystemExit('Failed to apply ARM64 image-selection correction')
p.write_text(s)
PY

chmod 700 "$SCRIPT"
bash -n "$SCRIPT"
exec "$SCRIPT"
