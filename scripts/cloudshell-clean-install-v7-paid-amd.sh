#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_URL="https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/2984a20b78c441cfea6c48833b404d3b89923764/scripts/cloudshell-clean-install-v5.sh"
TARGET="/tmp/nitu-install-v7-paid-amd-inner.sh"

curl -fsSL "$SOURCE_URL" -o "$TARGET"
chmod 700 "$TARGET"

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()

# Cloud Shell is FIPS-enabled; ED25519 fails. Use RSA.
s = s.replace('SSH_KEY="$HOME/.ssh/nitu_waha_ed25519"', 'SSH_KEY="$HOME/.ssh/nitu_waha_rsa3072"')
s = s.replace("ssh-keygen -q -t ed25519 -N '' -f \"$SSH_KEY\" -C \"nitu-waha-$DEPLOYMENT_ID\"", "ssh-keygen -q -t rsa -b 3072 -N '' -f \"$SSH_KEY\" -C \"nitu-waha-$DEPLOYMENT_ID\"")

# Free A1 is out of capacity in ap-mumbai-1. Switch to x86 paid flexible shape
# and the matching non-ARM WAHA NOWEB image.
s = s.replace('say "Select Ampere A1 and latest compatible Ubuntu 24.04 ARM image"', 'say "Select paid AMD flexible shape and latest compatible Ubuntu 24.04 image"')
s = s.replace('SHAPE="VM.Standard.A1.Flex"', 'SHAPE="VM.Standard.E4.Flex"')
s = s.replace("say \"Launch one clean Ampere instance; capacity plans are 2 OCPU/8 GB then 1 OCPU/6 GB\"", "say \"Launch one clean paid AMD instance; capacity plans are 1 OCPU/4 GB then 1 OCPU/3 GB\"")
s = s.replace("for plan in '2 8' '1 6'; do", "for plan in '1 4' '1 3'; do")
s = s.replace('devlikeapro/waha:noweb-arm-2026.7.1', 'devlikeapro/waha:noweb-2026.7.1')
s = s.replace('engine=NOWEB', 'engine=NOWEB\nshape_family=AMD64')

# Avoid hidden wait failure; print the OCI error files before stopping.
needle = '''trap 'rc=$?; echo; echo "INSTALL_FAILED line=$LINENO exit=$rc"; echo "Log: $LOG"; exit $rc' ERR'''
replacement = '''trap 'rc=$?; echo; echo "INSTALL_FAILED line=$LINENO exit=$rc"; if [ -n "${WORK:-}" ] && [ -d "$WORK" ]; then echo "Relevant OCI errors:"; find "$WORK" -maxdepth 1 -name "*.err" -type f -print -exec sed -n "1,160p" {} \\; 2>/dev/null || true; fi; echo "Log: $LOG"; exit $rc' ERR'''
s = s.replace(needle, replacement)

s = s.replace('echo "Public IP: $PUBLIC_IP"', 'echo "Public IP: $PUBLIC_IP"\necho "DNS A record needed: wa.nitutravels.in -> $PUBLIC_IP"')
p.write_text(s)
PY

bash -n "$TARGET"
exec bash "$TARGET"
