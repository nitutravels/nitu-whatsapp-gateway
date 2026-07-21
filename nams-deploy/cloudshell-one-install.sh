#!/usr/bin/env bash
set -Eeuo pipefail

REGION="${OCI_CLI_REGION:-${OCI_REGION:-ap-mumbai-1}}"
COMPARTMENT_NAME="${OCI_COMPARTMENT_NAME:-NituWAGateway}"
COMPARTMENT_ID_HINT="${OCI_COMPARTMENT_ID:-ocid1.compartment.oc1..aaaaaaaacufz3wn5ugdwaglqsmkbpzt4szgiiglhd672hpgppgb5ixnc4zma}"
REFERENCE_INSTANCE="${OCI_REFERENCE_INSTANCE:-NituTravelsWAHA-20260719T184923Z}"
TARGET_NAME="${OCI_TARGET_INSTANCE:-NAMS-Lightpanda-Agent}"
NSG_NAME="${OCI_NSG_NAME:-NAMS-Lightpanda-NSG}"
RESERVED_IP_HINT="${OCI_RESERVED_IP:-161.118.166.225}"
DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}"
SOURCE_REF="${NAMS_SOURCE_REF:-c74d8660d516e9330a9ad4f24742b10c43c487c4}"
IMAGE_TAG="${NAMS_IMAGE_TAG:-c74d8660d516e9330a9ad4f24742b10c43c487c4-cdp1}"
INSTALLER_REF="${NAMS_INSTALLER_REF:-89fe9e7fc70ff4f9f7977fc81d09905c94269e9c}"
SHAPE="VM.Standard.A1.Flex"
OCPUS=1
MEMORY_GB=8
LOG="$HOME/nams-one-install.log"
WORK="$HOME/nams-one-install-work"
DIAG="$WORK/diagnostics"
TOKEN="$(openssl rand -hex 24)"
PHASE=preflight
NEW_ID=''
NEW_IP=''
RESERVED_IP_ID=''
RESERVED_IP_ADDRESS=''
COMPARTMENT_ID=''
NSG_ID=''
SUBNET_ID=''
VCN_ID=''
AD=''
IMAGE_ID=''

mkdir -p "$DIAG"
: >"$LOG"
exec > >(tee -a "$LOG") 2>&1

