#!/usr/bin/env bash
set -Eeuo pipefail

REGION="${OCI_REGION:-ap-mumbai-1}"
TARGET_NAME="${NAMS_INSTANCE_NAME:-instance-20260723-2200}"
EXPECTED_IP="${NAMS_EXPECTED_IP:-130.210.31.138}"
DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}"
SUPPORT_REF="5d559f1cba4228e1f224f9dbbcdc12d46bcc1b57"
INSTALLER_URL="https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/${SUPPORT_REF}/nams-e2-micro/install-on-oracle-linux9-v2.sh"
TOKEN="${ADMIN_TOKEN:-$(openssl rand -hex 24)}"
NSG_NAME="NAMS-SEO-PUBLIC"
PLUGIN_NAME="Compute Instance Run Command"

say(){ printf '\n=== %s ===\n' "$*"; }
fail(){ echo "ERROR: $*" >&2; exit 1; }
trap 'rc=$?; echo; echo "Installer controller failed at line $LINENO (exit $rc). No WAHA resource was modified." >&2; exit $rc' ERR

command -v oci >/dev/null || fail "OCI CLI is not available in this Cloud Shell."
command -v jq >/dev/null || fail "jq is not available in this Cloud Shell."
command -v openssl >/dev/null || fail "openssl is not available in this Cloud Shell."

echo "NAMS one-click E2 Micro installer"
echo "Target: $TARGET_NAME ($EXPECTED_IP)"
echo "Domain: $DOMAIN"
echo "Region: $REGION"
echo "The WAHA/WhatsApp instance is explicitly excluded."

say "1/9 Resolving the exact new instance"
find_instance(){
  local name="$1"
  oci search resource structured-search --region "$REGION" \
    --query-text "query instance resources where displayName = '$name'" --output json 2>/dev/null |
    jq -r '[.data.items[]? | select((.["lifecycle-state"] // .lifecycleState // "") == "RUNNING")] | sort_by(.["time-created"] // .timeCreated // "") | last | .identifier // empty'
}
INSTANCE_ID="$(find_instance "$TARGET_NAME")"
if [ -z "$INSTANCE_ID" ]; then
  INSTANCE_ID="$(find_instance "NAMS-Lightpanda-Agent")"
fi
[ -n "$INSTANCE_ID" ] || fail "No RUNNING instance named $TARGET_NAME was found in $REGION."

INSTANCE_JSON="$(oci compute instance get --region "$REGION" --instance-id "$INSTANCE_ID" --output json)"
DISPLAY_NAME="$(jq -r '.data["display-name"]' <<<"$INSTANCE_JSON")"
LIFECYCLE="$(jq -r '.data["lifecycle-state"]' <<<"$INSTANCE_JSON")"
COMPARTMENT_ID="$(jq -r '.data["compartment-id"]' <<<"$INSTANCE_JSON")"
SHAPE="$(jq -r '.data.shape' <<<"$INSTANCE_JSON")"
[[ "$DISPLAY_NAME" != *WAHA* && "$DISPLAY_NAME" != *whatsapp* && "$DISPLAY_NAME" != *WhatsApp* ]] || fail "Safety stop: resolved instance looks like WAHA/WhatsApp."
[ "$LIFECYCLE" = "RUNNING" ] || fail "Target instance is not RUNNING."
[ "$SHAPE" = "VM.Standard.E2.1.Micro" ] || fail "Expected VM.Standard.E2.1.Micro, found $SHAPE."
echo "Instance: $DISPLAY_NAME"
echo "OCID: $INSTANCE_ID"
echo "Shape: $SHAPE"

VNIC_JSON="$(oci compute instance list-vnics --region "$REGION" --instance-id "$INSTANCE_ID" --output json)"
VNIC_ID="$(jq -r '.data[0].id // empty' <<<"$VNIC_JSON")"
PUBLIC_IP="$(jq -r '.data[0]["public-ip"] // empty' <<<"$VNIC_JSON")"
SUBNET_ID="$(jq -r '.data[0]["subnet-id"] // empty' <<<"$VNIC_JSON")"
[ -n "$VNIC_ID" ] && [ -n "$SUBNET_ID" ] || fail "Primary VNIC could not be resolved."
[ -n "$PUBLIC_IP" ] || fail "The instance has no public IP."
if [ "$PUBLIC_IP" != "$EXPECTED_IP" ]; then
  echo "Notice: screenshot IP was $EXPECTED_IP, OCI currently reports $PUBLIC_IP; OCI value will be used."
fi
VCN_ID="$(oci network subnet get --region "$REGION" --subnet-id "$SUBNET_ID" --query 'data."vcn-id"' --raw-output)"
echo "Public IP: $PUBLIC_IP"

