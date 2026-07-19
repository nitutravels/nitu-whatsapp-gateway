#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_URL="https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/2984a20b78c441cfea6c48833b404d3b89923764/scripts/cloudshell-clean-install-v5.sh"
TARGET="/tmp/nitu-install-v6-inner.sh"

curl -fsSL "$SOURCE_URL" -o "$TARGET"
chmod 700 "$TARGET"

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
# Reuse FIPS-compatible RSA key generation.
s = s.replace('SSH_KEY="$HOME/.ssh/nitu_waha_ed25519"', 'SSH_KEY="$HOME/.ssh/nitu_waha_rsa3072"')
s = s.replace("ssh-keygen -q -t ed25519 -N '' -f \"$SSH_KEY\" -C \"nitu-waha-$DEPLOYMENT_ID\"", "ssh-keygen -q -t rsa -b 3072 -N '' -f \"$SSH_KEY\" -C \"nitu-waha-$DEPLOYMENT_ID\"")
# Print the exact OCI launch error before the global trap exits. This is the next
# decisive diagnostic; do not hide OCI's capacity/limit/policy reason.
needle='''trap 'rc=$?; echo; echo "INSTALL_FAILED line=$LINENO exit=$rc"; echo "Log: $LOG"; exit $rc' ERR'''
replacement='''trap 'rc=$?; echo; echo "INSTALL_FAILED line=$LINENO exit=$rc"; if [ -d "$WORK" ]; then echo "Relevant OCI errors:"; find "$WORK" -maxdepth 1 -name "*.err" -type f -print -exec sed -n "1,160p" {} \\; 2>/dev/null || true; fi; echo "Log: $LOG"; exit $rc' ERR'''
s = s.replace(needle, replacement)
# If OCI launch returns an instance id but wait-for-state exits non-zero, continue
# by resolving the instance lifecycle explicitly instead of treating it as a fatal
# shell error. This prevents false failure on slow provisioning.
s = s.replace('''--wait-for-state RUNNING --max-wait-seconds 600 \\
      --query 'data.id' --raw-output 2>"$WORK/launch.err")"''', '''--query 'data.id' --raw-output 2>"$WORK/launch.err")"''')
# Add an explicit lifecycle wait after a successful id is returned.
s = s.replace('''if [[ $rc -eq 0 && "$INSTANCE_ID" == ocid1.instance.* ]]; then
      SELECTED_AD="$AD"; SELECTED_OCPUS="$OCPUS"; SELECTED_MEMORY="$MEMORY"; break 2
    fi''', '''if [[ $rc -eq 0 && "$INSTANCE_ID" == ocid1.instance.* ]]; then
      echo "Instance created: $INSTANCE_ID"
      if oci compute instance get --instance-id "$INSTANCE_ID" --wait-for-state RUNNING --max-wait-seconds 600 >/dev/null 2>"$WORK/wait-running.err"; then
        SELECTED_AD="$AD"; SELECTED_OCPUS="$OCPUS"; SELECTED_MEMORY="$MEMORY"; break 2
      fi
      echo "Instance did not reach RUNNING for this plan; terminating partial instance"
      cat "$WORK/wait-running.err" || true
      oci compute instance terminate --instance-id "$INSTANCE_ID" --preserve-boot-volume false --force >/dev/null 2>&1 || true
      INSTANCE_ID=""
    fi''')
# Make capacity exhaustion explicit instead of silently falling through.
s = s.replace('''cat "$WORK/launch.err"
    INSTANCE_ID=""''', '''cat "$WORK/launch.err"
    if grep -Eiq 'Out of host capacity|capacity|LimitExceeded|Service limit|quota' "$WORK/launch.err"; then
      echo "Classified launch failure: capacity_or_limit; trying next plan/AD"
    else
      echo "Classified launch failure: non_capacity; stopping for remedial action"
      exit 61
    fi
    INSTANCE_ID=""''')
p.write_text(s)
PY

bash -n "$TARGET"
exec bash "$TARGET"
