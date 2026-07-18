#!/usr/bin/env bash
set -Eeuo pipefail

: "${COMPARTMENT_OCID:?COMPARTMENT_OCID is required}"
: "${DOMAIN:?DOMAIN is required}"
: "${ADMIN_TOKEN:?ADMIN_TOKEN is required}"
: "${IMAGE:?IMAGE is required}"

echo 'CONTROL_PLANE_RECOVERY_BEGIN'
echo "SOURCE_COMMIT=${GITHUB_SHA:-unknown}"
echo "TARGET_IMAGE=$IMAGE"

echo 'STEP=wait_for_exact_image'
image_available=0
for attempt in $(seq 1 60); do
  if docker manifest inspect "$IMAGE" >/dev/null 2>&1; then
    image_available=1
    echo "IMAGE_AVAILABLE_AT_ATTEMPT=$attempt"
    break
  fi
  sleep 10
done
if [ "$image_available" -ne 1 ]; then
  echo 'RECOVERY_RESULT=failed'
  echo 'ERROR=Exact container image was not published within 10 minutes.'
  exit 11
fi

echo 'STEP=resolve_instance'
instance_id="$(oci compute instance list \
  --compartment-id "$COMPARTMENT_OCID" \
  --display-name nitu-whatsapp-gateway \
  --all \
  --query 'data[?"lifecycle-state"!=`TERMINATED`].id | [0]' \
  --raw-output)"
if [[ ! "$instance_id" =~ ^ocid1\.instance\. ]]; then
  echo 'RECOVERY_RESULT=failed'
  echo 'ERROR=Gateway instance was not found.'
  exit 12
fi
echo "INSTANCE_ID=$instance_id"

oci compute instance get --instance-id "$instance_id" --output json > /tmp/instance-before.json
echo -n 'INSTANCE_BEFORE='
jq -c '.data | {lifecycleState:."lifecycle-state",shape,agentConfig:."agent-config"}' /tmp/instance-before.json
echo

vnic_id="$(oci compute vnic-attachment list \
  --compartment-id "$COMPARTMENT_OCID" \
  --instance-id "$instance_id" \
  --all \
  --query 'data[?"lifecycle-state"==`ATTACHED`]."vnic-id" | [0]' \
  --raw-output)"
public_ip=''
if [[ "$vnic_id" =~ ^ocid1\.vnic\. ]]; then
  public_ip="$(oci network vnic get --vnic-id "$vnic_id" --query 'data."public-ip"' --raw-output)"
fi
echo "PUBLIC_IP=${public_ip:-unresolved}"
echo "DNS_A=$(dig +short A "$DOMAIN" | paste -sd, -)"

echo 'STEP=pin_exact_image_in_instance_metadata'
current_env_b64="$(jq -r '.data.metadata.gateway_env_b64 // empty' /tmp/instance-before.json)"
if [ -n "$current_env_b64" ]; then
  printf '%s' "$current_env_b64" | base64 --decode > /tmp/gateway.env
  if grep -q '^GATEWAY_IMAGE=' /tmp/gateway.env; then
    sed -i "s|^GATEWAY_IMAGE=.*$|GATEWAY_IMAGE=$IMAGE|" /tmp/gateway.env
  else
    printf 'GATEWAY_IMAGE=%s\n' "$IMAGE" | cat - /tmp/gateway.env > /tmp/gateway.env.new
    mv /tmp/gateway.env.new /tmp/gateway.env
  fi
  updated_env_b64="$(base64 -w0 /tmp/gateway.env)"
  jq --arg updated "$updated_env_b64" '.data.metadata | .gateway_env_b64=$updated' \
    /tmp/instance-before.json > /tmp/metadata-updated.json
  oci compute instance update \
    --instance-id "$instance_id" \
    --metadata file:///tmp/metadata-updated.json \
    --force >/dev/null
  echo 'METADATA_IMAGE_PINNED=yes'
