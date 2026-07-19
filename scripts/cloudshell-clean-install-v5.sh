#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_URL="https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/c25abc590a9f055051caab8e0817a980529623ee/scripts/cloudshell-clean-install-v3.sh"
TARGET="/tmp/nitu-install-v5-inner.sh"

curl -fsSL "$SOURCE_URL" -o "$TARGET"
chmod 700 "$TARGET"

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()

# Oracle Cloud Shell is FIPS-enabled; ED25519 key generation fails there.
s = s.replace('SSH_KEY="$HOME/.ssh/nitu_waha_ed25519"', 'SSH_KEY="$HOME/.ssh/nitu_waha_rsa3072"')
s = s.replace("ssh-keygen -q -t ed25519 -N '' -f \"$SSH_KEY\" -C \"nitu-waha-$DEPLOYMENT_ID\"", "ssh-keygen -q -t rsa -b 3072 -N '' -f \"$SSH_KEY\" -C \"nitu-waha-$DEPLOYMENT_ID\"")

# The outer installer writes a cloud-init script using an unquoted heredoc.
# Docker Compose variables must remain literal until the instance runs Docker.
for name in [
    'POSTGRES_PASSWORD',
    'WAHA_API_KEY',
    'WAHA_DASHBOARD_USERNAME',
    'WAHA_DASHBOARD_PASSWORD',
    'WEBHOOK_SECRET',
]:
    s = s.replace('${' + name + '}', '\\${' + name + '}')

s = s.replace('echo "Public IP: $PUBLIC_IP"', 'echo "Public IP: $PUBLIC_IP"\necho "DNS A record needed: wa.nitutravels.in -> $PUBLIC_IP"')
p.write_text(s)
PY

bash -n "$TARGET"
exec bash "$TARGET"
