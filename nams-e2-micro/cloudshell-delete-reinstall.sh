#!/usr/bin/env bash
set -Eeuo pipefail

REGION="${OCI_REGION:-ap-mumbai-1}"
TARGET_NAME="${NAMS_INSTANCE_NAME:-instance-20260723-2200}"
EXPECTED_IP="${NAMS_EXPECTED_IP:-130.210.31.138}"
DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}"
ONE_CLICK_REF="c4fd1e9e3e177ef728abe382a30c1f9e66b36bb0"
ONE_CLICK_URL="https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/${ONE_CLICK_REF}/nams-e2-micro/cloudshell-one-click.sh"
PLUGIN_NAME="Compute Instance Run Command"

say(){ printf '\n=== %s ===\n' "$*"; }
fail(){ echo "ERROR: $*" >&2; exit 1; }
trap 'rc=$?; echo; echo "Delete/reinstall controller failed at line $LINENO (exit $rc). The WAHA instance was not targeted." >&2; exit $rc' ERR

command -v oci >/dev/null || fail "OCI CLI is unavailable in Cloud Shell."
command -v jq >/dev/null || fail "jq is unavailable in Cloud Shell."

say "1/7 Resolving only the new NAMS instance"
find_instance(){
  local name="$1"
  oci search resource structured-search --region "$REGION" \
    --query-text "query instance resources where displayName = '$name'" --output json 2>/dev/null |
    jq -r '[.data.items[]? | select((.["lifecycle-state"] // .lifecycleState // "") == "RUNNING")] | sort_by(.["time-created"] // .timeCreated // "") | last | .identifier // empty'
}
INSTANCE_ID="$(find_instance "$TARGET_NAME")"
if [ -z "$INSTANCE_ID" ]; then INSTANCE_ID="$(find_instance "NAMS-Lightpanda-Agent")"; fi
[ -n "$INSTANCE_ID" ] || fail "No RUNNING instance named $TARGET_NAME or NAMS-Lightpanda-Agent was found."

INSTANCE_JSON="$(oci compute instance get --region "$REGION" --instance-id "$INSTANCE_ID" --output json)"
DISPLAY_NAME="$(jq -r '.data["display-name"]' <<<"$INSTANCE_JSON")"
COMPARTMENT_ID="$(jq -r '.data["compartment-id"]' <<<"$INSTANCE_JSON")"
SHAPE="$(jq -r '.data.shape' <<<"$INSTANCE_JSON")"
[[ "$DISPLAY_NAME" != *WAHA* && "$DISPLAY_NAME" != *WhatsApp* && "$DISPLAY_NAME" != *whatsapp* ]] || fail "Safety stop: resolved instance appears to be WAHA/WhatsApp."
[ "$SHAPE" = "VM.Standard.E2.1.Micro" ] || fail "Expected VM.Standard.E2.1.Micro but found $SHAPE."
VNIC_JSON="$(oci compute instance list-vnics --region "$REGION" --instance-id "$INSTANCE_ID" --output json)"
PUBLIC_IP="$(jq -r '.data[0]["public-ip"] // empty' <<<"$VNIC_JSON")"
[ -n "$PUBLIC_IP" ] || fail "The target instance has no public IP."
echo "Target: $DISPLAY_NAME"
echo "Public IP: $PUBLIC_IP"
echo "Shape: $SHAPE"
if [ "$PUBLIC_IP" != "$EXPECTED_IP" ]; then echo "OCI reports $PUBLIC_IP; this overrides the earlier screenshot IP $EXPECTED_IP."; fi

