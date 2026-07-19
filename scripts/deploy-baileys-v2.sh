#!/usr/bin/env bash
set -Eeuo pipefail

: "${COMPARTMENT_OCID:?COMPARTMENT_OCID is required}"
: "${DOMAIN:?DOMAIN is required}"
: "${ADMIN_TOKEN:?ADMIN_TOKEN is required}"
: "${IMAGE:?IMAGE is required}"

echo 'BAILEYS_V2_DEPLOY_BEGIN'
echo "SOURCE_COMMIT=${GITHUB_SHA:-unknown}"
echo "TARGET_IMAGE=$IMAGE"

for attempt in $(seq 1 60); do
  if docker manifest inspect "$IMAGE" >/dev/null 2>&1; then
    echo "IMAGE_AVAILABLE_AT_ATTEMPT=$attempt"
    break
  fi
  if [ "$attempt" -eq 60 ]; then
    echo 'DEPLOY_RESULT=failed'
    echo 'ERROR=Exact image was not published within ten minutes.'
    exit 11
  fi
  sleep 10
done

instance_id="$(oci compute instance list \
  --compartment-id "$COMPARTMENT_OCID" \
  --display-name nitu-whatsapp-gateway \
  --all \
  --query 'data[?"lifecycle-state"!=`TERMINATED`].id | [0]' \
  --raw-output)"
if [[ ! "$instance_id" =~ ^ocid1\.instance\. ]]; then
  echo 'DEPLOY_RESULT=failed'
  echo 'ERROR=Gateway instance was not found.'
  exit 12
fi
echo "INSTANCE_ID=$instance_id"

oci compute instance get --instance-id "$instance_id" --output json > /tmp/instance.json
lifecycle="$(jq -r '.data."lifecycle-state" // empty' /tmp/instance.json)"
echo "INITIAL_LIFECYCLE=$lifecycle"

case "$lifecycle" in
  STOPPED)
    oci compute instance action --instance-id "$instance_id" --action START >/dev/null
    echo 'START_REQUESTED=yes'
    ;;
  STOPPING)
    for attempt in $(seq 1 60); do
      lifecycle="$(oci compute instance get --instance-id "$instance_id" --query 'data."lifecycle-state"' --raw-output)"
      echo "STOP_WAIT_ATTEMPT=$attempt STATE=$lifecycle"
      [ "$lifecycle" = STOPPED ] && break
      sleep 10
    done
    [ "$lifecycle" = STOPPED ] || { echo 'DEPLOY_RESULT=failed'; echo 'ERROR=Instance did not finish stopping.'; exit 14; }
    oci compute instance action --instance-id "$instance_id" --action START >/dev/null
    echo 'START_REQUESTED=yes'
    ;;
  RUNNING|STARTING)
    echo 'REBOOT_SKIPPED=yes'
    ;;
  *)
    echo 'DEPLOY_RESULT=failed'
    echo "ERROR=Unsupported instance lifecycle state: $lifecycle"
    exit 14
    ;;
esac

stable=0
for attempt in $(seq 1 100); do
  lifecycle="$(oci compute instance get --instance-id "$instance_id" --query 'data."lifecycle-state"' --raw-output)"
  echo "POWER_ATTEMPT=$attempt STATE=$lifecycle"
  if [ "$lifecycle" = RUNNING ]; then
    stable=$((stable + 1))
    [ "$stable" -ge 3 ] && break
  else
    stable=0
  fi
  sleep 10
done
if [ "$stable" -lt 3 ]; then
  echo 'DEPLOY_RESULT=failed'
  echo 'ERROR=Instance did not reach a stable RUNNING state.'
  exit 14
fi

oci compute instance get --instance-id "$instance_id" --output json > /tmp/instance.json
vnic_id="$(oci compute vnic-attachment list \
  --compartment-id "$COMPARTMENT_OCID" \
  --instance-id "$instance_id" --all \
  --query 'data[?"lifecycle-state"==`ATTACHED`]."vnic-id" | [0]' \
  --raw-output)"
public_ip=''
if [[ "$vnic_id" =~ ^ocid1\.vnic\. ]]; then
  public_ip="$(oci network vnic get --vnic-id "$vnic_id" --query 'data."public-ip"' --raw-output)"
