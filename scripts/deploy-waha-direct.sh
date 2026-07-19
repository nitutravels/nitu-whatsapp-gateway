#!/usr/bin/env bash
set -Eeuo pipefail

: "${COMPARTMENT_OCID:?COMPARTMENT_OCID is required}"
: "${DOMAIN:?DOMAIN is required}"
: "${API_KEY:?API_KEY is required}"

WAHA_IMAGE="${WAHA_IMAGE:-devlikeapro/waha:noweb-arm-2026.7.1}"
SESSION_NAME="${SESSION_NAME:-nitu-travels}"

mkdir -p docs
exec > >(tee docs/waha-direct-install-result.txt) 2>&1
trap 'code=$?; echo "INSTALL_EXIT_CODE=$code"; echo "WAHA_DIRECT_INSTALL_END"' EXIT

echo 'WAHA_DIRECT_INSTALL_BEGIN'
echo "STARTED_AT=$(date -u +%FT%TZ)"
echo "WAHA_IMAGE=$WAHA_IMAGE"

instance_id="$(oci compute instance list \
  --compartment-id "$COMPARTMENT_OCID" \
  --display-name nitu-whatsapp-gateway --all \
  --query 'data[?"lifecycle-state"!=`TERMINATED`].id | [0]' \
  --raw-output)"
[[ "$instance_id" =~ ^ocid1\.instance\. ]] || { echo 'ERROR=Oracle instance not found'; exit 10; }
echo "INSTANCE_ID=$instance_id"

lifecycle="$(oci compute instance get --instance-id "$instance_id" --query 'data."lifecycle-state"' --raw-output)"
echo "INITIAL_LIFECYCLE=$lifecycle"
if [ "$lifecycle" = STOPPED ]; then
  oci compute instance action --instance-id "$instance_id" --action START >/dev/null
  echo 'START_REQUESTED=yes'
elif [ "$lifecycle" != RUNNING ] && [ "$lifecycle" != STARTING ]; then
  echo "ERROR=Unsupported lifecycle $lifecycle"
  exit 11
else
  echo 'REBOOT_SKIPPED=yes'
fi

for attempt in $(seq 1 60); do
  lifecycle="$(oci compute instance get --instance-id "$instance_id" --query 'data."lifecycle-state"' --raw-output)"
  echo "POWER_ATTEMPT=$attempt STATE=$lifecycle"
  [ "$lifecycle" = RUNNING ] && break
  sleep 5
done
[ "$lifecycle" = RUNNING ] || { echo 'ERROR=Instance did not reach RUNNING'; exit 12; }

oci compute instance get --instance-id "$instance_id" --output json > /tmp/instance.json
vnic_id="$(oci compute vnic-attachment list \
  --compartment-id "$COMPARTMENT_OCID" --instance-id "$instance_id" --all \
  --query 'data[?"lifecycle-state"==`ATTACHED`]."vnic-id" | [0]' --raw-output)"
