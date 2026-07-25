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
CONTROLLER_VERSION="2026-07-25.2"

say(){ printf '\n=== %s ===\n' "$*"; }
fail(){ echo "ERROR: $*" >&2; exit 1; }
trap 'rc=$?; echo; echo "Installer controller failed at line $LINENO (exit $rc). No WAHA resource was modified." >&2; exit $rc' ERR

for cmd in oci jq openssl curl; do command -v "$cmd" >/dev/null || fail "$cmd is not available in this Cloud Shell."; done

echo "NAMS one-click E2 Micro installer v${CONTROLLER_VERSION}"
echo "Target: $TARGET_NAME ($EXPECTED_IP)"
echo "Domain: $DOMAIN"
echo "Region: $REGION"
echo "The WAHA/WhatsApp instance is explicitly excluded."

say "1/11 Resolving the exact new instance"
find_instance(){
  local name="$1"
  oci search resource structured-search --region "$REGION" \
    --query-text "query instance resources where displayName = '$name'" --output json 2>/dev/null |
    jq -r '[.data.items[]? | select((.["lifecycle-state"] // .lifecycleState // "") == "RUNNING")] | sort_by(.["time-created"] // .timeCreated // "") | last | .identifier // empty'
}
INSTANCE_ID="$(find_instance "$TARGET_NAME")"
if [ -z "$INSTANCE_ID" ]; then INSTANCE_ID="$(find_instance "NAMS-Lightpanda-Agent")"; fi
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
if [ "$PUBLIC_IP" != "$EXPECTED_IP" ]; then echo "Notice: expected IP was $EXPECTED_IP; OCI currently reports $PUBLIC_IP and that value will be used."; fi
VCN_ID="$(oci network subnet get --region "$REGION" --subnet-id "$SUBNET_ID" --query 'data."vcn-id"' --raw-output)"
echo "Public IP: $PUBLIC_IP"

say "2/11 Ensuring OCI network access on ports 22, 80 and 443"
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

say "3/11 Ensuring least-privilege IAM for Run Command delivery"
TENANCY_ID="${OCI_TENANCY_ID:-$(awk -F= '/^[[:space:]]*tenancy[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$HOME/.oci/config" 2>/dev/null || true)}"
if [ -z "$TENANCY_ID" ]; then
  TENANCY_ID="$(oci iam region-subscription list --all --query 'data[0]."tenancy-id"' --raw-output 2>/dev/null || true)"
fi
[ -n "$TENANCY_ID" ] && [ "$TENANCY_ID" != "null" ] || fail "The tenancy OCID could not be resolved from Cloud Shell."
SHORT_ID="$(printf '%s' "$INSTANCE_ID" | sha256sum | cut -c1-10)"
DG_NAME="NAMS-E2-RunCommand-${SHORT_ID}"
POLICY_NAME="NAMS-E2-RunCommand-${SHORT_ID}"
MATCHING_RULE="instance.id = '$INSTANCE_ID'"
DG_ID="$(oci iam dynamic-group list --compartment-id "$TENANCY_ID" --all --output json 2>/dev/null | jq -r --arg n "$DG_NAME" '[.data[]? | select(.name==$n and .["lifecycle-state"]!="DELETED")] | first | .id // empty' || true)"
IAM_CHANGED=0
if [ -z "$DG_ID" ]; then
  DG_ID="$(oci iam dynamic-group create --compartment-id "$TENANCY_ID" --name "$DG_NAME" --description "Run Command access for the single NAMS E2 instance" --matching-rule "$MATCHING_RULE" --wait-for-state ACTIVE --query 'data.id' --raw-output 2>/tmp/nams-dg-create.err)" || {
    cat /tmp/nams-dg-create.err >&2
    fail "Could not create the required dynamic group. Run this Cloud Shell command as a tenancy administrator."
  }
  IAM_CHANGED=1
  echo "Created dynamic group: $DG_NAME"
else
  CURRENT_RULE="$(oci iam dynamic-group get --dynamic-group-id "$DG_ID" --query 'data."matching-rule"' --raw-output)"
  if [ "$CURRENT_RULE" != "$MATCHING_RULE" ]; then
    oci iam dynamic-group update --dynamic-group-id "$DG_ID" --matching-rule "$MATCHING_RULE" --force >/dev/null
    IAM_CHANGED=1
    echo "Restricted existing dynamic group to the exact NAMS instance."
  else
    echo "Dynamic group already correct: $DG_NAME"
  fi
