#!/usr/bin/env bash
set -Eeuo pipefail

REGION="${OCI_REGION:-ap-mumbai-1}"
SOURCE_NAME="${NAMS_INSTANCE_NAME:-instance-20260723-2200}"
CANDIDATE_NAME="${NAMS_CANDIDATE_NAME:-NAMS-Lightpanda-Agent-Candidate}"
FINAL_NAME="NAMS-Lightpanda-Agent"
DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}"
SUPPORT_REF="5d559f1cba4228e1f224f9dbbcdc12d46bcc1b57"
INSTALLER_URL="https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/${SUPPORT_REF}/nams-e2-micro/install-on-oracle-linux9-v2.sh"
TOKEN="${ADMIN_TOKEN:-$(openssl rand -hex 24)}"
NSG_NAME="NAMS-SEO-PUBLIC"
RESERVED_IP_NAME="NAMS-SEO-RESERVED-IP"

say(){ printf '\n=== %s ===\n' "$*"; }
fail(){ echo "ERROR: $*" >&2; exit 1; }
trap 'rc=$?; echo; echo "Blue-green installer failed at line $LINENO (exit $rc). The original NAMS instance was not deleted unless the replacement had already passed verification. WAHA was never targeted." >&2; exit $rc' ERR

for cmd in oci jq openssl base64 curl; do command -v "$cmd" >/dev/null || fail "$cmd is unavailable in Cloud Shell."; done

echo "NAMS blue-green cloud-init reinstall"
echo "Source instance: $SOURCE_NAME"
echo "Domain: $DOMAIN"
echo "Region: $REGION"
echo "This workflow does not use Oracle Run Command and explicitly excludes WAHA/WhatsApp."

find_running(){
  local name="$1"
  oci search resource structured-search --region "$REGION" \
    --query-text "query instance resources where displayName = '$name'" --output json 2>/dev/null |
    jq -r '[.data.items[]? | select((.["lifecycle-state"] // .lifecycleState // "") == "RUNNING")] | sort_by(.["time-created"] // .timeCreated // "") | last | .identifier // empty'
}
find_any(){
  local name="$1"
  oci search resource structured-search --region "$REGION" \
    --query-text "query instance resources where displayName = '$name'" --output json 2>/dev/null |
    jq -r '[.data.items[]?] | sort_by(.["time-created"] // .timeCreated // "") | last | .identifier // empty'
}

say "1/11 Resolving the interrupted NAMS instance"
SOURCE_ID="$(find_running "$SOURCE_NAME")"
[ -n "$SOURCE_ID" ] || fail "No RUNNING instance named $SOURCE_NAME was found in $REGION."
SOURCE_JSON="$(oci compute instance get --region "$REGION" --instance-id "$SOURCE_ID" --output json)"
SOURCE_DISPLAY="$(jq -r '.data["display-name"]' <<<"$SOURCE_JSON")"
[[ "$SOURCE_DISPLAY" != *WAHA* && "$SOURCE_DISPLAY" != *WhatsApp* && "$SOURCE_DISPLAY" != *whatsapp* ]] || fail "Safety stop: source instance resembles WAHA/WhatsApp."
COMPARTMENT_ID="$(jq -r '.data["compartment-id"]' <<<"$SOURCE_JSON")"
AD="$(jq -r '.data["availability-domain"]' <<<"$SOURCE_JSON")"
FD="$(jq -r '.data["fault-domain"] // empty' <<<"$SOURCE_JSON")"
SHAPE="$(jq -r '.data.shape' <<<"$SOURCE_JSON")"
IMAGE_ID="$(jq -r '.data["image-id"] // .data["source-details"]["image-id"] // empty' <<<"$SOURCE_JSON")"
[ "$SHAPE" = "VM.Standard.E2.1.Micro" ] || fail "Expected VM.Standard.E2.1.Micro, found $SHAPE."
[ -n "$IMAGE_ID" ] || fail "Unable to resolve the Oracle Linux image OCID from the source instance."
SOURCE_VNIC_JSON="$(oci compute instance list-vnics --region "$REGION" --instance-id "$SOURCE_ID" --output json)"
SOURCE_VNIC_ID="$(jq -r '.data[0].id // empty' <<<"$SOURCE_VNIC_JSON")"
SUBNET_ID="$(jq -r '.data[0]["subnet-id"] // empty' <<<"$SOURCE_VNIC_JSON")"
VCN_ID="$(oci network subnet get --region "$REGION" --subnet-id "$SUBNET_ID" --query 'data."vcn-id"' --raw-output)"
SOURCE_NSGS="$(jq -c '.data[0]["nsg-ids"] // []' <<<"$SOURCE_VNIC_JSON")"
SSH_KEYS="$(jq -r '.data.metadata.ssh_authorized_keys // empty' <<<"$SOURCE_JSON")"
echo "Source: $SOURCE_DISPLAY"
echo "Shape: $SHAPE"
echo "Image: $IMAGE_ID"
echo "Availability domain: $AD"
echo "Fault domain: ${FD:-automatic}"

