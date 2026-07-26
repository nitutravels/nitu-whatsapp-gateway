#!/usr/bin/env bash
set -Eeuo pipefail

REGION="${OCI_REGION:-ap-mumbai-1}"
NEW_NAME="NAMS-Authority-Agent"
DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}"
SHAPE="VM.Standard.A1.Flex"
OCPUS=2
MEMORY_GB=12
MODEL="qwen2.5:7b-instruct"
SUPPORT_REF="01a27dc20b5b104dfea74f62179c05e87a34a3c0"
INSTALLER_URL="https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/${SUPPORT_REF}/nams-a1-quality/install-ubuntu-a1.sh"
TOKEN="${ADMIN_TOKEN:-$(openssl rand -hex 24)}"
OLD_NAMES=("NAMS-Lightpanda-Agent-Candidate" "instance-20260723-2200")
NSG_NAME="NAMS-SEO-A1-PUBLIC"
RESERVED_IP_NAME="NAMS-SEO-Reserved-IP"

say(){ printf '\n=== %s ===\n' "$*"; }
fail(){ echo "ERROR: $*" >&2; exit 1; }
trap 'rc=$?; echo; echo "Controller stopped at line $LINENO (exit $rc). The WAHA/WhatsApp instance was never targeted." >&2; exit $rc' ERR

command -v oci >/dev/null || fail "OCI CLI is unavailable in Cloud Shell."
command -v jq >/dev/null || fail "jq is unavailable in Cloud Shell."
command -v openssl >/dev/null || fail "openssl is unavailable in Cloud Shell."

echo "NAMS one-line replacement deployment"
echo "New shape: $SHAPE, $OCPUS OCPUs, ${MEMORY_GB} GB RAM"
echo "Writing model: $MODEL"
echo "Lightpanda: removed; Chromium handles discovery and submissions"
echo "Safety: only the two exact obsolete E2 instance names may be terminated"

find_running_by_name(){
  local name="$1"
  oci search resource structured-search --region "$REGION" \
    --query-text "query instance resources where displayName = '$name'" --output json 2>/dev/null |
    jq -r '[.data.items[]? | select((.["lifecycle-state"] // .lifecycleState // "") == "RUNNING")] | sort_by(.["time-created"] // .timeCreated // "") | last | .identifier // empty'
}

say "1/10 Resolving the two obsolete NAMS E2 instances"
OLD_IDS=()
SOURCE_ID=""
for name in "${OLD_NAMES[@]}"; do
  id="$(find_running_by_name "$name")"
  if [ -n "$id" ]; then
    json="$(oci compute instance get --region "$REGION" --instance-id "$id" --output json)"
    actual="$(jq -r '.data["display-name"]' <<<"$json")"
    shape="$(jq -r '.data.shape' <<<"$json")"
    [[ "$actual" != *WAHA* && "$actual" != *whatsapp* && "$actual" != *WhatsApp* ]] || fail "Safety stop: $actual resembles WAHA/WhatsApp."
    [ "$actual" = "$name" ] || fail "Safety stop: expected $name but resolved $actual."
    [ "$shape" = "VM.Standard.E2.1.Micro" ] || fail "Safety stop: $actual is $shape, not the obsolete E2 Micro shape."
    OLD_IDS+=("$id")
    [ -n "$SOURCE_ID" ] || SOURCE_ID="$id"
    echo "Found obsolete instance: $actual ($id)"
  else
    echo "Already absent or not running: $name"
  fi
done
[ -n "$SOURCE_ID" ] || fail "Neither exact obsolete instance is running, so network placement cannot be inherited safely."

