#!/usr/bin/env bash
set +x
set -Eeuo pipefail

REGION="${OCI_REGION:-ap-mumbai-1}"
TENANCY_OCID="${OCI_TENANCY_OCID:?OCI_TENANCY_OCID is required}"
COMPARTMENT_OCID="${OCI_COMPARTMENT_OCID:-}"
COMPARTMENT_NAME="${OCI_COMPARTMENT_NAME:-NituWAGateway}"
TARGET_NAME="${OCI_TARGET_INSTANCE:-NAMS-Lightpanda-Agent}"
BASE_CONTROLLER_REF="128feab466e42c9d61b279c2b707ae5053b4721d"
WORK="${RUNNER_TEMP:-/tmp}/nams-preclean-${GITHUB_RUN_ID:-manual}"
mkdir -p "$WORK"

valid_ocid(){ [[ "${1:-}" == ocid1.* ]]; }
state(){ oci compute instance get --region "$REGION" --instance-id "$1" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true; }
wait_terminated(){ local id="$1" s=''; for _ in $(seq 1 270); do s="$(state "$id")"; [ "$s" = TERMINATED ] && return 0; sleep 10; done; echo "Timed out waiting for $id to terminate; current state=$s" >&2; return 1; }

if ! valid_ocid "$COMPARTMENT_OCID"; then
  COMPARTMENT_OCID="$(oci iam compartment list --region "$REGION" --compartment-id "$TENANCY_OCID" --compartment-id-in-subtree true --access-level ACCESSIBLE --all --output json | jq -r --arg n "$COMPARTMENT_NAME" '[.data[]|select(.name==$n and .["lifecycle-state"]=="ACTIVE")|.id][0]//empty')"
fi
valid_ocid "$COMPARTMENT_OCID"

ACTIVE_JSON="$(oci compute instance list --region "$REGION" --compartment-id "$COMPARTMENT_OCID" --display-name "$TARGET_NAME" --all --output json)"
mapfile -t ACTIVE_IDS < <(jq -r '.data[]|select(.["lifecycle-state"]!="TERMINATED")|.id' <<<"$ACTIVE_JSON")
SKIP_FD=''
if [ ${#ACTIVE_IDS[@]} -gt 0 ]; then
  echo "Found ${#ACTIVE_IDS[@]} unfinished NAMS candidate(s); preserving boot volumes and retiring only those candidates."
  for id in "${ACTIVE_IDS[@]}"; do
    fd="$(oci compute instance get --region "$REGION" --instance-id "$id" --query 'data."fault-domain"' --raw-output 2>/dev/null || true)"
    [ -n "$SKIP_FD" ] || SKIP_FD="$fd"
    echo "Retiring unfinished NAMS candidate in ${fd:-unknown placement}."
    oci compute instance terminate --region "$REGION" --instance-id "$id" --preserve-boot-volume true --force >/dev/null
  done
  for id in "${ACTIVE_IDS[@]}"; do wait_terminated "$id"; done
fi

curl -fsSL "https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/${BASE_CONTROLLER_REF}/nams-deploy/deploy-capacity-aware.sh" -o "$WORK/controller.sh"
chmod 700 "$WORK/controller.sh"

if [ -n "$SKIP_FD" ]; then
  python3 - "$WORK/controller.sh" "$SKIP_FD" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); skip=sys.argv[2]
s=p.read_text()
old='for profile in auto FAULT-DOMAIN-1 FAULT-DOMAIN-2 FAULT-DOMAIN-3; do'
profiles=' '.join(x for x in ('FAULT-DOMAIN-1','FAULT-DOMAIN-2','FAULT-DOMAIN-3') if x != skip)
new=f'for profile in {profiles}; do'
if old not in s:
    raise SystemExit('Expected placement loop not found in certified controller')
p.write_text(s.replace(old,new,1))
PY
  echo "Recovery will skip the previously used placement $SKIP_FD."
fi

exec bash "$WORK/controller.sh"