log(){ printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
valid_ocid(){ [[ "${1:-}" == ocid1.* ]]; }
valid_ip(){ [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
instance_state(){ oci compute instance get --region "$REGION" --instance-id "$1" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true; }
instance_vnic_id(){ oci compute instance list-vnics --region "$REGION" --instance-id "$1" --query 'data[0].id' --raw-output 2>/dev/null || true; }
instance_public_ip(){ oci compute instance list-vnics --region "$REGION" --instance-id "$1" --query 'data[0]."public-ip"' --raw-output 2>/dev/null || true; }
instance_private_ip_id(){
  local vnic
  vnic="$(instance_vnic_id "$1")"
  valid_ocid "$vnic" || return 1
  oci network private-ip list --region "$REGION" --vnic-id "$vnic" --all --query 'data[0].id' --raw-output
}
instance_token(){ oci compute instance get --region "$REGION" --instance-id "$1" --query 'data."freeform-tags".NAMSBootstrapToken' --raw-output 2>/dev/null || true; }
poll_state(){
  local id="$1" target="$2" loops="${3:-180}" state=''
  for _ in $(seq 1 "$loops"); do
    state="$(instance_state "$id")"
    [ "$state" = "$target" ] && return 0
    [ "$state" = TERMINATED ] && break
    sleep 10
  done
  log "Timed out waiting for instance state $target; current=$state"
  return 1
}
capture_console(){
  local id="$1" label="$2" history state
  valid_ocid "$id" || return 0
  history="$(oci compute console-history capture --region "$REGION" --instance-id "$id" --query 'data.id' --raw-output 2>/dev/null || true)"
  valid_ocid "$history" || return 0
  for _ in $(seq 1 60); do
    state="$(oci compute console-history get --region "$REGION" --instance-console-history-id "$history" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)"
    [ "$state" = SUCCEEDED ] && break
    [ "$state" = FAILED ] && return 0
    sleep 5
  done
  oci compute console-history get-content --region "$REGION" --instance-console-history-id "$history" --file "$DIAG/${label}-console.txt" >/dev/null 2>&1 || true
}
ensure_rule(){
  local port="$1" rules
  rules="$(oci network nsg rules list --region "$REGION" --nsg-id "$NSG_ID" --all --output json)"
  if ! jq -e --argjson p "$port" '.data[]? | select(.direction=="INGRESS" and .protocol=="6" and .source=="0.0.0.0/0") | .["tcp-options"]["destination-port-range"] | select(.min <= $p and .max >= $p)' <<<"$rules" >/dev/null; then
    cat >"$WORK/rule-${port}.json" <<JSON
[{"direction":"INGRESS","protocol":"6","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":$port,"max":$port}}}]
JSON
    oci network nsg rules add --region "$REGION" --nsg-id "$NSG_ID" --security-rules "file://$WORK/rule-${port}.json" >/dev/null
  fi
}
probe_full(){
  local ip="$1" token="$2"
  curl -fsS --connect-timeout 5 --max-time 20 -H "X-NAMS-Probe: $token" "http://$ip/_probe/app/health" >"$DIAG/app-health.json" 2>/dev/null &&
  curl -fsS --connect-timeout 5 --max-time 20 -H "X-NAMS-Probe: $token" "http://$ip/_probe/chromium/json/version" >"$DIAG/chromium.json" 2>/dev/null &&
  curl -fsS --connect-timeout 5 --max-time 20 -H "X-NAMS-Probe: $token" "http://$ip/_probe/novnc/vnc.html" >"$DIAG/novnc.html" 2>/dev/null &&
  curl -fsS --connect-timeout 5 --max-time 20 -H "X-NAMS-Probe: $token" "http://$ip/_probe/lightpanda/json/version" >"$DIAG/lightpanda.json" 2>/dev/null &&
  curl -fsS --connect-timeout 5 --max-time 20 -H "X-NAMS-Probe: $token" "http://$ip/_probe/ollama/api/tags" >"$DIAG/ollama.json" 2>/dev/null &&
  curl -fsS --connect-timeout 5 --max-time 20 -H "Authorization: Bearer $token" "http://$ip/" >"$DIAG/dashboard.html" 2>/dev/null &&
  grep -q '"ok"' "$DIAG/app-health.json" &&
  grep -q webSocketDebuggerUrl "$DIAG/chromium.json" &&
  grep -qi noVNC "$DIAG/novnc.html" &&
  grep -q NAMS "$DIAG/dashboard.html" &&
  jq -e '.models|length>0' "$DIAG/ollama.json" >/dev/null
}
wait_for_full_stack(){
  local id="$1" token="$2" ip='' state=''
  for i in $(seq 1 540); do
    state="$(instance_state "$id")"
    [ "$state" = TERMINATED ] && return 1
    ip="$(instance_public_ip "$id")"
    if valid_ip "$ip" && probe_full "$ip" "$token"; then
      NEW_IP="$ip"
      return 0
    fi
    if [ $((i % 12)) -eq 0 ]; then
      log "Installation verification: $((i/6)) minute(s) elapsed; instance=$state; ip=${ip:-pending}"
    fi
    sleep 10
  done
  return 1
}
ensure_reserved_ip(){
  local json
  json="$(oci network public-ip list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --scope REGION --lifetime RESERVED --all --output json | jq -c --arg ip "$RESERVED_IP_HINT" '[.data[]|select(.["ip-address"]==$ip or .["display-name"]=="NAMS-v5-Reserved-IP" or .["display-name"]=="NAMS-Reserved-IP")][0]//empty')"
  if [ -n "$json" ]; then
    RESERVED_IP_ID="$(jq -r '.id' <<<"$json")"
    RESERVED_IP_ADDRESS="$(jq -r '.["ip-address"]' <<<"$json")"
  else
    RESERVED_IP_ID="$(oci network public-ip create --region "$REGION" --compartment-id "$COMPARTMENT_ID" --lifetime RESERVED --display-name NAMS-v5-Reserved-IP --query 'data.id' --raw-output)"
    RESERVED_IP_ADDRESS="$(oci network public-ip get --region "$REGION" --public-ip-id "$RESERVED_IP_ID" --query 'data."ip-address"' --raw-output)"
  fi
  valid_ocid "$RESERVED_IP_ID"
  valid_ip "$RESERVED_IP_ADDRESS"
}
cutover_and_finish(){
  local id="$1" token="$2" private_id current_json current_id assigned dns_ip
  PHASE=cutover
  private_id="$(instance_private_ip_id "$id")"
  valid_ocid "$private_id"
  current_json="$(oci network public-ip get --region "$REGION" --private-ip-id "$private_id" --output json 2>/dev/null || true)"
  current_id="$(jq -r '.data.id//empty' <<<"${current_json:-{}}" 2>/dev/null || true)"
  if valid_ocid "$current_id" && [ "$current_id" != "$RESERVED_IP_ID" ]; then
    oci network public-ip delete --region "$REGION" --public-ip-id "$current_id" --force >/dev/null
    sleep 10
  fi
  assigned="$(oci network public-ip get --region "$REGION" --public-ip-id "$RESERVED_IP_ID" --query 'data."assigned-entity-id"' --raw-output 2>/dev/null || true)"
  if [ "$assigned" != "$private_id" ]; then
    oci network public-ip update --region "$REGION" --public-ip-id "$RESERVED_IP_ID" --private-ip-id "$private_id" --force >/dev/null
  fi
  for _ in $(seq 1 60); do
    assigned="$(oci network public-ip get --region "$REGION" --public-ip-id "$RESERVED_IP_ID" --query 'data."assigned-entity-id"' --raw-output 2>/dev/null || true)"
    [ "$assigned" = "$private_id" ] && break
    sleep 5
  done
  [ "$assigned" = "$private_id" ]
  PHASE=final_verify
  for _ in $(seq 1 60); do
    if probe_full "$RESERVED_IP_ADDRESS" "$token"; then break; fi
    sleep 5
  done
  probe_full "$RESERVED_IP_ADDRESS" "$token"
  oci compute instance update --region "$REGION" --instance-id "$id" --freeform-tags "$(jq -cn --arg t "$token" --arg ip "$RESERVED_IP_ADDRESS" '{NAMSBootstrapToken:$t,NAMSInstallState:"READY",NAMSReservedIP:$ip,ManagedBy:"CloudShellOneInstall"}')" --force >/dev/null
  dns_ip="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)"
  cat >"$HOME/nams-access.txt" <<ACCESS
NAMS installation is complete and fully verified.
Immediate access:
http://$RESERVED_IP_ADDRESS/?token=$token

Domain access after DNS points to the reserved IP:
https://$DOMAIN/?token=$token

Login token:
$token

DNS A record:
Host: seo
Value: $RESERVED_IP_ADDRESS
Current DNS value: ${dns_ip:-not-resolved}
ACCESS
  chmod 600 "$HOME/nams-access.txt"
  echo
  echo '============================================================'
  echo 'NAMS INSTALLATION COMPLETED AND VERIFIED'
  echo "Immediate dashboard: http://$RESERVED_IP_ADDRESS/?token=$token"
  echo "Login token: $token"
  echo "Reserved IP: $RESERVED_IP_ADDRESS"
  if [ "$dns_ip" = "$RESERVED_IP_ADDRESS" ]; then
    echo "Domain: https://$DOMAIN/?token=$token"
  else
    echo "DNS CHANGE REQUIRED: A record seo -> $RESERVED_IP_ADDRESS"
    echo "Current DNS: ${dns_ip:-not resolved}"
  fi
  echo "Saved securely: $HOME/nams-access.txt"
  echo '============================================================'
}

on_error(){
  local rc=$?
  set +e
  log "FAILED phase=$PHASE rc=$rc"
  capture_console "$NEW_ID" failed-candidate
  if valid_ocid "$NEW_ID" && ! probe_full "$(instance_public_ip "$NEW_ID")" "$TOKEN" 2>/dev/null; then
    log 'Retiring the failed fresh candidate to release free-tier resources.'
    oci compute instance terminate --region "$REGION" --instance-id "$NEW_ID" --preserve-boot-volume false --force >/dev/null 2>&1 || true
  fi
  echo "Diagnostics: $DIAG"
  echo "Full log: $LOG"
  exit "$rc"
}
trap on_error ERR

log 'NAMS one-command Cloud Shell installer'
log 'WAHA is read-only and will not be modified.'
for cmd in oci jq curl openssl base64; do command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 2; }; done
oci iam region-subscription list --region "$REGION" --all >/dev/null