else
  echo 'METADATA_IMAGE_PINNED=no'
fi

echo 'STEP=enable_run_command_plugin'
cat > /tmp/agent-config.json <<'JSON'
{
  "is-agent-disabled": false,
  "is-management-disabled": false,
  "are-all-plugins-disabled": false,
  "plugins-config": [
    {
      "name": "Compute Instance Run Command",
      "desiredState": "ENABLED"
    }
  ]
}
JSON
oci compute instance update \
  --instance-id "$instance_id" \
  --agent-config file:///tmp/agent-config.json \
  --force >/dev/null

echo 'STEP=soft_reset_instance'
oci compute instance action --instance-id "$instance_id" --action SOFTRESET >/dev/null
sleep 30
running_stable=0
for attempt in $(seq 1 100); do
  lifecycle="$(oci compute instance get \
    --instance-id "$instance_id" \
    --query 'data."lifecycle-state"' \
    --raw-output)"
  echo "POWER_ATTEMPT=$attempt STATE=$lifecycle"
  if [ "$lifecycle" = RUNNING ]; then
    running_stable=$((running_stable + 1))
    if [ "$running_stable" -ge 3 ]; then
      break
    fi
  else
    running_stable=0
  fi
  sleep 10
done
if [ "$running_stable" -lt 3 ]; then
  echo 'RECOVERY_RESULT=failed'
  echo 'ERROR=Instance did not return to a stable RUNNING state after soft reset.'
  exit 13
fi