public_ip="$(oci network vnic get --vnic-id "$vnic_id" --query 'data."public-ip"' --raw-output)"
[[ "$public_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'ERROR=No public IPv4'; exit 13; }
echo "PUBLIC_IP=$public_ip"

current_env_b64="$(jq -r '.data.metadata.gateway_env_b64 // empty' /tmp/instance.json)"
[ -n "$current_env_b64" ] || { echo 'ERROR=gateway_env_b64 metadata missing'; exit 14; }
printf '%s' "$current_env_b64" | base64 --decode > /tmp/gateway.env

set_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" /tmp/gateway.env; then
    sed -i "s|^${key}=.*$|${key}=${value}|" /tmp/gateway.env
  else
    printf '%s=%s\n' "$key" "$value" >> /tmp/gateway.env
  fi
}

admin_token="$(sed -n 's/^ADMIN_TOKEN=//p' /tmp/gateway.env | tail -1)"
webhook_url="$(sed -n 's/^WEBHOOK_URL=//p' /tmp/gateway.env | tail -1)"
webhook_secret="$(sed -n 's/^WEBHOOK_SECRET=//p' /tmp/gateway.env | tail -1)"

set_env GATEWAY_IMAGE "$WAHA_IMAGE"
set_env WAHA_API_KEY "$API_KEY"
set_env WHATSAPP_DEFAULT_ENGINE NOWEB
set_env WAHA_DASHBOARD_ENABLED true
set_env WAHA_DASHBOARD_USERNAME admin
[ -n "$admin_token" ] && set_env WAHA_DASHBOARD_PASSWORD "$admin_token"
set_env WHATSAPP_SWAGGER_ENABLED false
set_env WAHA_PRINT_QR False
set_env WAHA_WORKER_RESTART_SESSIONS True
set_env WHATSAPP_RESTART_ALL_SESSIONS True
set_env WAHA_LOCAL_STORE_BASE_DIR /data/waha-sessions
set_env WHATSAPP_FILES_FOLDER /data/waha-media
set_env WHATSAPP_FILES_LIFETIME 300
set_env WHATSAPP_DOWNLOAD_MEDIA false
set_env WAHA_LOG_FORMAT JSON
set_env WAHA_LOG_LEVEL info
set_env TZ Asia/Kolkata
set_env WAHA_PUBLIC_URL "https://$DOMAIN"
set_env WAHA_BASE_URL "https://$DOMAIN"
if [ -n "$webhook_url" ]; then
  set_env WHATSAPP_HOOK_URL "$webhook_url"
  set_env WHATSAPP_HOOK_EVENTS 'message.ack,session.status'
  set_env WHATSAPP_HOOK_RETRIES_POLICY exponential
  set_env WHATSAPP_HOOK_RETRIES_DELAY_SECONDS 2
  set_env WHATSAPP_HOOK_RETRIES_ATTEMPTS 8
fi
[ -n "$webhook_secret" ] && set_env WHATSAPP_HOOK_HMAC_KEY "$webhook_secret"

updated_env_b64="$(base64 -w0 /tmp/gateway.env)"
jq --arg updated "$updated_env_b64" '.data.metadata | .gateway_env_b64=$updated' \
  /tmp/instance.json > /tmp/metadata.json
oci compute instance update --instance-id "$instance_id" \
  --metadata file:///tmp/metadata.json --force >/dev/null
echo 'METADATA_UPDATED=yes'
echo 'ROLLOUT_MODE=no_build_no_reboot_official_image'

curl_base=(--silent --show-error --connect-timeout 6 --max-time 15 --resolve "$DOMAIN:443:$public_ip")
health_ok=0
session_ok=0
for attempt in $(seq 1 90); do
  health_code="$(curl "${curl_base[@]}" -o /tmp/health.json -w '%{http_code}' "https://$DOMAIN/health" || true)"
  session_code="$(curl "${curl_base[@]}" -H "X-Api-Key: $API_KEY" \
    -o /tmp/session.json -w '%{http_code}' "https://$DOMAIN/api/sessions/$SESSION_NAME" || true)"
  status="$(jq -r '.status // "unknown"' /tmp/session.json 2>/dev/null || echo unknown)"
  has_me="$(jq -r '((.me.id // "") | length) > 3' /tmp/session.json 2>/dev/null || echo false)"
  echo "VERIFY_ATTEMPT=$attempt HEALTH_HTTP=${health_code:-000} SESSION_HTTP=${session_code:-000} STATUS=$status HAS_ME=$has_me"
  [ "$health_code" = 200 ] && health_ok=1

  if [ "$health_code" = 200 ] && [ "$session_code" = 404 ]; then
    create_code="$(curl "${curl_base[@]}" -H "X-Api-Key: $API_KEY" \
      -H 'Content-Type: application/json' -X POST \
      --data '{"name":"nitu-travels","config":{"noweb":{"markOnline":false}}}' \
      -o /tmp/create.json -w '%{http_code}' "https://$DOMAIN/api/sessions" || true)"
    echo "SESSION_CREATE_HTTP=$create_code"
  elif [ "$session_code" = 200 ]; then
    case "$status" in
      WORKING|SCAN_QR_CODE|PASSKEY_REQUIRED|PASSKEY_CONFIRMATION_REQUIRED)
        session_ok=1
        break
        ;;
      STOPPED)
        start_code="$(curl "${curl_base[@]}" -H "X-Api-Key: $API_KEY" \
          -H 'Content-Type: application/json' -X POST --data '{}' \
          -o /tmp/start.json -w '%{http_code}' \
          "https://$DOMAIN/api/sessions/$SESSION_NAME/start" || true)"
        echo "SESSION_START_HTTP=$start_code"
        ;;
    esac
  fi
  sleep 5
done

echo -n 'FINAL_SESSION='
jq -c '{name,status,engine:(.engine.engine // .engine.name // null),me:(if .me then {id:.me.id,pushName:.me.pushName} else null end)}' \
  /tmp/session.json 2>/dev/null || cat /tmp/session.json 2>/dev/null || true

if [ "$health_ok" -eq 1 ] && [ "$session_ok" -eq 1 ]; then
  echo 'INSTALL_RESULT=success'
  exit 0
fi

echo 'INSTALL_RESULT=failed'
exit 20