PHASE=placement
COMPARTMENT_ID="$(oci iam compartment list --region "$REGION" --all --compartment-id-in-subtree true --access-level ACCESSIBLE --name "$COMPARTMENT_NAME" --lifecycle-state ACTIVE --query 'data[0].id' --raw-output 2>/dev/null || true)"
if ! valid_ocid "$COMPARTMENT_ID"; then
  COMPARTMENT_ID="$COMPARTMENT_ID_HINT"
fi
oci iam compartment get --region "$REGION" --compartment-id "$COMPARTMENT_ID" >/dev/null
REFERENCE_ID="$(oci compute instance list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --display-name "$REFERENCE_INSTANCE" --all --output json | jq -r '[.data[]|select(.["lifecycle-state"]=="RUNNING")|.id][0]//empty')"
valid_ocid "$REFERENCE_ID"
AD="$(oci compute instance get --region "$REGION" --instance-id "$REFERENCE_ID" --query 'data."availability-domain"' --raw-output)"
IMAGE_ID="$(oci compute instance get --region "$REGION" --instance-id "$REFERENCE_ID" --query 'data."image-id"' --raw-output)"
SUBNET_ID="$(oci compute instance list-vnics --region "$REGION" --instance-id "$REFERENCE_ID" --query 'data[0]."subnet-id"' --raw-output)"
VCN_ID="$(oci network subnet get --region "$REGION" --subnet-id "$SUBNET_ID" --query 'data."vcn-id"' --raw-output)"
valid_ocid "$IMAGE_ID"; valid_ocid "$SUBNET_ID"; valid_ocid "$VCN_ID"
log "Placement resolved from WAHA: AD=$AD"

