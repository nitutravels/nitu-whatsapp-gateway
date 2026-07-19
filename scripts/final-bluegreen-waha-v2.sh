#!/usr/bin/env bash
set -Eeuo pipefail

: "${COMPARTMENT_OCID:?COMPARTMENT_OCID is required}"
: "${BOOTSTRAP_URL:?BOOTSTRAP_URL is required}"
: "${DOMAIN:?DOMAIN is required}"
: "${WAHA_API_KEY:?WAHA_API_KEY is required}"

RESULT_FILE="${RESULT_FILE:-/tmp/final-bluegreen-waha-v2-result.txt}"
mkdir -p "$(dirname "$RESULT_FILE")"
exec > >(tee "$RESULT_FILE") 2>&1

echo 'FINAL_BLUEGREEN_WAHA_V2_BEGIN'
echo "STARTED_AT=$(date -u +%FT%TZ)"

candidate_id=''
candidate_private_id=''
reserved_id=''
old_private_id=''
cutover_started=0
cutover_verified=0

cleanup() {
  rc=$?
  trap - ERR
  set +e
  echo "FAILURE_CODE=$rc"
  if [ "$cutover_started" -eq 1 ] && [ "$cutover_verified" -eq 0 ] \
      && [[ "$reserved_id" =~ ^ocid1\.publicip\. ]] \
      && [[ "$old_private_id" =~ ^ocid1\.privateip\. ]]; then
    echo 'CUTOVER_ROLLBACK_BEGIN=yes'
    oci network public-ip update \
      --public-ip-id "$reserved_id" \
      --private-ip-id "$old_private_id" \
      --force --wait-for-state ASSIGNED --max-wait-seconds 600 >/dev/null 2>&1 || true
    echo 'CUTOVER_ROLLBACK_REQUESTED=yes'
  fi
  if [[ "$candidate_id" =~ ^ocid1\.instance\. ]]; then
    echo "TERMINATING_FAILED_CANDIDATE=$candidate_id"
    oci compute instance terminate \
      --instance-id "$candidate_id" \
      --force --preserve-boot-volume false >/dev/null 2>&1 || true
  fi
  echo 'INSTALL_RESULT=failed'
  echo "FINISHED_AT=$(date -u +%FT%TZ)"
  echo 'FINAL_BLUEGREEN_WAHA_V2_END'
  exit "$rc"
}
trap cleanup ERR

old_id="$(oci compute instance list \
  --compartment-id "$COMPARTMENT_OCID" \
  --display-name nitu-whatsapp-gateway --all \
  --query 'data[?"lifecycle-state"!=`TERMINATED`].id | [0]' \
  --raw-output)"
[[ "$old_id" =~ ^ocid1\.instance\. ]] || { echo 'ERROR=Current gateway instance not found'; false; }

oci compute instance get --instance-id "$old_id" --output json > /tmp/old.json
old_state="$(jq -r '.data["lifecycle-state"]' /tmp/old.json)"
ad="$(jq -r '.data["availability-domain"]' /tmp/old.json)"
old_shape="$(jq -r '.data.shape' /tmp/old.json)"
old_image="$(jq -r '.data["image-id"] // .data["source-details"]["image-id"] // empty' /tmp/old.json)"
[ "$old_state" = RUNNING ] || { echo "ERROR=Current gateway is not RUNNING ($old_state)"; false; }
[[ "$old_image" =~ ^ocid1\.image\. ]] || { echo 'ERROR=Current Ubuntu image could not be resolved'; false; }

echo "CURRENT_INSTANCE_ID=$old_id"
echo "CURRENT_SHAPE=$old_shape"

old_vnic="$(oci compute vnic-attachment list \
  --compartment-id "$COMPARTMENT_OCID" --instance-id "$old_id" --all \
  --query 'data[?"lifecycle-state"==`ATTACHED`]."vnic-id" | [0]' --raw-output)"
