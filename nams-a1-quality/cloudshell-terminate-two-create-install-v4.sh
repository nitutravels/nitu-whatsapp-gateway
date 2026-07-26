#!/usr/bin/env bash
set -Eeuo pipefail

BASE_REF="e977de2a59fdda744f68c307b6081a17dcce6460"
SUPPORT_REF="c76d001eafe91bc3a47a65f8f80d83a1258e27e4"
TMP="$(mktemp /tmp/nams-a1-controller.XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT

curl -fL --retry 6 --retry-delay 3 --connect-timeout 20 \
  "https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/${BASE_REF}/nams-a1-quality/cloudshell-terminate-two-create-install.sh" \
  -o "$TMP"

python3 - "$TMP" "$SUPPORT_REF" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
support_ref = sys.argv[2]
s = path.read_text()

s = s.replace(
    'SUPPORT_REF="01a27dc20b5b104dfea74f62179c05e87a34a3c0"',
    f'SUPPORT_REF="{support_ref}"',
    1,
)
s = s.replace(
    'ssh-keygen -q -t ed25519 -N \'\' -f "$KEY"',
    'ssh-keygen -q -t rsa -b 3072 -N \'\' -f "$KEY"',
    1,
)

old = '''  set +e
  "${cmd[@]}" >/tmp/nams-a1-launch.json 2>/tmp/nams-a1-launch.err
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
'''
new = '''  : >/tmp/nams-a1-launch.json
  : >/tmp/nams-a1-launch.err
  if "${cmd[@]}" >/tmp/nams-a1-launch.json 2>/tmp/nams-a1-launch.err; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
'''
if old not in s:
    raise SystemExit('Expected launch block was not found; refusing an unverified patch')
s = s.replace(old, new, 1)

old_classification = '''  if grep -Eqi 'out of host capacity|insufficient capacity|capacity is not available|LimitExceeded' /tmp/nams-a1-launch.err; then
    cat /tmp/nams-a1-launch.err
    continue
  fi
  cat /tmp/nams-a1-launch.err >&2
  fail "A1 launch failed for a reason other than host placement capacity."
'''
new_classification = '''  echo "Placement $fd failed (OCI exit $rc):"
  cat /tmp/nams-a1-launch.err >&2
  if grep -Eqi 'out of host capacity|insufficient capacity|capacity is not available|no available host|InternalError.*capacity' /tmp/nams-a1-launch.err; then
    echo "Confirmed host-capacity failure; trying the next distinct fault-domain placement."
    continue
  fi
  if grep -Eqi 'LimitExceeded|service limit|quota|not authorized|not permitted|AuthorizationFailed|InvalidParameter|CannotParseRequest' /tmp/nams-a1-launch.err; then
    fail "Oracle rejected the A1 launch because of quota, permission, or request validation. The two old instances were NOT terminated."
  fi
  fail "A1 launch failed for a non-capacity reason. The two old instances were NOT terminated."
'''
if old_classification not in s:
    raise SystemExit('Expected error-classification block was not found; refusing an unverified patch')
s = s.replace(old_classification, new_classification, 1)

path.write_text(s)
PY

bash -n "$TMP"
grep -q "SUPPORT_REF=\"${SUPPORT_REF}\"" "$TMP"
grep -q "ssh-keygen -q -t rsa -b 3072" "$TMP"
grep -q 'if "${cmd\[@\]}" >/tmp/nams-a1-launch.json' "$TMP"
! grep -q 'set +e' "$TMP"
! grep -q 'ssh-keygen -q -t ed25519' "$TMP"

exec bash "$TMP"