PHASE=network_security
NSG_ID="$(oci network nsg list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" --display-name "$NSG_NAME" --all --query 'data[0].id' --raw-output 2>/dev/null || true)"
if ! valid_ocid "$NSG_ID"; then
  NSG_ID="$(oci network nsg create --region "$REGION" --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" --display-name "$NSG_NAME" --query 'data.id' --raw-output)"
fi
ensure_rule 22; ensure_rule 80; ensure_rule 443
RULES="$(oci network nsg rules list --region "$REGION" --nsg-id "$NSG_ID" --all --output json)"
if ! jq -e '.data[]? | select(.direction=="EGRESS" and .protocol=="all" and .destination=="0.0.0.0/0")' <<<"$RULES" >/dev/null; then
  echo '[{"direction":"EGRESS","protocol":"all","destination":"0.0.0.0/0","destinationType":"CIDR_BLOCK","isStateless":false}]' >"$WORK/egress.json"
  oci network nsg rules add --region "$REGION" --nsg-id "$NSG_ID" --security-rules "file://$WORK/egress.json" >/dev/null
fi
ensure_reserved_ip
log "Reserved IP ready: $RESERVED_IP_ADDRESS"

PHASE=existing_instance
mapfile -t ACTIVE_IDS < <(oci compute instance list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --display-name "$TARGET_NAME" --all --output json | jq -r '.data[]|select(.["lifecycle-state"]!="TERMINATED")|.id')
for id in "${ACTIVE_IDS[@]:-}"; do
  valid_ocid "$id" || continue
  existing_token="$(instance_token "$id")"
  state="$(instance_state "$id")"
  log "Existing NAMS instance found: state=$state"
  if [ -n "$existing_token" ] && [ "$existing_token" != null ] && [ "$existing_token" != None ]; then
    if wait_for_full_stack "$id" "$existing_token"; then
      NEW_ID="$id"; TOKEN="$existing_token"
      cutover_and_finish "$NEW_ID" "$TOKEN"
      exit 0
    fi
  fi
  log 'Existing NAMS instance is not verified healthy; preserving its boot volume and retiring only that NAMS compute.'
  oci compute instance terminate --region "$REGION" --instance-id "$id" --preserve-boot-volume true --force >/dev/null
  poll_state "$id" TERMINATED 270
done

