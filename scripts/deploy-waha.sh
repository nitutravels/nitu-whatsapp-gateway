#!/usr/bin/env bash
set -Eeuo pipefail

: "${COMPARTMENT_OCID:?COMPARTMENT_OCID is required}"
: "${DOMAIN:?DOMAIN is required}"
: "${API_KEY:?API_KEY is required}"
: "${IMAGE:?IMAGE is required}"

SESSION_NAME="${SESSION_NAME:-nitu-travels}"

echo 'WAHA_DEPLOY_BEGIN'
echo "SOURCE_COMMIT=${GITHUB_SHA:-unknown}"
echo "TARGET_IMAGE=$IMAGE"
echo "SESSION_NAME=$SESSION_NAME"

# The immutable wrapper image can build concurrently with this workflow.
for attempt in $(seq 1 90); do
  if docker manifest inspect "$IMAGE" >/dev/null 2>&1; then
    echo "IMAGE_AVAILABLE_AT_ATTEMPT=$attempt"
    break
  fi
  if [ "$attempt" -eq 90 ]; then
    echo 'DEPLOY_RESULT=failed'
    echo 'ERROR=Exact WAHA image was not published within fifteen minutes.'
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
  echo 'ERROR=Oracle gateway instance was not found.'
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
    [ "$lifecycle" = STOPPED ] || { echo 'DEPLOY_RESULT=failed'; echo 'ERROR=Instance did not finish stopping.'; exit 13; }
    oci compute instance action --instance-id "$instance_id" --action START >/dev/null
    echo 'START_REQUESTED=yes'
    ;;
  RUNNING|STARTING)
    echo 'REBOOT_SKIPPED=yes'
    ;;
  *)
    echo 'DEPLOY_RESULT=failed'
    echo "ERROR=Unsupported instance lifecycle state: $lifecycle"
    exit 13
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
[ "$stable" -ge 3 ] || { echo 'DEPLOY_RESULT=failed'; echo 'ERROR=Instance did not reach stable RUNNING state.'; exit 14; }

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

# Preserve all current production secrets and settings. Only the immutable
# image reference changes; the existing systemd metadata-sync service performs
# the container replacement without rebooting the VM.
current_env_b64="$(jq -r '.data.metadata.gateway_env_b64 // empty' /tmp/instance.json)"
if [ -z "$current_env_b64" ]; then
  echo 'DEPLOY_RESULT=failed'
  echo 'ERROR=gateway_env_b64 metadata is absent; refusing to overwrite instance metadata.'
  exit 16
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

curl_base=(--silent --show-error --connect-timeout 8 --max-time 25 --resolve "$DOMAIN:443:$public_ip")
health_ok=0
session_ok=0
session_created=0
final_status='{}'

for attempt in $(seq 1 180); do
  rm -f /tmp/health.json /tmp/session.json /tmp/create.json
  health_code="$(curl "${curl_base[@]}" -o /tmp/health.json -w '%{http_code}' "https://$DOMAIN/health" || true)"
  session_code="$(curl "${curl_base[@]}" -H "X-Api-Key: $API_KEY" \
    -o /tmp/session.json -w '%{http_code}' "https://$DOMAIN/api/sessions/$SESSION_NAME" || true)"

  status="$(jq -r '.status // "unknown"' /tmp/session.json 2>/dev/null || echo unknown)"
  engine="$(jq -r '.engine.engine // .engine.name // "unknown"' /tmp/session.json 2>/dev/null || echo unknown)"
  has_me="$(jq -r '((.me.id // "") | length) > 3' /tmp/session.json 2>/dev/null || echo false)"
  echo "VERIFY_ATTEMPT=$attempt HEALTH_HTTP=${health_code:-000} SESSION_HTTP=${session_code:-000} STATUS=$status ENGINE=$engine HAS_ME=$has_me"

  [ "$health_code" = 200 ] && health_ok=1

  if [ "$health_code" = 200 ] && [ "$session_code" = 404 ] && [ "$session_created" -eq 0 ]; then
    create_code="$(curl "${curl_base[@]}" -H "X-Api-Key: $API_KEY" \
      -H 'Content-Type: application/json' -X POST \
      --data "{\"name\":\"$SESSION_NAME\"}" \
      -o /tmp/create.json -w '%{http_code}' "https://$DOMAIN/api/sessions" || true)"
    echo "SESSION_CREATE_HTTP=${create_code:-000}"
    if [[ "$create_code" =~ ^20[0-9]$ ]] || [ "$create_code" = 409 ]; then
      session_created=1
    fi
  elif [ "$session_code" = 200 ]; then
    final_status="$(cat /tmp/session.json)"
    case "$status" in
      WORKING|SCAN_QR_CODE|PASSKEY_REQUIRED|PASSKEY_CONFIRMATION_REQUIRED)
        session_ok=1
        break
        ;;
      STOPPED)
        start_code="$(curl "${curl_base[@]}" -H "X-Api-Key: $API_KEY" \
          -H 'Content-Type: application/json' -X POST --data '{}' \
          -o /tmp/start.json -w '%{http_code}' "https://$DOMAIN/api/sessions/$SESSION_NAME/start" || true)"
        echo "SESSION_START_HTTP=${start_code:-000}"
        ;;
      FAILED)
        restart_code="$(curl "${curl_base[@]}" -H "X-Api-Key: $API_KEY" \
          -H 'Content-Type: application/json' -X POST --data '{}' \
          -o /tmp/restart.json -w '%{http_code}' "https://$DOMAIN/api/sessions/$SESSION_NAME/restart" || true)"
        echo "SESSION_RESTART_HTTP=${restart_code:-000}"
        ;;
    esac
  fi
  sleep 10
done

echo -n 'FINAL_WAHA_STATUS='
printf '%s' "$final_status" | jq -c '{name,status,engine:(.engine.engine // .engine.name // null),me:(if .me then {id:.me.id,pushName:.me.pushName} else null end)}' 2>/dev/null || printf '%s\n' "$final_status"

if [ "$health_ok" -eq 1 ] && [ "$session_ok" -eq 1 ]; then
  echo 'DEPLOY_RESULT=success'
  echo 'WAHA_DEPLOY_END'
  exit 0
fi

echo 'DEPLOY_RESULT=failed'
if [ "$health_ok" -ne 1 ]; then
  echo 'ERROR=WAHA health endpoint did not recover through the current public IP.'
else
  echo 'ERROR=WAHA is online but the nitu-travels session did not reach a usable pairing or WORKING state.'
fi
echo 'WAHA_DEPLOY_END'
exit 17