say "2/11 Removing only an older failed candidate, if present"
OLD_CANDIDATE_ID="$(find_any "$CANDIDATE_NAME")"
if [ -n "$OLD_CANDIDATE_ID" ]; then
  OLD_CANDIDATE_JSON="$(oci compute instance get --region "$REGION" --instance-id "$OLD_CANDIDATE_ID" --output json 2>/dev/null || true)"
  OLD_CANDIDATE_STATE="$(jq -r '.data["lifecycle-state"] // empty' <<<"$OLD_CANDIDATE_JSON" 2>/dev/null || true)"
  OLD_CANDIDATE_DISPLAY="$(jq -r '.data["display-name"] // empty' <<<"$OLD_CANDIDATE_JSON" 2>/dev/null || true)"
  [[ "$OLD_CANDIDATE_DISPLAY" != *WAHA* && "$OLD_CANDIDATE_DISPLAY" != *WhatsApp* && "$OLD_CANDIDATE_DISPLAY" != *whatsapp* ]] || fail "Safety stop: old candidate resembles WAHA/WhatsApp."
  if [ "$OLD_CANDIDATE_STATE" != "TERMINATED" ] && [ -n "$OLD_CANDIDATE_STATE" ]; then
    echo "Terminating previous failed candidate in state $OLD_CANDIDATE_STATE..."
    oci compute instance terminate --region "$REGION" --instance-id "$OLD_CANDIDATE_ID" --preserve-boot-volume false --force >/dev/null
    for i in $(seq 1 90); do
      state="$(oci compute instance get --region "$REGION" --instance-id "$OLD_CANDIDATE_ID" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo TERMINATED)"
      [ "$state" = "TERMINATED" ] && break
      [ $((i % 6)) -eq 0 ] && echo "Candidate termination: $state ($((i/2)) minute(s))"
      sleep 10
    done
  fi
fi

say "3/11 Ensuring a dedicated NSG for SSH, HTTP and HTTPS"
NSG_ID="$(oci network nsg list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" --all --output json | jq -r --arg n "$NSG_NAME" '[.data[]? | select(.["display-name"]==$n and .["lifecycle-state"]=="AVAILABLE")] | first | .id // empty')"
if [ -z "$NSG_ID" ]; then
  NSG_ID="$(oci network nsg create --region "$REGION" --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" --display-name "$NSG_NAME" --wait-for-state AVAILABLE --query 'data.id' --raw-output)"
fi
RULES_JSON="$(oci network nsg rules list --region "$REGION" --nsg-id "$NSG_ID" --all --output json)"
for port in 22 80 443; do
  if ! jq -e --argjson p "$port" '.data[]? | select(.direction=="INGRESS" and .protocol=="6") | select(((.["tcp-options"]["destination-port-range"].min // -1)|tonumber)==$p)' <<<"$RULES_JSON" >/dev/null; then
    RULE="$(jq -n --argjson p "$port" --arg d "NAMS TCP $port" '[{direction:"INGRESS",protocol:"6",source:"0.0.0.0/0",sourceType:"CIDR_BLOCK",isStateless:false,tcpOptions:{destinationPortRange:{min:$p,max:$p}},description:$d}]')"
    oci network nsg rules add --region "$REGION" --nsg-id "$NSG_ID" --security-rules "$RULE" >/dev/null
  fi
