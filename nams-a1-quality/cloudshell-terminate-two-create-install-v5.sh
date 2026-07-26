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

old = '''NEW_ID=""
for fd in AUTO FAULT-DOMAIN-1 FAULT-DOMAIN-2 FAULT-DOMAIN-3; do
  echo "Trying placement: $fd"
  cmd=(oci compute instance launch --region "$REGION" --compartment-id "$COMPARTMENT_ID" \\
    --availability-domain "$AD" --display-name "$NEW_NAME" --shape "$SHAPE" \\
    --shape-config "{\\"ocpus\\":$OCPUS,\\"memoryInGBs\\":$MEMORY_GB}" \\
    --image-id "$IMAGE_ID" --subnet-id "$SUBNET_ID" --assign-public-ip false \\
    --nsg-ids file:///tmp/nams-a1-nsgs.json --ssh-authorized-keys-file "$KEY.pub" \\
    --user-data-file /tmp/nams-a1-cloud-init.sh --freeform-tags file:///tmp/nams-a1-tags.json \\
    --hostname-label namsauthority --output json)
  [ "$fd" = AUTO ] || cmd+=(--fault-domain "$fd")
  set +e
  "${cmd[@]}" >/tmp/nams-a1-launch.json 2>/tmp/nams-a1-launch.err
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    NEW_ID="$(jq -r '.data.id // empty' /tmp/nams-a1-launch.json)"
    [ -n "$NEW_ID" ] && break
  fi
  if grep -Eqi 'out of host capacity|insufficient capacity|capacity is not available|LimitExceeded' /tmp/nams-a1-launch.err; then
    cat /tmp/nams-a1-launch.err
    continue
  fi
  cat /tmp/nams-a1-launch.err >&2
  fail "A1 launch failed for a reason other than host placement capacity."
done
'''

new = '''NEW_ID=""
for fd in AUTO FAULT-DOMAIN-1 FAULT-DOMAIN-2 FAULT-DOMAIN-3; do
  echo "Trying placement: $fd"
  placement_capacity=false

  for attempt in 1 2 3 4 5; do
    cmd=(oci compute instance launch --region "$REGION" --compartment-id "$COMPARTMENT_ID" \\
      --availability-domain "$AD" --display-name "$NEW_NAME" --shape "$SHAPE" \\
      --shape-config "{\\"ocpus\\":$OCPUS,\\"memoryInGBs\\":$MEMORY_GB}" \\
      --image-id "$IMAGE_ID" --subnet-id "$SUBNET_ID" --assign-public-ip false \\
      --nsg-ids file:///tmp/nams-a1-nsgs.json --ssh-authorized-keys-file "$KEY.pub" \\
      --user-data-file /tmp/nams-a1-cloud-init.sh --freeform-tags file:///tmp/nams-a1-tags.json \\
      --hostname-label namsauthority --output json --max-retries 7)
    [ "$fd" = AUTO ] || cmd+=(--fault-domain "$fd")

    : >/tmp/nams-a1-launch.json
    : >/tmp/nams-a1-launch.err
    if "${cmd[@]}" >/tmp/nams-a1-launch.json 2>/tmp/nams-a1-launch.err; then
      rc=0
    else
      rc=$?
    fi

    if [ "$rc" -eq 0 ]; then
      NEW_ID="$(jq -r '.data.id // empty' /tmp/nams-a1-launch.json)"
      [ -n "$NEW_ID" ] && break 2
      fail "Oracle returned success without a new instance OCID. The old instances were NOT terminated."
    fi

    echo "Placement $fd attempt $attempt failed (OCI exit $rc):"
    cat /tmp/nams-a1-launch.err >&2

    if grep -Eqi 'TooManyRequests|status[^0-9]*429|request-rate limit|rate limit exceeded|throttl' /tmp/nams-a1-launch.err; then
      case "$attempt" in
        1) delay=15 ;;
        2) delay=30 ;;
        *) delay=60 ;;
      esac
      if [ "$attempt" -lt 5 ]; then
        echo "OCI API throttled this request. Waiting ${delay}s before retrying the SAME placement."
        sleep "$delay"
        continue
      fi
      fail "OCI API throttling persisted after exponential backoff. No instance was terminated; wait 10 minutes before running this controller again."
    fi

    if grep -Eqi 'out of host capacity|insufficient capacity|capacity is not available|no available host|InternalError.*capacity' /tmp/nams-a1-launch.err; then
      placement_capacity=true
      echo "Confirmed host-capacity failure for $fd."
      break
    fi

    if grep -Eqi 'LimitExceeded|QuotaExceeded|service limit|quota|not authorized|not permitted|AuthorizationFailed|InvalidParameter|CannotParseRequest' /tmp/nams-a1-launch.err; then
      fail "Oracle rejected the A1 launch because of quota, permission, or request validation. The two old instances were NOT terminated."
    fi

    fail "A1 launch failed for a non-capacity reason. The two old instances were NOT terminated."
  done

  if [ "$placement_capacity" = true ]; then
    echo "Waiting 20s before trying the next distinct fault-domain placement to avoid OCI throttling."
    sleep 20
  fi
done
'''

if old not in s:
    raise SystemExit('Expected A1 placement loop was not found; refusing an unverified patch')
s = s.replace(old, new, 1)
path.write_text(s)
PY

bash -n "$TMP"
grep -q "SUPPORT_REF=\"${SUPPORT_REF}\"" "$TMP"
grep -q "ssh-keygen -q -t rsa -b 3072" "$TMP"
grep -q "TooManyRequests" "$TMP"
grep -q "Waiting 20s before trying the next distinct fault-domain" "$TMP"
! grep -q "ssh-keygen -q -t ed25519" "$TMP"

exec bash "$TMP"