say "2/7 Enabling Oracle Run Command"
cat >/tmp/nams-agent-config.json <<JSON
{
  "areAllPluginsDisabled": false,
  "isManagementDisabled": false,
  "isMonitoringDisabled": false,
  "pluginsConfig": [
    {"name": "$PLUGIN_NAME", "desiredState": "ENABLED"}
  ]
}
JSON
oci compute instance update --region "$REGION" --instance-id "$INSTANCE_ID" --agent-config file:///tmp/nams-agent-config.json --force >/dev/null
PLUGIN_STATUS=""
for i in $(seq 1 90); do
  PLUGIN_STATUS="$(oci instance-agent plugin get --region "$REGION" --compartment-id "$COMPARTMENT_ID" --instanceagent-id "$INSTANCE_ID" --plugin-name "$PLUGIN_NAME" --query 'data.status' --raw-output 2>/dev/null || true)"
  [ "$PLUGIN_STATUS" = "RUNNING" ] && break
  case "$PLUGIN_STATUS" in STOPPED|NOT_SUPPORTED) fail "Run Command plugin status is $PLUGIN_STATUS.";; esac
  [ $((i % 6)) -eq 0 ] && echo "Run Command plugin: ${PLUGIN_STATUS:-waiting} ($((i/2)) minute(s))"
  sleep 10
done
[ "$PLUGIN_STATUS" = "RUNNING" ] || fail "Run Command did not become RUNNING within 15 minutes."

say "3/7 Canceling only unfinished earlier NAMS commands"
EXECUTIONS="$(oci instance-agent command-execution list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --instance-id "$INSTANCE_ID" --all --output json 2>/dev/null || echo '{"data":[]}')"
while IFS=$'\t' read -r COMMAND_ID STATE; do
  [ -n "$COMMAND_ID" ] || continue
  case "$STATE" in ACCEPTED|IN_PROGRESS) ;;& *) continue;; esac
  COMMAND_JSON="$(oci instance-agent command get --region "$REGION" --command-id "$COMMAND_ID" --output json 2>/dev/null || true)"
  COMMAND_NAME="$(jq -r '.data["display-name"] // empty' <<<"$COMMAND_JSON" 2>/dev/null || true)"
  if [[ "$COMMAND_NAME" == *NAMS* || "$COMMAND_NAME" == *nams* ]]; then
    echo "Canceling unfinished command: $COMMAND_NAME"
    oci instance-agent command cancel --region "$REGION" --command-id "$COMMAND_ID" --force >/dev/null 2>&1 || true
  fi
done < <(jq -r '.data[]? | [.["command-id"],.["lifecycle-state"]] | @tsv' <<<"$EXECUTIONS")
sleep 15

say "4/7 Deleting only the interrupted NAMS installation"
read -r -d '' CLEANUP_SCRIPT <<'REMOTE' || true
set -Eeuo pipefail
sudo bash -s <<'ROOT'
set -Eeuo pipefail

echo "Stopping partial NAMS services and installers..."
systemctl stop nams-e2-watchdog.timer nams-e2-watchdog.service nams-e2.service nams-v6-watchdog.timer nams-v6-watchdog.service nams-v6.service 2>/dev/null || true
systemctl disable nams-e2-watchdog.timer nams-e2.service nams-v6-watchdog.timer nams-v6.service 2>/dev/null || true
pkill -f 'nams-e2-installer' 2>/dev/null || true
pkill -f 'install-on-oracle-linux9' 2>/dev/null || true
sleep 3

for dir in /opt/nams-e2-micro /opt/nams-v6; do
  if [ -f "$dir/docker-compose.yml" ] && command -v docker >/dev/null 2>&1; then
    (cd "$dir" && docker compose down -v --remove-orphans --timeout 20) || true
  fi
done

if command -v docker >/dev/null 2>&1; then
  docker ps -aq --filter label=com.docker.compose.project=nams-e2-micro | xargs -r docker rm -f || true
  docker ps -aq --filter label=com.docker.compose.project=nams-v6 | xargs -r docker rm -f || true
  docker volume ls -q | grep -E '^(nams-e2-micro|nams-v6)_' | xargs -r docker volume rm -f || true
  docker image rm -f nams-e2-app:local nams-e2-chromium:local 2>/dev/null || true
  docker builder prune -af --filter 'until=24h' >/dev/null 2>&1 || true