fi
POLICY_STATEMENT="Allow dynamic-group id $DG_ID to use instance-agent-command-execution-family in compartment id $COMPARTMENT_ID where request.instance.id=target.instance.id"
POLICY_ID="$(oci iam policy list --compartment-id "$TENANCY_ID" --all --output json 2>/dev/null | jq -r --arg n "$POLICY_NAME" '[.data[]? | select(.name==$n and .["lifecycle-state"]!="DELETED")] | first | .id // empty' || true)"
printf '%s\n' "$POLICY_STATEMENT" | jq -R -s 'split("\n") | map(select(length>0))' >/tmp/nams-policy-statements.json
if [ -z "$POLICY_ID" ]; then
  POLICY_ID="$(oci iam policy create --compartment-id "$TENANCY_ID" --name "$POLICY_NAME" --description "Least-privilege Run Command execution policy for one NAMS E2 instance" --statements file:///tmp/nams-policy-statements.json --wait-for-state ACTIVE --query 'data.id' --raw-output 2>/tmp/nams-policy-create.err)" || {
    cat /tmp/nams-policy-create.err >&2
    fail "Could not create the required Run Command policy. Run this Cloud Shell command as a tenancy administrator."
  }
  IAM_CHANGED=1
  echo "Created policy: $POLICY_NAME"
else
  CURRENT_STATEMENTS="$(oci iam policy get --policy-id "$POLICY_ID" --query 'data.statements' --output json)"
  if ! jq -e --arg s "$POLICY_STATEMENT" 'index($s) != null' <<<"$CURRENT_STATEMENTS" >/dev/null; then
    jq --arg s "$POLICY_STATEMENT" '. + [$s] | unique' <<<"$CURRENT_STATEMENTS" >/tmp/nams-policy-statements.json
    oci iam policy update --policy-id "$POLICY_ID" --statements file:///tmp/nams-policy-statements.json --force >/dev/null
    IAM_CHANGED=1
    echo "Updated policy: $POLICY_NAME"
  else
    echo "Run Command policy already present."
  fi
fi

say "4/11 Enabling Oracle Run Command on the target only"
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

wait_plugin(){
  local max_checks="${1:-90}" status=""
  for i in $(seq 1 "$max_checks"); do
    status="$(oci instance-agent plugin get --region "$REGION" --compartment-id "$COMPARTMENT_ID" --instanceagent-id "$INSTANCE_ID" --plugin-name "$PLUGIN_NAME" --query 'data.status' --raw-output 2>/dev/null || true)"
    case "$status" in
      RUNNING) echo "$status"; return 0 ;;
      STOPPED|NOT_SUPPORTED) echo "$status"; return 2 ;;
    esac
    [ $((i % 6)) -eq 0 ] && echo "Run Command plugin: ${status:-not reported} ($((i/6)) minute(s))" >&2
    sleep 10
  done
  echo "$status"
  return 1
}
PLUGIN_STATUS="$(wait_plugin 90)" || fail "Oracle Run Command plugin did not reach RUNNING; last status: ${PLUGIN_STATUS:-unknown}."
echo "Run Command plugin: $PLUGIN_STATUS"

create_text_command(){
  local name="$1" text="$2" timeout="${3:-600}"
  jq -n --arg text "$text" '{source:{sourceType:"TEXT",text:$text},output:{outputType:"TEXT"}}' >/tmp/nams-command-content.json
  jq -n --arg id "$INSTANCE_ID" '{instanceId:$id}' >/tmp/nams-command-target.json
  oci instance-agent command create --region "$REGION" --compartment-id "$COMPARTMENT_ID" \
    --display-name "$name" --timeout-in-seconds "$timeout" \
    --content file:///tmp/nams-command-content.json --target file:///tmp/nams-command-target.json \
    --query 'data.id' --raw-output
}

wait_execution(){
  local command_id="$1" max_seconds="$2" elapsed=0 state="" delivery="" last=""
  while [ "$elapsed" -lt "$max_seconds" ]; do
    EXEC_JSON="$(oci instance-agent command-execution get --region "$REGION" --command-id "$command_id" --instance-id "$INSTANCE_ID" --output json 2>/dev/null || true)"
    state="$(jq -r '.data["lifecycle-state"] // empty' <<<"$EXEC_JSON" 2>/dev/null || true)"
    delivery="$(jq -r '.data["delivery-state"] // empty' <<<"$EXEC_JSON" 2>/dev/null || true)"
    if [ "$state/$delivery" != "$last" ] || [ $((elapsed % 120)) -eq 0 ]; then
      echo "Command state: ${state:-waiting} / delivery: ${delivery:-waiting} / elapsed: $((elapsed/60)) minute(s)" >&2
      last="$state/$delivery"
    fi
    case "$state" in
      SUCCEEDED) printf '%s' "$EXEC_JSON"; return 0 ;;
      FAILED|TIMED_OUT|CANCELED) printf '%s' "$EXEC_JSON"; return 2 ;;
    esac
    case "$delivery" in
      EXPIRED|FAILED) printf '%s' "$EXEC_JSON"; return 3 ;;
    esac
    sleep 30
    elapsed=$((elapsed+30))
  done
  printf '%s' "$EXEC_JSON"
  return 4
}