SOURCE_JSON="$(oci compute instance get --region "$REGION" --instance-id "$SOURCE_ID" --output json)"
COMPARTMENT_ID="$(jq -r '.data["compartment-id"]' <<<"$SOURCE_JSON")"
AD="$(jq -r '.data["availability-domain"]' <<<"$SOURCE_JSON")"
SOURCE_VNICS="$(oci compute instance list-vnics --region "$REGION" --instance-id "$SOURCE_ID" --output json)"
SOURCE_VNIC_ID="$(jq -r '.data[0].id // empty' <<<"$SOURCE_VNICS")"
SUBNET_ID="$(jq -r '.data[0]["subnet-id"] // empty' <<<"$SOURCE_VNICS")"
[ -n "$SOURCE_VNIC_ID" ] && [ -n "$SUBNET_ID" ] || fail "Source VNIC/subnet could not be resolved."
VCN_ID="$(oci network subnet get --region "$REGION" --subnet-id "$SUBNET_ID" --query 'data."vcn-id"' --raw-output)"
EXISTING_NSGS="$(oci network vnic get --region "$REGION" --vnic-id "$SOURCE_VNIC_ID" --output json | jq -c '.data["nsg-ids"] // []')"

say "2/10 Preparing the public NSG"
NSG_ID="$(oci network nsg list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" --all --output json | jq -r --arg n "$NSG_NAME" '[.data[]? | select(.["display-name"]==$n and .["lifecycle-state"]=="AVAILABLE")] | first | .id // empty')"
if [ -z "$NSG_ID" ]; then
  NSG_ID="$(oci network nsg create --region "$REGION" --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" --display-name "$NSG_NAME" --wait-for-state AVAILABLE --query 'data.id' --raw-output)"
fi
RULES="$(oci network nsg rules list --region "$REGION" --nsg-id "$NSG_ID" --all --output json)"
for port in 22 80 443; do
  if ! jq -e --argjson p "$port" '.data[]? | select(.direction=="INGRESS" and .protocol=="6") | select(((.["tcp-options"]["destination-port-range"].min // -1)|tonumber)==$p)' <<<"$RULES" >/dev/null; then
    rule="$(jq -n --argjson p "$port" --arg d "NAMS TCP $port" '[{direction:"INGRESS",protocol:"6",source:"0.0.0.0/0",sourceType:"CIDR_BLOCK",isStateless:false,tcpOptions:{destinationPortRange:{min:$p,max:$p}},description:$d}]')"
    oci network nsg rules add --region "$REGION" --nsg-id "$NSG_ID" --security-rules "$rule" >/dev/null
  fi
done
ALL_NSGS="$(jq -c --arg id "$NSG_ID" '. + [$id] | unique' <<<"$EXISTING_NSGS")"
printf '%s' "$ALL_NSGS" >/tmp/nams-a1-nsgs.json

echo "NSG ready: $NSG_ID"

say "3/10 Selecting the latest Ubuntu 24.04 ARM64 platform image"
IMAGE_ID="$(oci compute image list --region "$REGION" --compartment-id "$COMPARTMENT_ID" \
  --operating-system "Canonical Ubuntu" --operating-system-version "24.04" --shape "$SHAPE" \
  --all --sort-by TIMECREATED --sort-order DESC --output json |
  jq -r '[.data[]? | select(.["lifecycle-state"]=="AVAILABLE")] | first | .id // empty')"
[ -n "$IMAGE_ID" ] || fail "No Ubuntu 24.04 ARM64 image compatible with $SHAPE was found."
echo "Image: $IMAGE_ID"

say "4/10 Preparing SSH access and cloud-init"
KEY="$HOME/nams-a1.key"
if [ ! -f "$KEY" ] || [ ! -f "$KEY.pub" ]; then
  rm -f "$KEY" "$KEY.pub"
  ssh-keygen -q -t ed25519 -N '' -f "$KEY"
fi
chmod 600 "$KEY"
chmod 644 "$KEY.pub"

cat >/tmp/nams-a1-cloud-init.sh <<CLOUDINIT
#!/usr/bin/env bash
set -Eeuo pipefail
exec > >(tee -a /var/log/nams-bootstrap.log | logger -t nams-bootstrap -s 2>/dev/console) 2>&1
for i in \$(seq 1 120); do
  if curl -fsS --connect-timeout 5 https://raw.githubusercontent.com/ >/dev/null 2>&1; then break; fi
  sleep 5
