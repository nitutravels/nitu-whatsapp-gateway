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

old_network = '''say "1/10 Resolving the two obsolete NAMS E2 instances"
OLD_IDS=()
SOURCE_ID=""
for name in "${OLD_NAMES[@]}"; do
  id="$(find_running_by_name "$name")"
  if [ -n "$id" ]; then
    json="$(oci compute instance get --region "$REGION" --instance-id "$id" --output json)"
    actual="$(jq -r '.data["display-name"]' <<<"$json")"
    shape="$(jq -r '.data.shape' <<<"$json")"
    [[ "$actual" != *WAHA* && "$actual" != *whatsapp* && "$actual" != *WhatsApp* ]] || fail "Safety stop: $actual resembles WAHA/WhatsApp."
    [ "$actual" = "$name" ] || fail "Safety stop: expected $name but resolved $actual."
    [ "$shape" = "VM.Standard.E2.1.Micro" ] || fail "Safety stop: $actual is $shape, not the obsolete E2 Micro shape."
    OLD_IDS+=("$id")
    [ -n "$SOURCE_ID" ] || SOURCE_ID="$id"
    echo "Found obsolete instance: $actual ($id)"
  else
    echo "Already absent or not running: $name"
  fi
done
[ -n "$SOURCE_ID" ] || fail "Neither exact obsolete instance is running, so network placement cannot be inherited safely."

SOURCE_JSON="$(oci compute instance get --region "$REGION" --instance-id "$SOURCE_ID" --output json)"
COMPARTMENT_ID="$(jq -r '.data["compartment-id"]' <<<"$SOURCE_JSON")"
AD="$(jq -r '.data["availability-domain"]' <<<"$SOURCE_JSON")"
SOURCE_VNICS="$(oci compute instance list-vnics --region "$REGION" --instance-id "$SOURCE_ID" --output json)"
SOURCE_VNIC_ID="$(jq -r '.data[0].id // empty' <<<"$SOURCE_VNICS")"
SUBNET_ID="$(jq -r '.data[0]["subnet-id"] // empty' <<<"$SOURCE_VNICS")"
[ -n "$SOURCE_VNIC_ID" ] && [ -n "$SUBNET_ID" ] || fail "Source VNIC/subnet could not be resolved."
VCN_ID="$(oci network subnet get --region "$REGION" --subnet-id "$SUBNET_ID" --query 'data."vcn-id"' --raw-output)"
EXISTING_NSGS="$(oci network vnic get --region "$REGION" --vnic-id "$SOURCE_VNIC_ID" --output json | jq -c '.data["nsg-ids"] // []')"
'''

new_network = '''say "1/10 Resolving obsolete NAMS instances and a read-only network source"
OLD_IDS=()
SOURCE_ID=""
SOURCE_KIND="obsolete-nams"
for name in "${OLD_NAMES[@]}"; do
  id="$(find_running_by_name "$name")"
  if [ -n "$id" ]; then
    json="$(oci compute instance get --region "$REGION" --instance-id "$id" --output json)"
    actual="$(jq -r '.data["display-name"]' <<<"$json")"
    shape="$(jq -r '.data.shape' <<<"$json")"
    [[ "$actual" != *WAHA* && "$actual" != *whatsapp* && "$actual" != *WhatsApp* ]] || fail "Safety stop: $actual resembles WAHA/WhatsApp."
    [ "$actual" = "$name" ] || fail "Safety stop: expected $name but resolved $actual."
    [ "$shape" = "VM.Standard.E2.1.Micro" ] || fail "Safety stop: $actual is $shape, not the obsolete E2 Micro shape."
    OLD_IDS+=("$id")
    [ -n "$SOURCE_ID" ] || SOURCE_ID="$id"
    echo "Found obsolete instance: $actual ($id)"
  else
    echo "Already absent or not running: $name"
  fi
done

EXISTING_REPLACEMENT="$(find_running_by_name "$NEW_NAME")"
if [ -n "$EXISTING_REPLACEMENT" ]; then
  fail "A RUNNING $NEW_NAME already exists. Refusing to create a duplicate."
fi

if [ -z "$SOURCE_ID" ]; then
  SOURCE_KIND="waha-read-only"
  for candidate in "NituTravelsWAHA-20260719T184923Z" "nitu-whatsapp-gateway" "nitu-waha-gateway"; do
    SOURCE_ID="$(find_running_by_name "$candidate")"
    [ -n "$SOURCE_ID" ] && break
  done
fi

if [ -z "$SOURCE_ID" ]; then
  SOURCE_ID="$(oci search resource structured-search --region "$REGION" --query-text 'query instance resources' --output json 2>/dev/null | jq -r '[.data.items[]? | select((.["lifecycle-state"] // .lifecycleState // "") == "RUNNING") | select((.["display-name"] // .displayName // "") | test("WAHA|whatsapp";"i"))] | sort_by(.["time-created"] // .timeCreated // "") | last | .identifier // empty')"
fi

[ -n "$SOURCE_ID" ] || fail "The obsolete NAMS instances are gone and no running WAHA network reference could be found. No resource was modified."

SOURCE_JSON="$(oci compute instance get --region "$REGION" --instance-id "$SOURCE_ID" --output json)"
SOURCE_NAME="$(jq -r '.data["display-name"]' <<<"$SOURCE_JSON")"
COMPARTMENT_ID="$(jq -r '.data["compartment-id"]' <<<"$SOURCE_JSON")"
AD="$(jq -r '.data["availability-domain"]' <<<"$SOURCE_JSON")"
SOURCE_VNICS="$(oci compute instance list-vnics --region "$REGION" --instance-id "$SOURCE_ID" --output json)"
SOURCE_VNIC_ID="$(jq -r '.data[0].id // empty' <<<"$SOURCE_VNICS")"
SUBNET_ID="$(jq -r '.data[0]["subnet-id"] // empty' <<<"$SOURCE_VNICS")"
[ -n "$SOURCE_VNIC_ID" ] && [ -n "$SUBNET_ID" ] || fail "Read-only network source VNIC/subnet could not be resolved."
VCN_ID="$(oci network subnet get --region "$REGION" --subnet-id "$SUBNET_ID" --query 'data."vcn-id"' --raw-output)"
if [ "$SOURCE_KIND" = "waha-read-only" ]; then
  EXISTING_NSGS='[]'
  echo "Using $SOURCE_NAME only as a read-only subnet/VCN reference; its NSGs will NOT be copied and it will NEVER be modified."
else
  EXISTING_NSGS="$(oci network vnic get --region "$REGION" --vnic-id "$SOURCE_VNIC_ID" --output json | jq -c '.data["nsg-ids"] // []')"
fi
'''