say "2/9 Ensuring OCI network access on ports 22, 80 and 443"
NSG_ID="$(oci network nsg list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" --all --output json | jq -r --arg n "$NSG_NAME" '[.data[]? | select(.["display-name"]==$n and .["lifecycle-state"]=="AVAILABLE")] | first | .id // empty')"
if [ -z "$NSG_ID" ]; then
  NSG_ID="$(oci network nsg create --region "$REGION" --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" --display-name "$NSG_NAME" --wait-for-state AVAILABLE --query 'data.id' --raw-output)"
  echo "Created NSG: $NSG_ID"
else
  echo "Using existing NSG: $NSG_ID"
fi

RULES_JSON="$(oci network nsg rules list --region "$REGION" --nsg-id "$NSG_ID" --all --output json)"
for port in 22 80 443; do
  if ! jq -e --argjson p "$port" '.data[]? | select(.direction=="INGRESS" and .protocol=="6") | select(((.["tcp-options"]["destination-port-range"].min // .tcpOptions.destinationPortRange.min // -1)|tonumber)==$p)' <<<"$RULES_JSON" >/dev/null; then
    RULE="$(jq -n --argjson p "$port" --arg d "NAMS TCP $port" '[{direction:"INGRESS",protocol:"6",source:"0.0.0.0/0",sourceType:"CIDR_BLOCK",isStateless:false,tcpOptions:{destinationPortRange:{min:$p,max:$p}},description:$d}]')"
    oci network nsg rules add --region "$REGION" --nsg-id "$NSG_ID" --security-rules "$RULE" >/dev/null
    echo "Allowed TCP $port"
  fi
done

CURRENT_NSGS="$(oci network vnic get --region "$REGION" --vnic-id "$VNIC_ID" --output json | jq -c '.data["nsg-ids"] // []')"
NEW_NSGS="$(jq -c --arg id "$NSG_ID" '. + [$id] | unique' <<<"$CURRENT_NSGS")"
printf '%s' "$NEW_NSGS" >/tmp/nams-nsg-ids.json
oci network vnic update --region "$REGION" --vnic-id "$VNIC_ID" --nsg-ids file:///tmp/nams-nsg-ids.json --force >/dev/null

say "3/9 Enabling Oracle Run Command on the target only"
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
  case "$PLUGIN_STATUS" in
    RUNNING) break ;;
    STOPPED|NOT_SUPPORTED) fail "Oracle Run Command plugin status is $PLUGIN_STATUS." ;;
  esac
  if [ $((i % 6)) -eq 0 ]; then echo "Run Command plugin: ${PLUGIN_STATUS:-not reported} ($((i/2)) minute(s))"; fi
  sleep 10
done
[ "$PLUGIN_STATUS" = "RUNNING" ] || fail "Oracle Run Command did not reach RUNNING within 15 minutes."

say "4/9 Starting the unattended installation inside Oracle Linux 9"
REMOTE_SCRIPT="$(cat <<REMOTE
set -Eeuo pipefail
curl -fsSL '$INSTALLER_URL' | env \
  ADMIN_TOKEN='$TOKEN' \
  NAMS_DOMAIN='$DOMAIN' \
  NAMS_E2_RELEASE_REF='$SUPPORT_REF' \
  NAMS_SOURCE_REF='c74d8660d516e9330a9ad4f24742b10c43c487c4' \
  OLLAMA_MODEL='qwen2.5:0.5b-instruct' \
  bash
REMOTE
)"
jq -n --arg text "$REMOTE_SCRIPT" '{source:{sourceType:"TEXT",text:$text},output:{outputType:"TEXT"}}' >/tmp/nams-command-content.json
jq -n --arg id "$INSTANCE_ID" '{instanceId:$id}' >/tmp/nams-command-target.json
COMMAND_ID="$(oci instance-agent command create --region "$REGION" --compartment-id "$COMPARTMENT_ID" \
  --display-name "Install NAMS E2 Micro" --timeout-in-seconds 0 \
  --content file:///tmp/nams-command-content.json --target file:///tmp/nams-command-target.json \
  --query 'data.id' --raw-output)"
echo "Run Command: $COMMAND_ID"

say "5/9 Monitoring installation without retrying failures"
STATE=""
LAST_STATE=""
for i in $(seq 1 240); do
  EXEC_JSON="$(oci instance-agent command-execution get --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" --output json 2>/dev/null || true)"
  STATE="$(jq -r '.data["lifecycle-state"] // empty' <<<"$EXEC_JSON" 2>/dev/null || true)"
  DELIVERY="$(jq -r '.data["delivery-state"] // empty' <<<"$EXEC_JSON" 2>/dev/null || true)"
  if [ "$STATE" != "$LAST_STATE" ] || [ $((i % 4)) -eq 0 ]; then
    echo "Installation state: ${STATE:-waiting} / delivery: ${DELIVERY:-waiting} / elapsed: $((i/2)) minute(s)"
    LAST_STATE="$STATE"
  fi
  case "$STATE" in
    SUCCEEDED) break ;;
    FAILED|TIMED_OUT|CANCELED)
      echo "--- Oracle Run Command output ---"
      jq -r '.data.content.text // .data.content.message // "No text output returned"' <<<"$EXEC_JSON" || true
      EXIT_CODE="$(jq -r '.data.content["exit-code"] // empty' <<<"$EXEC_JSON")"
      fail "Installation ended in state $STATE${EXIT_CODE:+ with exit code $EXIT_CODE}."
      ;;
  esac
  sleep 30