echo 'STEP=wait_for_gateway_and_systemd_update'
health_ok=0
status_ok=0
final_status='{}'
for attempt in $(seq 1 120); do
  rm -f /tmp/health.json /tmp/status.json
  health_code=000
  status_code=000
  if [[ "$public_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    health_code="$(curl -sS --connect-timeout 8 --max-time 20 \
      --resolve "$DOMAIN:443:$public_ip" \
      -o /tmp/health.json -w '%{http_code}' \
      "https://$DOMAIN/healthz" || true)"
    status_code="$(curl -sS --connect-timeout 8 --max-time 20 \
      --resolve "$DOMAIN:443:$public_ip" \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -o /tmp/status.json -w '%{http_code}' \
      "https://$DOMAIN/admin/api/status" || true)"
  else
    health_code="$(curl -sS --connect-timeout 8 --max-time 20 \
      -o /tmp/health.json -w '%{http_code}' \
      "https://$DOMAIN/healthz" || true)"
    status_code="$(curl -sS --connect-timeout 8 --max-time 20 \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -o /tmp/status.json -w '%{http_code}' \
      "https://$DOMAIN/admin/api/status" || true)"
  fi

  status="$(jq -r '.status // "unknown"' /tmp/status.json 2>/dev/null || echo unknown)"
  ready="$(jq -r '(.operationalReady // .ready // false)' /tmp/status.json 2>/dev/null || echo false)"
  provider_state="$(jq -r '.providerState // "unknown"' /tmp/status.json 2>/dev/null || echo unknown)"
  has_qr="$(jq -r '((.qrDataUrl // "") | length) > 20' /tmp/status.json 2>/dev/null || echo false)"
  has_code="$(jq -r '((.pairingCode // "") | length) >= 8' /tmp/status.json 2>/dev/null || echo false)"
  echo "VERIFY_ATTEMPT=$attempt HEALTH_HTTP=${health_code:-000} STATUS_HTTP=${status_code:-000} STATUS=$status READY=$ready PROVIDER_STATE=$provider_state HAS_QR=$has_qr HAS_CODE=$has_code"

  if [ "$health_code" = 200 ]; then
    health_ok=1
  fi
  if [ "$status_code" = 200 ] && [ -s /tmp/status.json ]; then
    final_status="$(cat /tmp/status.json)"
    if [ "$ready" = true ] || { [ "$status" = awaiting_pairing ] && { [ "$has_qr" = true ] || [ "$has_code" = true ]; }; }; then
      status_ok=1
      break
    fi
  fi
  sleep 10
done

echo -n 'FINAL_GATEWAY_STATUS='
printf '%s' "$final_status" | jq -c '{
  status,
  ready,
  operationalReady,
  providerState,
  account,
  recoveryInProgress,
  pairingInProgress,
  queue,
  lastErrorPresent: ((.lastError // "") | length > 0)
}' 2>/dev/null || printf '%s\n' "$final_status"

echo 'STEP=verify_run_command_plugin_separately'
plugin_status="$(oci instance-agent plugin get \
  --compartment-id "$COMPARTMENT_OCID" \
  --instanceagent-id "$instance_id" \
  --plugin-name 'Compute Instance Run Command' \
  --query 'data.status' \
  --raw-output 2>/dev/null || echo UNKNOWN)"
echo "RUN_COMMAND_PLUGIN_STATUS=$plugin_status"

run_command_result='not-tested'
if [ "$plugin_status" = RUNNING ]; then
  jq -n \
    --arg text "echo RUN_COMMAND_OK; systemctl is-active oracle-cloud-agent; systemctl is-active docker; cd /opt/nitu-wa && docker compose ps --format json" \
    '{source:{sourceType:"TEXT",text:$text},output:{outputType:"TEXT"}}' > /tmp/command-content.json
  jq -n --arg id "$instance_id" '{instanceId:$id}' > /tmp/command-target.json
  command_id="$(oci instance-agent command create \
    --compartment-id "$COMPARTMENT_OCID" \
    --content file:///tmp/command-content.json \
    --target file:///tmp/command-target.json \
    --timeout-in-seconds 180 \
    --display-name 'Nitu gateway post-reboot diagnostic' \
    --query 'data.id' --raw-output)"
  for attempt in $(seq 1 24); do
    execution_json="$(oci instance-agent command-execution get \
      --command-id "$command_id" \
      --instance-id "$instance_id" \
      --output json)"
    execution_state="$(jq -r '.data."lifecycle-state" // empty' <<<"$execution_json")"
    echo "RUN_COMMAND_ATTEMPT=$attempt STATE=$execution_state"
    case "$execution_state" in
      SUCCEEDED)
        run_command_result=success
        echo -n 'RUN_COMMAND_OUTPUT='
        jq -c '.data.content // {}' <<<"$execution_json"
        echo
        break
        ;;
      FAILED|CANCELED|TIMED_OUT)
        run_command_result="$execution_state"
        echo -n 'RUN_COMMAND_OUTPUT='
        jq -c '.data.content // {}' <<<"$execution_json"
        echo
        break
        ;;
    esac
    sleep 5
  done
  if [ "$run_command_result" = not-tested ]; then
    run_command_result=accepted-but-not-executed
    oci instance-agent command cancel --command-id "$command_id" --force >/dev/null 2>&1 || true
  fi
fi
echo "RUN_COMMAND_RESULT=$run_command_result"

if [ "$health_ok" -eq 1 ] && [ "$status_ok" -eq 1 ]; then
  echo 'RECOVERY_RESULT=success'
  if [ "$run_command_result" != success ]; then
    echo 'MANAGEMENT_PLANE=degraded'
    echo 'MANAGEMENT_NOTE=Gateway recovered independently; Oracle Run Command still requires agent investigation.'
  else
    echo 'MANAGEMENT_PLANE=healthy'
  fi
  echo 'CONTROL_PLANE_RECOVERY_END'
  exit 0
fi

echo 'RECOVERY_RESULT=failed'
if [ "$health_ok" -ne 1 ]; then
  echo 'ERROR=Gateway health endpoint did not recover after the control-plane reboot.'
else
  echo 'ERROR=Gateway is online but neither operationally ready nor awaiting usable pairing.'
fi
echo 'CONTROL_PLANE_RECOVERY_END'
exit 14
