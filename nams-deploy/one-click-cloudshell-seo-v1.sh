#!/usr/bin/env bash
set -Eeuo pipefail

# NAMS full-stack one-click installer for Oracle Cloud Shell.
# The existing 1 GB E2.Micro instance is used only as a VCN/subnet reference.
# A correctly sized Always Free Ampere A1 instance is launched for the full stack.

REGION="${OCI_REGION:-ap-mumbai-1}"
REFERENCE_IP="${REFERENCE_IP:-130.210.31.138}"
DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}"
TARGET_NAME="${NAMS_INSTANCE_NAME:-NAMS-SEO-Agent}"
NSG_NAME="${NAMS_NSG_NAME:-NAMS-SEO-NSG}"
RESERVED_IP_HINT="${NAMS_RESERVED_IP:-161.118.166.225}"
SOURCE_REF="c74d8660d516e9330a9ad4f24742b10c43c487c4"
IMAGE_TAG="c74d8660d516e9330a9ad4f24742b10c43c487c4-cdp1"
INSTALLER_REF="1bf9e499c3d501cd9740ce5ac7af3bfd48c39f2c"
SHAPE="VM.Standard.A1.Flex"
OCPUS=1
MEMORY_GB=12
WORK="${HOME}/nams-one-click-$(date +%Y%m%d-%H%M%S)"
KEY="${HOME}/.ssh/nams-seo-ed25519"
TOKEN="$(openssl rand -hex 24)"
NEW_ID=""
NEW_IP=""
SUCCESS=0
mkdir -p "$WORK" "$(dirname "$KEY")"