done
[ "$STATE" = "SUCCEEDED" ] || fail "Installation did not complete within 120 minutes."

echo "--- Final installer output ---"
jq -r '.data.content.text // "Installation completed; detailed log is /var/log/nams-e2-install.log on the VM."' <<<"$EXEC_JSON" || true

say "6/9 Verifying the complete stack from outside the VM"
probe_public(){ local path="$1"; shift; curl -fsS --connect-timeout 8 --max-time 45 -H "X-NAMS-Probe: $TOKEN" "$@" "http://$PUBLIC_IP$path"; }
EXTERNAL_READY=0
for i in $(seq 1 60); do
  if probe_public /_probe/app/health >/tmp/nams-public-app.json 2>/dev/null && \
     probe_public /_probe/chromium/json/version >/tmp/nams-public-chromium.json 2>/dev/null && \
     probe_public /_probe/novnc/vnc.html >/tmp/nams-public-novnc.html 2>/dev/null && \
     probe_public /_probe/lightpanda/json/version >/tmp/nams-public-lightpanda.json 2>/dev/null && \
     probe_public /_probe/ollama/api/tags >/tmp/nams-public-ollama.json 2>/dev/null; then
    EXTERNAL_READY=1
    break
  fi
  [ $((i % 6)) -eq 0 ] && echo "External verification wait: $((i/2)) minute(s)"
  sleep 5
done
[ "$EXTERNAL_READY" -eq 1 ] || fail "The remote command succeeded, but the public health endpoints are not reachable."
grep -q '"ok"' /tmp/nams-public-app.json
grep -q 'webSocketDebuggerUrl' /tmp/nams-public-chromium.json
grep -qi 'noVNC' /tmp/nams-public-novnc.html
jq -e '.models | length > 0' /tmp/nams-public-ollama.json >/dev/null
curl -fsS --connect-timeout 8 --max-time 45 -H "Authorization: Bearer $TOKEN" "http://$PUBLIC_IP/" >/tmp/nams-public-dashboard.html
grep -qi 'NAMS' /tmp/nams-public-dashboard.html

say "7/9 Recording the verified deployment"
EXISTING_TAGS="$(oci compute instance get --region "$REGION" --instance-id "$INSTANCE_ID" --query 'data."freeform-tags"' --output json)"
VERIFIED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq --arg token "$TOKEN" --arg domain "$DOMAIN" --arg ip "$PUBLIC_IP" --arg at "$VERIFIED_AT" \
  '. + {NAMSBootstrapToken:$token,NAMSDomain:$domain,NAMSProfile:"E2-Micro",NAMSStatus:"Verified",NAMSPublicIP:$ip,NAMSVerifiedAt:$at}' \
  <<<"$EXISTING_TAGS" >/tmp/nams-verified-tags.json
oci compute instance update --region "$REGION" --instance-id "$INSTANCE_ID" \
  --display-name "NAMS-Lightpanda-Agent" --freeform-tags file:///tmp/nams-verified-tags.json --force >/dev/null

say "8/9 Checking DNS"
DNS_IP="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | head -1 || true)"
if [ "$DNS_IP" = "$PUBLIC_IP" ]; then
  DNS_STATUS="correct"
else
  DNS_STATUS="change_required"
fi

say "9/9 Installation verified"
echo "Full NAMS stack: VERIFIED"
echo "Application: OK"
echo "Lightpanda: OK"
echo "Chromium CDP: OK"
echo "Live browser/noVNC: OK"
echo "Ollama local AI model: OK"
echo "Public IP: $PUBLIC_IP"
echo "Login token: $TOKEN"
echo "Immediate login: http://$PUBLIC_IP/?token=$TOKEN"
if [ "$DNS_STATUS" = "correct" ]; then
  echo "Domain login: https://$DOMAIN/?token=$TOKEN"
  echo "DNS: already correct"
else
  echo "DNS action required after this installer:"
  echo "  Type: A"
  echo "  Host: seo"
  echo "  Value: $PUBLIC_IP"
  echo "  Current resolved IP: ${DNS_IP:-none}"
  echo "After DNS updates, open: https://$DOMAIN/?token=$TOKEN"
fi