subnet="$(oci network vnic get --vnic-id "$old_vnic" --query 'data."subnet-id"' --raw-output)"
reserved_ip="$(oci network vnic get --vnic-id "$old_vnic" --query 'data."public-ip"' --raw-output)"
old_private_id="$(oci network private-ip list --vnic-id "$old_vnic" --all \
  --query 'data[?"is-primary"==`true`].id | [0]' --raw-output)"
[[ "$subnet" =~ ^ocid1\.subnet\. ]] || { echo 'ERROR=Subnet not found'; false; }
[[ "$reserved_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'ERROR=Reserved IP not found'; false; }
[[ "$old_private_id" =~ ^ocid1\.privateip\. ]] || { echo 'ERROR=Current private IP not found'; false; }
echo "RESERVED_PUBLIC_IP=$reserved_ip"

stale_ids="$(oci compute instance list \
  --compartment-id "$COMPARTMENT_OCID" \
  --display-name nitu-waha-gateway --all \
  --query 'data[?"lifecycle-state"!=`TERMINATED`].id' --raw-output)"
for stale in $(jq -r '.[]?' <<<"$stale_ids" 2>/dev/null || true); do
  echo "TERMINATING_STALE_CANDIDATE=$stale"
  oci compute instance terminate --instance-id "$stale" --force --preserve-boot-volume false >/dev/null || true
done
sleep 20

cat > /tmp/cloud-init.yaml <<EOF
#cloud-config
package_update: true
packages:
  - curl
runcmd:
  - [bash, -lc, "curl -fsSL '$BOOTSTRAP_URL' -o /root/nitu-waha-bootstrap.sh && chmod 700 /root/nitu-waha-bootstrap.sh && /root/nitu-waha-bootstrap.sh > /var/log/nitu-waha-bootstrap.log 2>&1"]
final_message: "Nitu Travels WAHA candidate bootstrap completed"
EOF
user_data="$(base64 -w0 /tmp/cloud-init.yaml)"
jq -n --arg user_data "$user_data" '{user_data:$user_data}' > /tmp/metadata.json
cat > /tmp/tags.json <<EOF
{"Application":"Nitu WAHA Gateway","ManagedBy":"GitHub Actions","InstallRun":"${GITHUB_RUN_ID:-manual}"}
EOF

launch_candidate() {
  local shape="$1" image="$2" shape_config="${3:-}"
  local -a args=(
    oci compute instance launch
    --availability-domain "$ad"
    --compartment-id "$COMPARTMENT_OCID"
    --subnet-id "$subnet"
    --assign-public-ip true
    --display-name nitu-waha-gateway
    --shape "$shape"
    --image-id "$image"
    --metadata file:///tmp/metadata.json
    --freeform-tags file:///tmp/tags.json
    --wait-for-state RUNNING
    --max-wait-seconds 1200
    --query data.id
    --raw-output
  )
  if [ -n "$shape_config" ]; then
    args+=(--shape-config "$shape_config")
  fi
  "${args[@]}"
}

candidate_id="$(launch_candidate VM.Standard.E2.1.Micro "$old_image" 2>/tmp/e2-launch.err || true)"
if [[ "$candidate_id" =~ ^ocid1\.instance\. ]]; then
  echo 'CANDIDATE_LAUNCH_MODE=E2_MICRO'
else
  echo 'E2_LAUNCH_FAILED=yes'
  tail -n 8 /tmp/e2-launch.err 2>/dev/null || true
  arm_image="$(oci compute image list \
    --compartment-id "$COMPARTMENT_OCID" \
    --operating-system 'Canonical Ubuntu' \
    --operating-system-version '24.04' \
    --shape VM.Standard.A1.Flex \
    --sort-by TIMECREATED --sort-order DESC --all \
    --query 'data[0].id' --raw-output)"
  [[ "$arm_image" =~ ^ocid1\.image\. ]] || { echo 'ERROR=ARM fallback image not found'; false; }
  candidate_id="$(launch_candidate VM.Standard.A1.Flex "$arm_image" '{"ocpus":1,"memoryInGBs":6}' 2>/tmp/a1-launch.err || true)"
  [[ "$candidate_id" =~ ^ocid1\.instance\. ]] || {
    echo 'ERROR=Neither E2 Micro nor A1 Flex candidate could be launched'
    tail -n 8 /tmp/a1-launch.err 2>/dev/null || true
    false
  }
  echo 'CANDIDATE_LAUNCH_MODE=A1_FLEX'
fi

echo "CANDIDATE_INSTANCE_ID=$candidate_id"

candidate_vnic=''
candidate_ip=''
for attempt in $(seq 1 60); do
  candidate_vnic="$(oci compute vnic-attachment list \
    --compartment-id "$COMPARTMENT_OCID" --instance-id "$candidate_id" --all \
    --query 'data[?"lifecycle-state"==`ATTACHED`]."vnic-id" | [0]' --raw-output 2>/dev/null || true)"
  if [[ "$candidate_vnic" =~ ^ocid1\.vnic\. ]]; then
    candidate_ip="$(oci network vnic get --vnic-id "$candidate_vnic" --query 'data."public-ip"' --raw-output 2>/dev/null || true)"
    [[ "$candidate_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
  fi
  sleep 10
done
[[ "$candidate_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'ERROR=Candidate temporary IP missing'; false; }
echo "CANDIDATE_TEMP_IP=$candidate_ip"

ready=0
session_status=UNKNOWN
for attempt in $(seq 1 180); do
  common=(--silent --show-error --connect-timeout 5 --max-time 18 -H "Host: $DOMAIN")
  health_code="$(curl "${common[@]}" -o /tmp/health.json -w '%{http_code}' "http://$candidate_ip/health" 2>/dev/null || true)"
  version_code="$(curl "${common[@]}" -H "X-Api-Key: $WAHA_API_KEY" -o /tmp/version.json -w '%{http_code}' "http://$candidate_ip/api/server/version" 2>/dev/null || true)"
  session_code="$(curl "${common[@]}" -H "X-Api-Key: $WAHA_API_KEY" -o /tmp/session.json -w '%{http_code}' "http://$candidate_ip/api/sessions/nitu-travels" 2>/dev/null || true)"
  engine="$(jq -r '.engine // "unknown"' /tmp/version.json 2>/dev/null || echo unknown)"
  session_status="$(jq -r '.status // "UNKNOWN"' /tmp/session.json 2>/dev/null || echo UNKNOWN)"
  echo "CANDIDATE_VERIFY=$attempt HEALTH=${health_code:-000} VERSION=${version_code:-000} SESSION=${session_code:-000} ENGINE=$engine STATUS=$session_status"

  if [ "$session_code" = 200 ] && [ "$session_status" = FAILED ]; then
    curl "${common[@]}" -H "X-Api-Key: $WAHA_API_KEY" -H 'Content-Type: application/json' \
      -X POST -d '{}' "http://$candidate_ip/api/sessions/nitu-travels/restart" >/dev/null 2>&1 || true
  fi

  if [ "$health_code" = 200 ] && [ "$version_code" = 200 ] && [ "$session_code" = 200 ] && [ "$engine" = NOWEB ]; then
    case "$session_status" in
      WORKING|SCAN_QR_CODE|PASSKEY_REQUIRED|PASSKEY_CONFIRMATION_REQUIRED)
        ready=1
        break
        ;;
    esac
  fi
  sleep 10
done
[ "$ready" -eq 1 ] || { echo 'ERROR=Candidate did not become ready'; false; }
echo 'CANDIDATE_VERIFIED=yes'

candidate_private_id="$(oci network private-ip list --vnic-id "$candidate_vnic" --all \
  --query 'data[?"is-primary"==`true`].id | [0]' --raw-output)"
[[ "$candidate_private_id" =~ ^ocid1\.privateip\. ]] || { echo 'ERROR=Candidate private IP missing'; false; }

reserved_id="$(oci network public-ip get \
  --public-ip-address "$reserved_ip" \
  --query data.id --raw-output)"
temp_id="$(oci network public-ip get \
  --public-ip-address "$candidate_ip" \
  --query data.id --raw-output)"
[[ "$reserved_id" =~ ^ocid1\.publicip\. ]] || { echo 'ERROR=Reserved public IP object missing'; false; }
[[ "$temp_id" =~ ^ocid1\.publicip\. ]] || { echo 'ERROR=Candidate ephemeral public IP object missing'; false; }
echo "RESERVED_PUBLIC_IP_ID=$reserved_id"
echo "CANDIDATE_EPHEMERAL_IP_ID=$temp_id"

cutover_started=1
echo 'CUTOVER_BEGIN=yes'
oci network public-ip delete \
  --public-ip-id "$temp_id" --force \
  --wait-for-state TERMINATED --max-wait-seconds 600 >/dev/null
oci network public-ip update \
  --public-ip-id "$reserved_id" \
  --private-ip-id "$candidate_private_id" \
  --force --wait-for-state ASSIGNED --max-wait-seconds 600 >/dev/null

cutover_ok=0
for attempt in $(seq 1 150); do
  args=(--silent --show-error --connect-timeout 8 --max-time 20 --resolve "$DOMAIN:443:$reserved_ip")
  health_code="$(curl "${args[@]}" -o /tmp/live-health.json -w '%{http_code}' "https://$DOMAIN/health" 2>/dev/null || true)"
  version_code="$(curl "${args[@]}" -H "X-Api-Key: $WAHA_API_KEY" -o /tmp/live-version.json -w '%{http_code}' "https://$DOMAIN/api/server/version" 2>/dev/null || true)"
  session_code="$(curl "${args[@]}" -H "X-Api-Key: $WAHA_API_KEY" -o /tmp/live-session.json -w '%{http_code}' "https://$DOMAIN/api/sessions/nitu-travels" 2>/dev/null || true)"
  engine="$(jq -r '.engine // "unknown"' /tmp/live-version.json 2>/dev/null || echo unknown)"
  live_status="$(jq -r '.status // "UNKNOWN"' /tmp/live-session.json 2>/dev/null || echo UNKNOWN)"
  echo "CUTOVER_VERIFY=$attempt HEALTH=${health_code:-000} VERSION=${version_code:-000} SESSION=${session_code:-000} ENGINE=$engine STATUS=$live_status"

  if [ "$session_code" = 200 ] && [ "$live_status" = FAILED ]; then
    curl "${args[@]}" -H "X-Api-Key: $WAHA_API_KEY" -H 'Content-Type: application/json' \
      -X POST -d '{}' "https://$DOMAIN/api/sessions/nitu-travels/restart" >/dev/null 2>&1 || true
  fi

  if [ "$health_code" = 200 ] && [ "$version_code" = 200 ] && [ "$session_code" = 200 ] && [ "$engine" = NOWEB ]; then
    case "$live_status" in
      WORKING|SCAN_QR_CODE|PASSKEY_REQUIRED|PASSKEY_CONFIRMATION_REQUIRED)
        cutover_ok=1
        session_status="$live_status"
        break
        ;;
    esac
  fi
  sleep 10
done
[ "$cutover_ok" -eq 1 ] || { echo 'ERROR=Cutover verification failed'; false; }

cutover_verified=1
trap - ERR
oci compute instance action --instance-id "$old_id" --action SOFTSTOP >/dev/null || true

echo 'OLD_GATEWAY_SOFTSTOP_REQUESTED=yes'
echo "FINAL_INSTANCE_ID=$candidate_id"
echo "FINAL_PUBLIC_IP=$reserved_ip"
echo 'FINAL_ENGINE=NOWEB'
echo "FINAL_SESSION_STATUS=$session_status"
echo 'INSTALL_RESULT=success'
echo "FINISHED_AT=$(date -u +%FT%TZ)"
echo 'FINAL_BLUEGREEN_WAHA_V2_END'
