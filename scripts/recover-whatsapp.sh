#!/usr/bin/env bash
set -Eeuo pipefail

target_image="${1:?Target image is required}"
phone_number="${2:-918901066699}"
cd /opt/nitu-wa

admin_token="$(grep '^ADMIN_TOKEN=' .env | cut -d= -f2-)"
auth_root="$(pwd)/data/auth"
session_root="$auth_root/session-primary"

status_json() {
  curl -fsS --max-time 12 \
    -H "Authorization: Bearer $admin_token" \
    http://127.0.0.1:3000/admin/api/status 2>/dev/null || true
}

stop_gateway() {
  docker compose --env-file .env stop -t 30 gateway >/dev/null 2>&1 || true
  docker compose --env-file .env rm -f gateway >/dev/null 2>&1 || true
  docker rm -f nitu-wa-gateway >/dev/null 2>&1 || true
  sleep 3
}

clear_transient_profile_files() {
  mkdir -p "$auth_root"
  if [ -d "$session_root" ]; then
    find "$session_root" -type f \( \
      -name SingletonLock -o -name SingletonCookie -o -name SingletonSocket \
    \) -delete 2>/dev/null || true
    find "$session_root" -type d \( \
      -name Cache -o -name 'Code Cache' -o -name GPUCache -o \
      -name DawnCache -o -name GrShaderCache -o -name ShaderCache \
    \) -prune -exec rm -rf {} + 2>/dev/null || true
  fi
  chown -R 1000:1000 data 2>/dev/null || true
}

start_gateway() {
  docker compose --env-file .env up -d --force-recreate --no-deps gateway
}

wait_for_api() {
  local attempts="${1:-36}"
  for attempt in $(seq 1 "$attempts"); do
    body="$(status_json)"
    [ -n "$body" ] && return 0
    sleep 5
  done
  return 1
}

wait_for_pairing_or_ready() {
  local attempts="${1:-48}"
  for attempt in $(seq 1 "$attempts"); do
    body="$(status_json)"
    status="$(printf '%s' "$body" | jq -r '.status // empty' 2>/dev/null || true)"
    ready="$(printf '%s' "$body" | jq -r '.ready // false' 2>/dev/null || true)"
    has_qr="$(printf '%s' "$body" | jq -r '((.qrDataUrl // "") | length) > 20' 2>/dev/null || echo false)"
    has_code="$(printf '%s' "$body" | jq -r '((.pairingCode // "") | length) >= 8' 2>/dev/null || echo false)"
    echo "WAIT_ATTEMPT=$attempt STATUS=${status:-unreachable} READY=$ready HAS_QR=$has_qr HAS_CODE=$has_code"
    if [ "$ready" = true ] || { [ "$status" = awaiting_pairing ] && { [ "$has_qr" = true ] || [ "$has_code" = true ]; }; }; then
      return 0
    fi
    sleep 5
  done
  return 1
}

archive_current_session() {
  stop_gateway
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  if [ -d "$session_root" ]; then
    mv "$session_root" "$auth_root/session-primary.recovery-$stamp"
    echo "SESSION_ARCHIVED=session-primary.recovery-$stamp"
  fi
  find "$auth_root" -maxdepth 1 -type d -name 'session-primary.recovery-*' -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | awk 'NR>3 {sub(/^[^ ]+ /, ""); print}' \
    | xargs -r rm -rf
  clear_transient_profile_files
}

echo 'STEP=pull_exact_image'
for attempt in $(seq 1 40); do
  if docker pull "$target_image" >/tmp/nitu-wa-pull.log 2>&1; then
    break
  fi
  if [ "$attempt" -eq 40 ]; then
    cat /tmp/nitu-wa-pull.log >&2
    exit 21
  fi
  sleep 15
done
docker tag "$target_image" ghcr.io/nitutravels/nitu-whatsapp-gateway:latest

echo 'STEP=restart_with_preserved_session'
stop_gateway
clear_transient_profile_files
start_gateway
wait_for_api 36 || { docker logs --tail 160 nitu-wa-gateway >&2 || true; exit 22; }

if ! wait_for_pairing_or_ready 24; then
  body="$(status_json)"
  status="$(printf '%s' "$body" | jq -r '.status // empty' 2>/dev/null || true)"
  last_error="$(printf '%s' "$body" | jq -r '.lastError // ""' 2>/dev/null || true)"
  echo "PRESERVED_SESSION_STATUS=${status:-unknown}"
  echo "PRESERVED_SESSION_ERROR_PRESENT=$([ -n "$last_error" ] && echo yes || echo no)"
  echo 'STEP=archive_unusable_session_and_start_clean'
  archive_current_session
  start_gateway
  wait_for_api 36 || { docker logs --tail 200 nitu-wa-gateway >&2 || true; exit 23; }
  wait_for_pairing_or_ready 60 || { docker logs --tail 240 nitu-wa-gateway >&2 || true; exit 24; }
fi

body="$(status_json)"
status="$(printf '%s' "$body" | jq -r '.status // empty' 2>/dev/null || true)"
ready="$(printf '%s' "$body" | jq -r '.ready // false' 2>/dev/null || true)"
if [ "$ready" != true ] && [ "$status" = awaiting_pairing ]; then
  echo 'STEP=request_phone_pairing_code'
  pair_response="$(curl -sS --max-time 90 -X POST \
    -H "Authorization: Bearer $admin_token" \
    -H 'content-type: application/json' \
    --data "{\"phoneNumber\":\"$phone_number\"}" \
    http://127.0.0.1:3000/admin/api/pair || true)"
  pair_ok="$(printf '%s' "$pair_response" | jq -r '((.pairingCode // "") | length) >= 8' 2>/dev/null || echo false)"
  pair_error="$(printf '%s' "$pair_response" | jq -r '.error // ""' 2>/dev/null || true)"
  echo "PAIR_REQUEST_OK=$pair_ok"
  echo "PAIR_REQUEST_ERROR_PRESENT=$([ -n "$pair_error" ] && echo yes || echo no)"
  sleep 5
fi

final="$(status_json)"
printf '%s' "$final" | jq -c '{status,ready,account,hasQr:((.qrDataUrl // "")|length>20),hasPairingCode:((.pairingCode // "")|length>=8),lastErrorPresent:((.lastError // "")|length>0),queue}'
final_ready="$(printf '%s' "$final" | jq -r '.ready // false')"
final_status="$(printf '%s' "$final" | jq -r '.status // empty')"
final_qr="$(printf '%s' "$final" | jq -r '((.qrDataUrl // "") | length) > 20')"
final_code="$(printf '%s' "$final" | jq -r '((.pairingCode // "") | length) >= 8')"
if [ "$final_ready" = true ] || { [ "$final_status" = awaiting_pairing ] && { [ "$final_qr" = true ] || [ "$final_code" = true ]; }; }; then
  exit 0
fi

docker logs --tail 240 nitu-wa-gateway >&2 || true
exit 25