if old_network not in s:
    raise SystemExit('Expected network-source block was not found; refusing an unverified patch')
s = s.replace(old_network, new_network, 1)

old_loop = '''NEW_ID=""
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

new_loop = '''NEW_ID=""
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
    if "${cmd[@]}" >/tmp/nams-a1-launch.json 2>/tmp/nams-a1-launch.err; then rc=0; else rc=$?; fi
    if [ "$rc" -eq 0 ]; then
      NEW_ID="$(jq -r '.data.id // empty' /tmp/nams-a1-launch.json)"
      [ -n "$NEW_ID" ] && break 2
      fail "Oracle returned success without an instance OCID."
    fi

    echo "Placement $fd attempt $attempt failed (OCI exit $rc):"
    cat /tmp/nams-a1-launch.err >&2
    if grep -Eqi 'TooManyRequests|status[^0-9]*429|request-rate limit|rate limit exceeded|throttl' /tmp/nams-a1-launch.err; then
      case "$attempt" in 1) delay=15;; 2) delay=30;; *) delay=60;; esac
      [ "$attempt" -lt 5 ] || fail "OCI throttling persisted after backoff. Wait 10 minutes before running again."
      echo "OCI throttled the request; waiting ${delay}s before retrying the SAME placement."
      sleep "$delay"
      continue
    fi
    if grep -Eqi 'out of host capacity|insufficient capacity|capacity is not available|no available host|InternalError.*capacity' /tmp/nams-a1-launch.err; then
      placement_capacity=true
      break
    fi
    if grep -Eqi 'LimitExceeded|QuotaExceeded|service limit|quota|not authorized|not permitted|AuthorizationFailed|InvalidParameter|CannotParseRequest' /tmp/nams-a1-launch.err; then
      fail "Oracle rejected the launch because of quota, permission, or request validation."
    fi
    fail "A1 launch failed for a non-capacity reason."
  done
  if [ "$placement_capacity" = true ]; then
    echo "Confirmed host-capacity failure for $fd; waiting 20s before the next placement."
    sleep 20
  fi
done
'''

if old_loop not in s:
    raise SystemExit('Expected launch loop was not found; refusing an unverified patch')
s = s.replace(old_loop, new_loop, 1)
path.write_text(s)
PY

bash -n "$TMP"
grep -q 'Using $SOURCE_NAME only as a read-only subnet/VCN reference' "$TMP"
grep -q 'ssh-keygen -q -t rsa -b 3072' "$TMP"
grep -q 'TooManyRequests' "$TMP"
grep -q 'A RUNNING $NEW_NAME already exists' "$TMP"
! grep -q 'ssh-keygen -q -t ed25519' "$TMP"

exec bash "$TMP"