done
curl -fsSL '$INSTALLER_URL' | env \
  ADMIN_TOKEN='$TOKEN' \
  NAMS_DOMAIN='$DOMAIN' \
  NAMS_SUPPORT_REF='$SUPPORT_REF' \
  NAMS_SOURCE_REF='c74d8660d516e9330a9ad4f24742b10c43c487c4' \
  OLLAMA_MODEL='$MODEL' \
  bash
CLOUDINIT
chmod 600 /tmp/nams-a1-cloud-init.sh

jq -n --arg token "$TOKEN" --arg domain "$DOMAIN" --arg model "$MODEL" \
  '{NAMSBootstrapToken:$token,NAMSDomain:$domain,NAMSModel:$model,NAMSStatus:"Installing",NAMSProfile:"A1-2OCPU-12GB-NoLightpanda"}' \
  >/tmp/nams-a1-tags.json

say "5/10 Launching the required A1 instance with capacity-aware placement"
NEW_ID=""
for fd in AUTO FAULT-DOMAIN-1 FAULT-DOMAIN-2 FAULT-DOMAIN-3; do
  echo "Trying placement: $fd"
  cmd=(oci compute instance launch --region "$REGION" --compartment-id "$COMPARTMENT_ID" \
    --availability-domain "$AD" --display-name "$NEW_NAME" --shape "$SHAPE" \
    --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}" \
    --image-id "$IMAGE_ID" --subnet-id "$SUBNET_ID" --assign-public-ip false \
    --nsg-ids file:///tmp/nams-a1-nsgs.json --ssh-authorized-keys-file "$KEY.pub" \
    --user-data-file /tmp/nams-a1-cloud-init.sh --freeform-tags file:///tmp/nams-a1-tags.json \
    --hostname-label namsauthority --output json)
  [ "$fd" = AUTO ] || cmd+=(--fault-domain "$fd")
  set +e
  "${cmd[@]}" >/tmp/nams-a1-launch.json 2>/tmp/nams-a1-launch.err
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    NEW_ID="$(jq -r '.data.id // empty' /tmp/nams-a1-launch.json)"
    [ -n "$NEW_ID" ] && break
  fi
  if grep -Eqi 'out of host capacity|insufficient capacity|capacity is not available|LimitExceeded' /tmp/nams-a1-launch.err; then
    cat /tmp/nams-a1-launch.err
    continue
  fi
  cat /tmp/nams-a1-launch.err >&2
  fail "A1 launch failed for a reason other than host placement capacity."
done
[ -n "$NEW_ID" ] || fail "Oracle reported no A1 capacity in all available fault-domain placements. The two old instances were NOT terminated."
echo "New instance OCID: $NEW_ID"

say "6/10 Waiting for the new A1 VM to reach RUNNING"
STATE=""
for i in $(seq 1 120); do
  STATE="$(oci compute instance get --region "$REGION" --instance-id "$NEW_ID" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)"
  [ "$STATE" = RUNNING ] && break
  case "$STATE" in TERMINATED|TERMINATING) fail "The new A1 instance entered $STATE.";; esac
  [ $((i % 6)) -eq 0 ] && echo "New VM state: ${STATE:-unknown}; $((i/2)) minute(s)"
  sleep 10
done
[ "$STATE" = RUNNING ] || fail "New A1 instance did not reach RUNNING within 20 minutes. The old instances were NOT terminated."

say "7/10 Attaching a stable reserved public IP"
RESERVED_JSON="$(oci network public-ip list --region "$REGION" --compartment-id "$COMPARTMENT_ID" --scope REGION --all --output json)"
PUBLIC_IP_ID="$(jq -r --arg n "$RESERVED_IP_NAME" '[.data[]? | select(.lifetime=="RESERVED" and .["display-name"]==$n)] | first | .id // empty' <<<"$RESERVED_JSON")"
if [ -z "$PUBLIC_IP_ID" ]; then
  PUBLIC_IP_ID="$(jq -r '[.data[]? | select(.lifetime=="RESERVED" and .["ip-address"]=="161.118.166.225" and (.["private-ip-id"]==null))] | first | .id // empty' <<<"$RESERVED_JSON")"