fi
if [[ ! "$public_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'DEPLOY_RESULT=failed'
  echo 'ERROR=Gateway VNIC has no usable public IPv4 address.'
  exit 15
fi
echo "PUBLIC_IP=$public_ip"

current_env_b64="$(jq -r '.data.metadata.gateway_env_b64 // empty' /tmp/instance.json)"
if [ -z "$current_env_b64" ]; then
  echo 'DEPLOY_RESULT=failed'
  echo 'ERROR=gateway_env_b64 metadata is absent; refusing to overwrite instance metadata.'
  exit 13
fi
printf '%s' "$current_env_b64" | base64 --decode > /tmp/gateway.env
if grep -q '^GATEWAY_IMAGE=' /tmp/gateway.env; then
  sed -i "s|^GATEWAY_IMAGE=.*$|GATEWAY_IMAGE=$IMAGE|" /tmp/gateway.env
else
  printf 'GATEWAY_IMAGE=%s\n' "$IMAGE" | cat - /tmp/gateway.env > /tmp/gateway.env.new
  mv /tmp/gateway.env.new /tmp/gateway.env
fi
updated_env_b64="$(base64 -w0 /tmp/gateway.env)"
jq --arg updated "$updated_env_b64" '.data.metadata | .gateway_env_b64=$updated' \
  /tmp/instance.json > /tmp/metadata.json
oci compute instance update --instance-id "$instance_id" --metadata file:///tmp/metadata.json --force >/dev/null
echo 'METADATA_IMAGE_PINNED=yes'
echo 'ROLLOUT_MODE=systemd_metadata_sync_no_reboot'

cat > /tmp/agent-config.json <<'JSON'
{
  "is-agent-disabled": false,
  "is-management-disabled": false,
  "are-all-plugins-disabled": false,
  "plugins-config": [{"name":"Compute Instance Run Command","desiredState":"ENABLED"}]
}
JSON
oci compute instance update --instance-id "$instance_id" --agent-config file:///tmp/agent-config.json --force >/dev/null || true

health_ok=0
state_ok=0
final_status='{}'
for attempt in $(seq 1 150); do
  rm -f /tmp/health.json /tmp/status.json
  curl_args=(--silent --show-error --connect-timeout 8 --max-time 20 --resolve "$DOMAIN:443:$public_ip")
  health_code="$(curl "${curl_args[@]}" -o /tmp/health.json -w '%{http_code}' "https://$DOMAIN/healthz" || true)"
  status_code="$(curl "${curl_args[@]}" -H "Authorization: Bearer $ADMIN_TOKEN" \
    -o /tmp/status.json -w '%{http_code}' "https://$DOMAIN/admin/api/status" || true)"
  status="$(jq -r '.status // "unknown"' /tmp/status.json 2>/dev/null || echo unknown)"
  phase="$(jq -r '.phase // "unknown"' /tmp/status.json 2>/dev/null || echo unknown)"
  engine="$(jq -r '.engine // "unknown"' /tmp/status.json 2>/dev/null || echo unknown)"
  ready="$(jq -r '.ready // false' /tmp/status.json 2>/dev/null || echo false)"
  registered="$(jq -r '.registered // false' /tmp/status.json 2>/dev/null || echo false)"
  has_qr="$(jq -r '((.qrDataUrl // "") | length) > 20' /tmp/status.json 2>/dev/null || echo false)"
  has_code="$(jq -r '((.pairingCode // "") | length) >= 8' /tmp/status.json 2>/dev/null || echo false)"
  echo "VERIFY_ATTEMPT=$attempt HEALTH_HTTP=${health_code:-000} STATUS_HTTP=${status_code:-000} ENGINE=$engine STATUS=$status PHASE=$phase READY=$ready REGISTERED=$registered HAS_QR=$has_qr HAS_CODE=$has_code"

  [ "$health_code" = 200 ] && health_ok=1
  if [ "$status_code" = 200 ] && [ -s /tmp/status.json ]; then
    final_status="$(cat /tmp/status.json)"
    if [ "$engine" = baileys-websocket ] && { [ "$ready" = true ] || { [ "$phase" = pairing ] && { [ "$has_qr" = true ] || [ "$has_code" = true ]; }; }; }; then
      state_ok=1
      break
    fi
  fi
  sleep 10
done

echo -n 'FINAL_GATEWAY_STATUS='
printf '%s' "$final_status" | jq -c '{engine,engineVersion,status,phase,ready,connected,registered,account,hasQr:((.qrDataUrl // "")|length>20),hasPairingCode:((.pairingCode // "")|length>=8),queue,worker,lastErrorPresent:((.lastError // "")|length>0)}' 2>/dev/null || printf '%s\n' "$final_status"

if [ "$health_ok" -eq 1 ] && [ "$state_ok" -eq 1 ]; then
  echo 'DEPLOY_RESULT=success'
  echo 'BAILEYS_V2_DEPLOY_END'
  exit 0
fi

echo 'DEPLOY_RESULT=failed'
if [ "$health_ok" -ne 1 ]; then
  echo 'ERROR=Gateway health endpoint did not recover through the current public IP.'
else
  echo 'ERROR=Gateway is online but neither ready nor presenting a usable pairing state.'
fi
echo 'BAILEYS_V2_DEPLOY_END'
exit 16