done
ALL_NSGS="$(jq -c --arg id "$NSG_ID" '. + [$id] | unique' <<<"$SOURCE_NSGS")"
printf '%s' "$ALL_NSGS" >/tmp/nams-bluegreen-nsgs.json

echo "NSG: $NSG_ID"

say "4/11 Creating or reusing a reserved public IP"
RESERVED_JSON="$(oci network public-ip list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --scope REGION --lifetime RESERVED --all --output json)"
RESERVED_ID="$(jq -r --arg n "$RESERVED_IP_NAME" '[.data[]? | select(.["display-name"]==$n)] | first | .id // empty' <<<"$RESERVED_JSON")"
if [ -z "$RESERVED_ID" ]; then
  RESERVED_ID="$(oci network public-ip create --region "$REGION" --compartment-id "$COMPARTMENT_ID" --lifetime RESERVED --display-name "$RESERVED_IP_NAME" --wait-for-state AVAILABLE --query 'data.id' --raw-output)"
fi
RESERVED_IP="$(oci network public-ip get --region "$REGION" --public-ip-id "$RESERVED_ID" --query 'data."ip-address"' --raw-output)"
CURRENT_PRIVATE_ID="$(oci network public-ip get --region "$REGION" --public-ip-id "$RESERVED_ID" --query 'data."private-ip-id"' --raw-output 2>/dev/null || true)"
if [ -n "$CURRENT_PRIVATE_ID" ] && [ "$CURRENT_PRIVATE_ID" != "null" ] && [ "$CURRENT_PRIVATE_ID" != "None" ]; then
  echo "Detaching reserved IP from an older NAMS candidate..."
  oci network public-ip update --region "$REGION" --public-ip-id "$RESERVED_ID" --private-ip-id '' --force >/dev/null
fi
echo "Reserved IP: $RESERVED_IP"

say "5/11 Preparing cloud-init bootstrap"
cat >/tmp/nams-user-data.sh <<BOOTSTRAP
#!/usr/bin/env bash
set -Eeuo pipefail
exec > >(tee -a /var/log/nams-cloud-init-bootstrap.log | logger -t nams-cloud-init -s 2>/dev/console) 2>&1
echo "NAMS_BOOTSTRAP_START \$(date -Is)"
for i in \$(seq 1 120); do
  if curl -fsS --connect-timeout 5 https://raw.githubusercontent.com/ >/dev/null 2>&1; then break; fi
  [ "\$i" -eq 120 ] && exit 91
  sleep 5
done
curl -fsSL '$INSTALLER_URL' | env \
  ADMIN_TOKEN='$TOKEN' \
  NAMS_DOMAIN='$DOMAIN' \
  NAMS_E2_RELEASE_REF='$SUPPORT_REF' \
  NAMS_SOURCE_REF='c74d8660d516e9330a9ad4f24742b10c43c487c4' \
  OLLAMA_MODEL='qwen2.5:0.5b-instruct' \
  bash
echo "NAMS_BOOTSTRAP_SUCCESS \$(date -Is)"
BOOTSTRAP
USER_DATA_B64="$(base64 -w0 /tmp/nams-user-data.sh)"
jq -n --arg ud "$USER_DATA_B64" --arg keys "$SSH_KEYS" '{user_data:$ud} + (if ($keys|length)>0 then {ssh_authorized_keys:$keys} else {} end)' >/tmp/nams-bluegreen-metadata.json
jq -n --arg token "$TOKEN" --arg domain "$DOMAIN" '{NAMSBootstrapToken:$token,NAMSDomain:$domain,NAMSStatus:"Installing",NAMSProfile:"E2-Micro-CloudInit"}' >/tmp/nams-bluegreen-tags.json