fi
if [ -z "$PUBLIC_IP_ID" ]; then
  PUBLIC_IP_ID="$(oci network public-ip create --region "$REGION" --compartment-id "$COMPARTMENT_ID" --lifetime RESERVED --display-name "$RESERVED_IP_NAME" --wait-for-state AVAILABLE --query 'data.id' --raw-output)"
fi
NEW_VNIC_ID="$(oci compute instance list-vnics --region "$REGION" --instance-id "$NEW_ID" --output json | jq -r '.data[0].id // empty')"
PRIVATE_IP_ID="$(oci network private-ip list --region "$REGION" --vnic-id "$NEW_VNIC_ID" --output json | jq -r '.data[]? | select(.["is-primary"]==true) | .id' | head -1)"
[ -n "$PRIVATE_IP_ID" ] || fail "New primary private IP could not be resolved."
oci network public-ip update --region "$REGION" --public-ip-id "$PUBLIC_IP_ID" --private-ip-id "$PRIVATE_IP_ID" --force >/dev/null
PUBLIC_IP="$(oci network public-ip get --region "$REGION" --public-ip-id "$PUBLIC_IP_ID" --query 'data."ip-address"' --raw-output)"
echo "Reserved public IP: $PUBLIC_IP"

say "8/10 Terminating only the two exact obsolete E2 instances"
for id in "${OLD_IDS[@]}"; do
  json="$(oci compute instance get --region "$REGION" --instance-id "$id" --output json)"
  name="$(jq -r '.data["display-name"]' <<<"$json")"
  shape="$(jq -r '.data.shape' <<<"$json")"
  allowed=false
  for expected in "${OLD_NAMES[@]}"; do [ "$name" = "$expected" ] && allowed=true; done
  [ "$allowed" = true ] || fail "Safety stop before termination: unexpected instance $name."
  [ "$shape" = "VM.Standard.E2.1.Micro" ] || fail "Safety stop before termination: $name is $shape."
  oci compute instance terminate --region "$REGION" --instance-id "$id" \
    --preserve-boot-volume false --preserve-data-volumes-created-at-launch false --force >/dev/null
  echo "Termination requested: $name"
done

say "9/10 Recording deployment details"
FINAL_TAGS="$(oci compute instance get --region "$REGION" --instance-id "$NEW_ID" --query 'data."freeform-tags"' --output json | jq --arg ip "$PUBLIC_IP" '. + {NAMSPublicIP:$ip}')"
printf '%s' "$FINAL_TAGS" >/tmp/nams-a1-final-tags.json
oci compute instance update --region "$REGION" --instance-id "$NEW_ID" --freeform-tags file:///tmp/nams-a1-final-tags.json --force >/dev/null
printf '%s\n' "$TOKEN" >"$HOME/nams-a1-login-token.txt"
chmod 600 "$HOME/nams-a1-login-token.txt"

say "10/10 Deployment started successfully"
echo "The old E2 instances are being terminated."
echo "The full installation now continues inside the A1 VM through cloud-init, so Cloud Shell may be closed."
echo "Expected installation time: approximately 20-45 minutes, mainly for the 4.7 GB writing model."
echo
echo "Public IP: $PUBLIC_IP"
echo "Login token: $TOKEN"
echo "Token backup: $HOME/nams-a1-login-token.txt"
echo "Open after installation: http://$PUBLIC_IP/?token=$TOKEN"
echo
echo "DNS record after the IP responds:"
echo "  Type: A"
echo "  Host: seo"
echo "  Value: $PUBLIC_IP"
echo "Then open: https://$DOMAIN/?token=$TOKEN"
echo
echo "Later status check from Cloud Shell:"
echo "ssh -i $KEY ubuntu@$PUBLIC_IP \"sudo cat /var/lib/nams-a1-install.status 2>/dev/null || echo INSTALLING; sudo tail -n 80 /var/log/nams-a1-install.log\""