log(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
valid_ocid(){ [[ "${1:-}" == ocid1.* ]]; }
cleanup(){
  rc=$?
  if [ "$SUCCESS" -ne 1 ] && valid_ocid "$NEW_ID"; then
    log "Installation failed; removing the incomplete candidate to avoid wasting compute resources."
    oci compute instance terminate --region "$REGION" --instance-id "$NEW_ID" --preserve-boot-volume false --force >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap cleanup EXIT

log "Preflight: validating OCI Cloud Shell session"
command -v oci >/dev/null
command -v jq >/dev/null
command -v openssl >/dev/null
oci iam region-subscription list --all >/dev/null

TENANCY_OCID="${OCI_TENANCY_OCID:-}"
if ! valid_ocid "$TENANCY_OCID"; then
  TENANCY_OCID="$(awk -F= '/^[[:space:]]*tenancy[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2;exit}' "$HOME/.oci/config" 2>/dev/null || true)"
fi
valid_ocid "$TENANCY_OCID" || { echo "Could not determine tenancy OCID from Cloud Shell." >&2; exit 2; }

log "Locating the new reference instance with public IP $REFERENCE_IP"
REFERENCE_ID=""
REFERENCE_COMPARTMENT=""
while IFS=$'\t' read -r compartment_id instance_id; do
  [ -n "$instance_id" ] || continue
  ip="$(oci compute instance list-vnics --region "$REGION" --instance-id "$instance_id" --query 'data[0]."public-ip"' --raw-output 2>/dev/null || true)"
  if [ "$ip" = "$REFERENCE_IP" ]; then
    REFERENCE_ID="$instance_id"
    REFERENCE_COMPARTMENT="$compartment_id"
    break
  fi
done < <(
  {
    printf '%s\n' "$TENANCY_OCID"
    oci iam compartment list --region "$REGION" --compartment-id "$TENANCY_OCID" --compartment-id-in-subtree true --access-level ACCESSIBLE --lifecycle-state ACTIVE --all --query 'data[].id' --raw-output 2>/dev/null | tr -d '[],' | tr ' ' '\n' | tr -d '"'
  } | awk 'NF' | sort -u | while read -r cid; do
    oci compute instance list --region "$REGION" --compartment-id "$cid" --lifecycle-state RUNNING --all --output json 2>/dev/null | jq -r --arg c "$cid" '.data[] | [$c,.id] | @tsv'
  done
)
valid_ocid "$REFERENCE_ID" || { echo "No running instance with public IP $REFERENCE_IP was found." >&2; exit 3; }

AD="$(oci compute instance get --region "$REGION" --instance-id "$REFERENCE_ID" --query 'data."availability-domain"' --raw-output)"
SUBNET_ID="$(oci compute instance list-vnics --region "$REGION" --instance-id "$REFERENCE_ID" --query 'data[0]."subnet-id"' --raw-output)"
VCN_ID="$(oci network subnet get --region "$REGION" --subnet-id "$SUBNET_ID" --query 'data."vcn-id"' --raw-output)"
valid_ocid "$SUBNET_ID"; valid_ocid "$VCN_ID"; valid_ocid "$REFERENCE_COMPARTMENT"
echo "Reference instance: $REFERENCE_ID"
echo "Compartment: $REFERENCE_COMPARTMENT"
echo "Availability domain: $AD"

log "Checking that no active full NAMS instance already exists"
ACTIVE_ID="$(oci compute instance list --region "$REGION" --compartment-id "$REFERENCE_COMPARTMENT" --display-name "$TARGET_NAME" --all --output json | jq -r '[.data[]|select(."lifecycle-state"!="TERMINATED")][0].id // empty')"
if valid_ocid "$ACTIVE_ID"; then
  echo "An active instance named $TARGET_NAME already exists: $ACTIVE_ID" >&2
  echo "The installer will not create a duplicate." >&2
  exit 4
fi

log "Creating/reusing a dedicated NSG and opening only SSH, HTTP and HTTPS"
NSG_ID="$(oci network nsg list --region "$REGION" --compartment-id "$REFERENCE_COMPARTMENT" --vcn-id "$VCN_ID" --display-name "$NSG_NAME" --all --query 'data[0].id' --raw-output 2>/dev/null || true)"
if ! valid_ocid "$NSG_ID"; then
  NSG_ID="$(oci network nsg create --region "$REGION" --compartment-id "$REFERENCE_COMPARTMENT" --vcn-id "$VCN_ID" --display-name "$NSG_NAME" --query 'data.id' --raw-output)"
fi
RULES="$(oci network nsg rules list --region "$REGION" --nsg-id "$NSG_ID" --all --output json)"
for port in 22 80 443; do
  if ! jq -e --argjson p "$port" '.data[]? | select(.direction=="INGRESS" and .protocol=="6" and .source=="0.0.0.0/0") | .["tcp-options"]["destination-port-range"] | select(.min <= $p and .max >= $p)' <<<"$RULES" >/dev/null; then
    printf '[{"direction":"INGRESS","protocol":"6","source":"0.0.0.0/0","sourceType":"CIDR_BLOCK","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":%s,"max":%s}}}]' "$port" "$port" >"$WORK/rule-$port.json"
    oci network nsg rules add --region "$REGION" --nsg-id "$NSG_ID" --security-rules "file://$WORK/rule-$port.json" >/dev/null
  fi
done
if ! jq -e '.data[]? | select(.direction=="EGRESS" and .protocol=="all" and .destination=="0.0.0.0/0")' <<<"$RULES" >/dev/null; then
  echo '[{"direction":"EGRESS","protocol":"all","destination":"0.0.0.0/0","destinationType":"CIDR_BLOCK","isStateless":false}]' >"$WORK/egress.json"
  oci network nsg rules add --region "$REGION" --nsg-id "$NSG_ID" --security-rules "file://$WORK/egress.json" >/dev/null
fi

log "Selecting Ubuntu 24.04 ARM image"
IMAGE_ID="$(oci compute image list --region "$REGION" --compartment-id "$REFERENCE_COMPARTMENT" --shape "$SHAPE" --operating-system 'Canonical Ubuntu' --operating-system-version '24.04' --sort-by TIMECREATED --sort-order DESC --all --query 'data[0].id' --raw-output)"
valid_ocid "$IMAGE_ID" || { echo "Ubuntu 24.04 ARM image was not found." >&2; exit 5; }

if [ ! -s "$KEY" ]; then
  ssh-keygen -q -t ed25519 -N '' -f "$KEY"
fi
chmod 600 "$KEY"

log "Preparing noninteractive cloud-init installation"
BOOTSTRAP=$(cat <<BOOT
#!/usr/bin/env bash
set -Eeuo pipefail
curl -fL --retry 10 --retry-delay 10 --connect-timeout 20 \
  'https://raw.githubusercontent.com/nitutravels/fintimesnews-public-worker-v2/${INSTALLER_REF}/nams-deploy/install-certified.sh' \
  -o /root/install-certified.sh
chmod 700 /root/install-certified.sh
env ADMIN_TOKEN='${TOKEN}' \
  NAMS_DOMAIN='${DOMAIN}' \
  NAMS_SOURCE_REF='${SOURCE_REF}' \
  NAMS_IMAGE_TAG='${IMAGE_TAG}' \
  OLLAMA_MODEL='gemma3:1b' \
  GHCR_USER='nitutravels' \
  GHCR_TOKEN_B64='' \
  bash /root/install-certified.sh
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
final_message: 'NAMS full-stack installation finished'
CLOUD

log "Launching the full-stack Always Free A1 server (1 OCPU, 12 GB RAM)"
: >"$WORK/launch-errors.log"
for fd in auto FAULT-DOMAIN-1 FAULT-DOMAIN-2 FAULT-DOMAIN-3; do
  cmd=(oci compute instance launch --region "$REGION" --availability-domain "$AD" --compartment-id "$REFERENCE_COMPARTMENT" --display-name "$TARGET_NAME" --hostname-label nams-seo --shape "$SHAPE" --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}" --image-id "$IMAGE_ID" --subnet-id "$SUBNET_ID" --assign-public-ip true --nsg-ids "[\"$NSG_ID\"]" --user-data-file "$WORK/cloud-init.yaml" --ssh-authorized-keys-file "$KEY.pub" --query 'data.id' --raw-output)
  [ "$fd" = auto ] || cmd+=(--fault-domain "$fd")
  set +e
  candidate="$("${cmd[@]}" 2>"$WORK/launch-$fd.err")"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ] && valid_ocid "$candidate"; then
    NEW_ID="$candidate"
    echo "Launch accepted in placement $fd"
    break
  fi
  { echo "===== $fd rc=$rc ====="; cat "$WORK/launch-$fd.err"; } >>"$WORK/launch-errors.log"
  if ! grep -Eqi 'capacity|Out of host capacity|TooManyRequests|Too many requests|InternalError' "$WORK/launch-$fd.err"; then
    cat "$WORK/launch-$fd.err" >&2
    exit 6
  fi
  sleep 30
done
valid_ocid "$NEW_ID" || { echo "Oracle had no A1 capacity in any fault domain." >&2; cat "$WORK/launch-errors.log" >&2; exit 7; }

log "Waiting for the instance to become RUNNING"
for i in $(seq 1 180); do
  state="$(oci compute instance get --region "$REGION" --instance-id "$NEW_ID" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)"
  [ "$state" = RUNNING ] && break
  [ "$state" = TERMINATED ] && { echo "Candidate terminated during launch." >&2; exit 8; }
  sleep 10
done
[ "${state:-}" = RUNNING ] || { echo "Instance did not reach RUNNING state." >&2; exit 9; }
NEW_IP="$(oci compute instance list-vnics --region "$REGION" --instance-id "$NEW_ID" --query 'data[0]."public-ip"' --raw-output)"
echo "Candidate public IP: $NEW_IP"

log "Waiting for SSH and monitoring the real installer status"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 ubuntu@"$NEW_IP")
for i in $(seq 1 120); do
  if "${SSH[@]}" 'echo ready' >/dev/null 2>&1; then break; fi
  [ "$i" -eq 120 ] && { echo "SSH did not become reachable." >&2; exit 10; }
  sleep 5
done

for i in $(seq 1 540); do
  status="$("${SSH[@]}" 'sudo cat /var/lib/nams-install.status 2>/dev/null || echo BOOTING' 2>/dev/null || echo BOOTING)"
  case "$status" in
    SUCCESS*) break ;;
    FAILED*)
      echo "Installer reported: $status" >&2
      "${SSH[@]}" 'sudo tail -n 300 /var/log/nams-install.log; cd /opt/nams 2>/dev/null && sudo docker compose ps && sudo docker compose logs --tail=200 || true' || true
      exit 11
      ;;
  esac
  if [ $((i % 12)) -eq 0 ]; then
    echo "Installation still running: $((i/12)) minute(s); status=$status"
  fi
  sleep 5