PHASE=cloud_init
BOOTSTRAP=$(cat <<BOOT
#!/usr/bin/env bash
set -Eeuo pipefail
for i in \$(seq 1 120); do getent hosts raw.githubusercontent.com >/dev/null 2>&1 && break; sleep 5; done
curl -fL --retry 10 --retry-delay 10 --connect-timeout 20 'https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/${INSTALLER_REF}/nams-deploy/install-source-fallback.sh' -o /root/nams-install.sh
chmod 700 /root/nams-install.sh
env ADMIN_TOKEN='${TOKEN}' NAMS_DOMAIN='${DOMAIN}' NAMS_SOURCE_REF='${SOURCE_REF}' NAMS_IMAGE_TAG='${IMAGE_TAG}' bash /root/nams-install.sh
BOOT
)
BOOTSTRAP_B64="$(printf '%s' "$BOOTSTRAP" | base64 -w0)"
cat >"$WORK/cloud-init.yaml" <<CLOUD
#cloud-config
package_update: false
write_files:
  - path: /root/nams-bootstrap.sh
    permissions: '0700'
    encoding: b64
    content: ${BOOTSTRAP_B64}
runcmd:
  - [ bash, -lc, '/root/nams-bootstrap.sh' ]
final_message: 'NAMS one-command installation finished'
CLOUD

PHASE=launch
log 'Launching fresh NAMS at 1 OCPU / 8 GB using distinct fault-domain placements.'
: >"$DIAG/launch-errors.txt"
TAGS="$(jq -cn --arg t "$TOKEN" '{NAMSBootstrapToken:$t,NAMSInstallState:"INSTALLING",ManagedBy:"CloudShellOneInstall"}')"
launch_candidate(){
  local label="$1" fd="$2" out rc hostname
  hostname="nams$(date +%m%d%H%M)"
  local -a cmd=(oci compute instance launch --region "$REGION" --availability-domain "$AD" --compartment-id "$COMPARTMENT_ID" --display-name "$TARGET_NAME" --hostname-label "$hostname" --shape "$SHAPE" --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}" --image-id "$IMAGE_ID" --subnet-id "$SUBNET_ID" --assign-public-ip true --nsg-ids "[\"$NSG_ID\"]" --user-data-file "$WORK/cloud-init.yaml" --freeform-tags "$TAGS" --query 'data.id' --raw-output)
  [ -z "$fd" ] || cmd+=(--fault-domain "$fd")
  set +e
  out="$("${cmd[@]}" 2>"$WORK/launch-${label}.err")"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ] && valid_ocid "$out"; then NEW_ID="$out"; return 0; fi
  { echo "===== profile=$label rc=$rc ====="; cat "$WORK/launch-${label}.err"; } >>"$DIAG/launch-errors.txt"
  return 1
}
for profile in auto FAULT-DOMAIN-1 FAULT-DOMAIN-2 FAULT-DOMAIN-3; do
  fd=''; [ "$profile" = auto ] || fd="$profile"
  if launch_candidate "$profile" "$fd"; then log "Launch accepted: $profile"; break; fi
  if grep -Eqi 'LimitExceeded|QuotaExceeded|NotAuthorized|InvalidParameter|NotAuthenticated' "$WORK/launch-${profile}.err"; then
    cat "$WORK/launch-${profile}.err" >&2
    exit 32
  fi
  if ! grep -Eqi 'Out of host capacity|host capacity|TooManyRequests|InternalError|ServiceUnavailable|capacity' "$WORK/launch-${profile}.err"; then
    cat "$WORK/launch-${profile}.err" >&2
    exit 33
  fi
  log "Capacity unavailable at $profile; trying next distinct placement."
done
if ! valid_ocid "$NEW_ID"; then
  cat "$DIAG/launch-errors.txt" >&2
  echo 'All distinct free A1 placements are currently out of host capacity.' >&2
  exit 34
fi
poll_state "$NEW_ID" RUNNING 180
NEW_IP="$(instance_public_ip "$NEW_ID")"
for _ in $(seq 1 60); do valid_ip "$NEW_IP" && break; sleep 5; NEW_IP="$(instance_public_ip "$NEW_ID")"; done
valid_ip "$NEW_IP"
log "Candidate running on temporary IP $NEW_IP"

PHASE=install_verify
if ! wait_for_full_stack "$NEW_ID" "$TOKEN"; then
  capture_console "$NEW_ID" install-timeout
  echo 'The VM launched but the full stack did not verify within 90 minutes.' >&2
  exit 40
fi
log 'All application, browser, noVNC, Lightpanda, Ollama and model checks passed.'
cutover_and_finish "$NEW_ID" "$TOKEN"