say "6/11 Launching the clean candidate without deleting the current instance"
launch_candidate(){
  local with_fd="$1"
  local err=/tmp/nams-launch.err
  local args=(compute instance launch --region "$REGION" --availability-domain "$AD" --compartment-id "$COMPARTMENT_ID" --shape "$SHAPE" --subnet-id "$SUBNET_ID" --display-name "$CANDIDATE_NAME" --image-id "$IMAGE_ID" --assign-public-ip false --nsg-ids file:///tmp/nams-bluegreen-nsgs.json --metadata file:///tmp/nams-bluegreen-metadata.json --freeform-tags file:///tmp/nams-bluegreen-tags.json --wait-for-state RUNNING --max-wait-seconds 1800)
  [ "$with_fd" = yes ] && [ -n "$FD" ] && args+=(--fault-domain "$FD")
  set +e
  CANDIDATE_ID="$(oci "${args[@]}" --query 'data.id' --raw-output 2>"$err")"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    cat "$err" >&2
    return "$rc"
  fi
}
if ! launch_candidate yes; then
  if grep -Eqi 'out of host capacity|capacity|InternalError|500' /tmp/nams-launch.err; then
    echo "Same fault-domain placement lacked capacity; retrying once with OCI automatic placement."
    launch_candidate no
  else
    fail "Candidate launch failed for a non-capacity reason."
  fi
fi
[ -n "$CANDIDATE_ID" ] || fail "OCI did not return a candidate instance OCID."
echo "Candidate: $CANDIDATE_ID"

say "7/11 Attaching the reserved public IP"
CANDIDATE_VNIC_ID="$(oci compute instance list-vnics --region "$REGION" --instance-id "$CANDIDATE_ID" --query 'data[0].id' --raw-output)"
PRIVATE_IP_ID="$(oci network private-ip list --region "$REGION" --vnic-id "$CANDIDATE_VNIC_ID" --all --output json | jq -r '[.data[]? | select(.["is-primary"]==true)] | first | .id // empty')"
[ -n "$PRIVATE_IP_ID" ] || fail "Candidate primary private IP could not be resolved."
oci network public-ip update --region "$REGION" --public-ip-id "$RESERVED_ID" --private-ip-id "$PRIVATE_IP_ID" --force >/dev/null
for i in $(seq 1 30); do
  attached="$(oci network public-ip get --region "$REGION" --public-ip-id "$RESERVED_ID" --query 'data."private-ip-id"' --raw-output)"
  [ "$attached" = "$PRIVATE_IP_ID" ] && break
  sleep 5
done
[ "$attached" = "$PRIVATE_IP_ID" ] || fail "Reserved IP did not attach to the candidate."

say "8/11 Waiting for cloud-init and verifying every public service"
probe(){ local path="$1"; shift; curl -fsS --connect-timeout 8 --max-time 60 -H "X-NAMS-Probe: $TOKEN" "$@" "http://$RESERVED_IP$path"; }
READY=0
for i in $(seq 1 240); do
  if probe /_probe/app/health >/tmp/nams-bg-app.json 2>/dev/null && \
     probe /_probe/chromium/json/version >/tmp/nams-bg-chromium.json 2>/dev/null && \
     probe /_probe/novnc/vnc.html >/tmp/nams-bg-novnc.html 2>/dev/null && \
     probe /_probe/lightpanda/json/version >/tmp/nams-bg-lightpanda.json 2>/dev/null && \
     probe /_probe/ollama/api/tags >/tmp/nams-bg-ollama.json 2>/dev/null; then
    READY=1
    break
  fi
  if [ $((i % 12)) -eq 0 ]; then
    echo "Cloud-init verification wait: $((i/12)) minute(s)"
    HISTORY_ID="$(oci compute instance-console-history capture --region "$REGION" --instance-id "$CANDIDATE_ID" --query 'data.id' --raw-output 2>/dev/null || true)"
    if [ -n "$HISTORY_ID" ]; then
      sleep 3
      oci compute instance-console-history get-content --region "$REGION" --instance-console-history-id "$HISTORY_ID" 2>/dev/null | tail -n 12 || true
    fi
  fi
  sleep 5
done
if [ "$READY" -ne 1 ]; then
  echo "Candidate did not verify. Capturing final console history; original instance remains running."
  HISTORY_ID="$(oci compute instance-console-history capture --region "$REGION" --instance-id "$CANDIDATE_ID" --query 'data.id' --raw-output 2>/dev/null || true)"
  [ -z "$HISTORY_ID" ] || { sleep 3; oci compute instance-console-history get-content --region "$REGION" --instance-console-history-id "$HISTORY_ID" 2>/dev/null | tail -n 120 || true; }
  fail "Candidate failed full verification."
fi
grep -q '"ok"' /tmp/nams-bg-app.json
grep -q 'webSocketDebuggerUrl' /tmp/nams-bg-chromium.json
grep -qi 'noVNC' /tmp/nams-bg-novnc.html
jq -e '.models | length > 0' /tmp/nams-bg-ollama.json >/dev/null
curl -fsS --connect-timeout 8 --max-time 60 -H "Authorization: Bearer $TOKEN" "http://$RESERVED_IP/" >/tmp/nams-bg-dashboard.html
grep -qi 'NAMS' /tmp/nams-bg-dashboard.html

echo "Candidate passed application, dashboard, Lightpanda, Chromium CDP, noVNC and Ollama verification."

say "9/11 Promoting the verified replacement"
VERIFIED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CANDIDATE_TAGS="$(oci compute instance get --region "$REGION" --instance-id "$CANDIDATE_ID" --query 'data."freeform-tags"' --output json)"
jq --arg at "$VERIFIED_AT" --arg ip "$RESERVED_IP" '. + {NAMSStatus:"Verified",NAMSVerifiedAt:$at,NAMSPublicIP:$ip}' <<<"$CANDIDATE_TAGS" >/tmp/nams-bluegreen-verified-tags.json
oci compute instance update --region "$REGION" --instance-id "$CANDIDATE_ID" --display-name "$FINAL_NAME" --freeform-tags file:///tmp/nams-bluegreen-verified-tags.json --force >/dev/null

say "10/11 Deleting the interrupted source only after successful verification"
oci compute instance terminate --region "$REGION" --instance-id "$SOURCE_ID" --preserve-boot-volume false --force >/dev/null
for i in $(seq 1 90); do
  old_state="$(oci compute instance get --region "$REGION" --instance-id "$SOURCE_ID" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo TERMINATED)"
  [ "$old_state" = "TERMINATED" ] && break
  [ $((i % 6)) -eq 0 ] && echo "Old instance termination: $old_state ($((i/2)) minute(s))"
  sleep 10
done

say "11/11 Clean reinstall completed and verified"
DNS_IP="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | head -1 || true)"
echo "Full NAMS stack: VERIFIED"
echo "Application: OK"
echo "Lightpanda: OK"
echo "Chromium CDP: OK"
echo "Live browser/noVNC: OK"
echo "Ollama local AI: OK"
echo "Verified instance: $FINAL_NAME"
echo "Reserved public IP: $RESERVED_IP"
echo "Login token: $TOKEN"
echo "Immediate login: http://$RESERVED_IP/?token=$TOKEN"
if [ "$DNS_IP" = "$RESERVED_IP" ]; then
  echo "Domain login: https://$DOMAIN/?token=$TOKEN"
  echo "DNS: already correct"
else
  echo "DNS CHANGE REQUIRED:"
  echo "  Type: A"
  echo "  Host: seo"
  echo "  Value: $RESERVED_IP"
  echo "  Current resolved IP: ${DNS_IP:-none}"
  echo "After DNS updates, open: https://$DOMAIN/?token=$TOKEN"
fi