say "5/11 Proving Run Command delivery before installation"
PREFLIGHT='set -eu; echo NAMS_RUN_COMMAND_READY; id; if sudo -n true 2>/dev/null; then echo NAMS_SUDO_READY; else echo NAMS_SUDO_UNAVAILABLE; fi'
PREFLIGHT_OK=0
for attempt in 1 2; do
  PREFLIGHT_ID="$(create_text_command "NAMS delivery preflight ${attempt}" "$PREFLIGHT" 600)"
  echo "Preflight command: $PREFLIGHT_ID"
  if PREFLIGHT_JSON="$(wait_execution "$PREFLIGHT_ID" 600)"; then
    PREFLIGHT_OUT="$(jq -r '.data.content.text // empty' <<<"$PREFLIGHT_JSON")"
    echo "$PREFLIGHT_OUT"
    grep -q 'NAMS_RUN_COMMAND_READY' <<<"$PREFLIGHT_OUT" || fail "Run Command reported success but returned no preflight marker."
    grep -q 'NAMS_SUDO_READY' <<<"$PREFLIGHT_OUT" || fail "Run Command is delivered, but the ocarun user has no passwordless sudo. Recreate the NAMS instance with the supplied cloud-init bootstrap before installing."
    PREFLIGHT_OK=1
    break
  else
    rc=$?
  fi
  echo "Preflight attempt $attempt was not delivered successfully (code $rc)."
  if [ "$attempt" -eq 1 ]; then
    echo "Performing one controlled soft reboot to restart Oracle Cloud Agent and apply IAM membership."
    oci compute instance action --region "$REGION" --instance-id "$INSTANCE_ID" --action SOFTRESET --wait-for-state RUNNING --max-wait-seconds 1800 >/dev/null
    sleep 90
    PLUGIN_STATUS="$(wait_plugin 120)" || fail "Run Command plugin did not recover after the controlled reboot."
    echo "Run Command plugin after reboot: $PLUGIN_STATUS"
    if [ "$IAM_CHANGED" -eq 1 ]; then
      echo "Allowing IAM propagation before the final preflight attempt."
      sleep 180
    fi
  fi
done
[ "$PREFLIGHT_OK" -eq 1 ] || fail "Run Command still cannot deliver after IAM repair and one controlled reboot. Check the instance's outbound HTTPS route and Oracle Cloud Agent logs. No installation command was submitted."

say "6/11 Starting the unattended installation inside Oracle Linux 9"
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
COMMAND_ID="$(create_text_command "Install NAMS E2 Micro" "$REMOTE_SCRIPT" 21600)"
echo "Run Command: $COMMAND_ID"

say "7/11 Monitoring the real installation"
if EXEC_JSON="$(wait_execution "$COMMAND_ID" 21600)"; then
  :
else
  rc=$?
  echo "--- Oracle Run Command output ---"
  jq -r '.data.content.text // .data.content.message // "No text output returned"' <<<"$EXEC_JSON" || true
  STATE="$(jq -r '.data["lifecycle-state"] // empty' <<<"$EXEC_JSON")"
  DELIVERY="$(jq -r '.data["delivery-state"] // empty' <<<"$EXEC_JSON")"
  EXIT_CODE="$(jq -r '.data.content["exit-code"] // empty' <<<"$EXEC_JSON")"
  fail "Installation did not succeed (state=${STATE:-unknown}, delivery=${DELIVERY:-unknown}${EXIT_CODE:+, exit=$EXIT_CODE}, monitor_code=$rc)."
fi
echo "--- Final installer output ---"
jq -r '.data.content.text // "Installation completed; detailed log is /var/log/nams-e2-install.log on the VM."' <<<"$EXEC_JSON" || true

say "8/11 Verifying the complete stack from outside the VM"
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

say "9/11 Recording the verified deployment"
EXISTING_TAGS="$(oci compute instance get --region "$REGION" --instance-id "$INSTANCE_ID" --query 'data."freeform-tags"' --output json)"
VERIFIED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq --arg token "$TOKEN" --arg domain "$DOMAIN" --arg ip "$PUBLIC_IP" --arg at "$VERIFIED_AT" --arg controller "$CONTROLLER_VERSION" \
  '. + {NAMSBootstrapToken:$token,NAMSDomain:$domain,NAMSProfile:"E2-Micro",NAMSStatus:"Verified",NAMSPublicIP:$ip,NAMSVerifiedAt:$at,NAMSControllerVersion:$controller}' \
  <<<"$EXISTING_TAGS" >/tmp/nams-verified-tags.json
oci compute instance update --region "$REGION" --instance-id "$INSTANCE_ID" \
  --display-name "NAMS-Lightpanda-Agent" --freeform-tags file:///tmp/nams-verified-tags.json --force >/dev/null

say "10/11 Checking DNS"
DNS_IP="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | head -1 || true)"
if [ "$DNS_IP" = "$PUBLIC_IP" ]; then DNS_STATUS="correct"; else DNS_STATUS="change_required"; fi

say "11/11 Installation verified"
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
else
  echo "DNS action required: set $DOMAIN A record to $PUBLIC_IP (currently ${DNS_IP:-unresolved})."
fi
