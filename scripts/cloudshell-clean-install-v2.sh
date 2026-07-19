#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_URL="https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/5992e13800ae774b6ba5301522cfec721a268b00/scripts/cloudshell-clean-install.sh"
TARGET="/tmp/nitu-install-v2.sh"

: "${OCI_CLI_CONFIG_FILE:=/etc/oci/config}"
export OCI_CLI_CONFIG_FILE

if [[ ! -r "$OCI_CLI_CONFIG_FILE" ]]; then
  echo "INSTALL_FAILED: Oracle Cloud Shell config is not readable: $OCI_CLI_CONFIG_FILE" >&2
  exit 20
fi

curl -fsSL "$SOURCE_URL" -o "$TARGET"
chmod 700 "$TARGET"

# The original installer incorrectly assumed ~/.oci/config. Cloud Shell uses
# OCI_CLI_CONFIG_FILE (normally /etc/oci/config) with instance_obo_user auth.
python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
s = s.replace('"$HOME/.oci/config"', '"${OCI_CLI_CONFIG_FILE:-/etc/oci/config}"')
s = s.replace('Could not read tenancy OCID from ~/.oci/config', 'Could not read tenancy OCID from OCI_CLI_CONFIG_FILE')
p.write_text(s)
PY

exec bash "$TARGET"