fi

rm -rf /opt/nams-e2-micro /opt/nams-v6
rm -f /usr/local/sbin/nams-e2-watchdog /usr/local/sbin/nams-v6-watchdog
rm -f /etc/systemd/system/nams-e2.service /etc/systemd/system/nams-e2-watchdog.service /etc/systemd/system/nams-e2-watchdog.timer
rm -f /etc/systemd/system/nams-v6.service /etc/systemd/system/nams-v6-watchdog.service /etc/systemd/system/nams-v6-watchdog.timer
rm -f /var/lib/nams-e2-install.status /var/lib/nams-e2-dashboard-token /var/lib/nams-e2-active-model
rm -f /var/lib/nams-v6-install.status /var/lib/nams-v6-dashboard-token
rm -f /var/log/nams-e2-install.log /var/log/nams-v6-install.log
systemctl daemon-reload
systemctl reset-failed

echo "CLEANUP_OK"
ROOT
REMOTE
jq -n --arg text "$CLEANUP_SCRIPT" '{source:{sourceType:"TEXT",text:$text},output:{outputType:"TEXT"}}' >/tmp/nams-cleanup-content.json
jq -n --arg id "$INSTANCE_ID" '{instanceId:$id}' >/tmp/nams-cleanup-target.json
CLEANUP_COMMAND_ID="$(oci instance-agent command create --region "$REGION" --compartment-id "$COMPARTMENT_ID" \
  --display-name "NAMS clean interrupted installation" --timeout-in-seconds 1200 \
  --content file:///tmp/nams-cleanup-content.json --target file:///tmp/nams-cleanup-target.json \
  --query 'data.id' --raw-output)"
echo "Cleanup command: $CLEANUP_COMMAND_ID"

say "5/7 Waiting for confirmed cleanup"
CLEANUP_STATE=""
for i in $(seq 1 80); do
  CLEANUP_JSON="$(oci instance-agent command-execution get --region "$REGION" --command-id "$CLEANUP_COMMAND_ID" --instance-id "$INSTANCE_ID" --output json 2>/dev/null || true)"
  CLEANUP_STATE="$(jq -r '.data["lifecycle-state"] // empty' <<<"$CLEANUP_JSON" 2>/dev/null || true)"
  case "$CLEANUP_STATE" in
    SUCCEEDED) break;;
    FAILED|TIMED_OUT|CANCELED)
      jq -r '.data.content.text // .data.content.message // "No cleanup output returned"' <<<"$CLEANUP_JSON" || true
      fail "Cleanup ended in state $CLEANUP_STATE. Reinstallation was not started."
      ;;
  esac
  [ $((i % 4)) -eq 0 ] && echo "Cleanup state: ${CLEANUP_STATE:-waiting} / elapsed $((i/2)) minute(s)"
  sleep 30
done
[ "$CLEANUP_STATE" = "SUCCEEDED" ] || fail "Cleanup did not finish within 40 minutes."
CLEANUP_OUTPUT="$(jq -r '.data.content.text // empty' <<<"$CLEANUP_JSON")"
echo "$CLEANUP_OUTPUT"
grep -q 'CLEANUP_OK' <<<"$CLEANUP_OUTPUT" || fail "Oracle marked cleanup successful but CLEANUP_OK was not returned."

say "6/7 Starting complete fresh installation and verification"
echo "The next controller will rebuild, verify all services, record the token, and report DNS."

say "7/7 Handing over to the verified installer"
exec env \
  OCI_REGION="$REGION" \
  NAMS_INSTANCE_NAME="$DISPLAY_NAME" \
  NAMS_EXPECTED_IP="$PUBLIC_IP" \
  NAMS_DOMAIN="$DOMAIN" \
  bash <(curl -fsSL "$ONE_CLICK_URL")