done
[ "${status:-}" = SUCCESS ] || { echo "Installation did not complete within 45 minutes." >&2; "${SSH[@]}" 'sudo tail -n 300 /var/log/nams-install.log' || true; exit 12; }

log "Performing full-stack verification"
"${SSH[@]}" "sudo bash -lc 'cd /opt/nams && docker compose ps && test \"\$(cat /var/lib/nams-install.status)\" = SUCCESS && curl -fsS -H \"X-NAMS-Probe: $TOKEN\" http://127.0.0.1/_probe/app/health && curl -fsS -H \"X-NAMS-Probe: $TOKEN\" http://127.0.0.1/_probe/chromium/json/version | grep -q webSocketDebuggerUrl && curl -fsS -H \"X-NAMS-Probe: $TOKEN\" http://127.0.0.1/_probe/novnc/vnc.html | grep -qi noVNC && curl -fsS -H \"X-NAMS-Probe: $TOKEN\" http://127.0.0.1/_probe/lightpanda/json/version >/dev/null && curl -fsS -H \"X-NAMS-Probe: $TOKEN\" http://127.0.0.1/_probe/ollama/api/tags | grep -q gemma3'"

log "Attaching the existing reserved NAMS IP when available"
FINAL_IP="$NEW_IP"
RESERVED_JSON="$(oci network public-ip list --region "$REGION" --compartment-id "$REFERENCE_COMPARTMENT" --scope REGION --lifetime RESERVED --all --output json | jq -c --arg ip "$RESERVED_IP_HINT" '[.data[]|select(."ip-address"==$ip)][0] // empty')"
if [ -n "$RESERVED_JSON" ]; then
  RESERVED_ID="$(jq -r '.id' <<<"$RESERVED_JSON")"
  ATTACHED_PRIVATE="$(jq -r '."private-ip-id" // empty' <<<"$RESERVED_JSON")"
  if [ -z "$ATTACHED_PRIVATE" ]; then
    VNIC_ID="$(oci compute instance list-vnics --region "$REGION" --instance-id "$NEW_ID" --query 'data[0].id' --raw-output)"
    PRIVATE_ID="$(oci network private-ip list --region "$REGION" --vnic-id "$VNIC_ID" --all --query 'data[0].id' --raw-output)"
    oci network public-ip update --region "$REGION" --public-ip-id "$RESERVED_ID" --private-ip-id "$PRIVATE_ID" --force >/dev/null
    FINAL_IP="$RESERVED_IP_HINT"
  else
    echo "Reserved IP $RESERVED_IP_HINT is already attached elsewhere; keeping candidate IP $NEW_IP."
  fi
fi

log "Saving the login token privately in the instance tags"
oci compute instance update --region "$REGION" --instance-id "$NEW_ID" --freeform-tags "{\"NAMSBootstrapToken\":\"$TOKEN\",\"NAMSDomain\":\"$DOMAIN\",\"NAMSVerified\":\"true\"}" --force >/dev/null

SUCCESS=1
trap - EXIT
cat <<DONE

============================================================
NAMS FULL INSTALLATION VERIFIED
============================================================
Instance: $TARGET_NAME
Public IP: $FINAL_IP

CHANGE/CONFIRM THIS DNS RECORD IN BIGROCK:
Type: A
Host: seo
Value: $FINAL_IP

LOGIN TOKEN:
$TOKEN

OPEN AFTER DNS UPDATES:
https://$DOMAIN/?token=$TOKEN

The original 1 GB instance at $REFERENCE_IP was not modified.
After confirming the website works, you may terminate that unused instance.
============================================================
DONE
