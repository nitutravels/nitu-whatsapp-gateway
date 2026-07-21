#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Installs the Manage Nitu Travels continuous queue worker without SSH.
# It uses OCI Run Command through Oracle Cloud Agent on the active WAHA VM.

COMPARTMENT_OCID="${NITU_COMPARTMENT_OCID:-ocid1.compartment.oc1..aaaaaaaacufz3wn5ugdwaglqsmkbpzt4szgiiglhd672hpgppgb5ixnc4zma}"
PUBLIC_IP="${NITU_ORACLE_PUBLIC_IP:-137.23.58.166}"
REGION="${OCI_CLI_REGION:-ap-mumbai-1}"
INSTALLER_URL="https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/main/scripts/install-manage-queue-worker-v17.sh"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 2; }; }
need oci; need jq; need curl
export OCI_CLI_REGION="$REGION"

WORKER_KEY="${1:-}"
if [ -z "$WORKER_KEY" ]; then
  printf 'Paste the NEW worker key only, then press Enter: '
  IFS= read -r WORKER_KEY
fi
WORKER_KEY="${WORKER_KEY//$'\r'/}"
WORKER_KEY="${WORKER_KEY//$'\n'/}"
case "$WORKER_KEY" in
  ''|*'&'*|*' '*|*'?'*|*'='*)
    echo 'Paste only the generated key characters, without key=, URL, spaces, &, ?, or quotation marks.' >&2
    exit 2
    ;;
esac
[ "${#WORKER_KEY}" -ge 24 ] || { echo 'Worker key is unexpectedly short.' >&2; exit 2; }

printf 'Locating the running Oracle instance that owns %s...\n' "$PUBLIC_IP"
INSTANCE_ID=""
INSTANCE_NAME=""
while IFS=$'\t' read -r iid name; do
  [ -n "$iid" ] || continue
  while IFS= read -r vnic_id; do
    [ -n "$vnic_id" ] || continue
    ip="$(oci network vnic get --vnic-id "$vnic_id" --query 'data."public-ip"' --raw-output 2>/dev/null || true)"
    if [ "$ip" = "$PUBLIC_IP" ]; then
      INSTANCE_ID="$iid"
      INSTANCE_NAME="$name"
      break 2
    fi
  done < <(oci compute vnic-attachment list --compartment-id "$COMPARTMENT_OCID" --instance-id "$iid" --all 2>/dev/null | jq -r '.data[]."vnic-id"')
done < <(oci compute instance list --compartment-id "$COMPARTMENT_OCID" --all 2>/dev/null | jq -r '.data[] | select(."lifecycle-state"=="RUNNING") | [.id,."display-name"] | @tsv')

[ -n "$INSTANCE_ID" ] || {
  echo "Could not find a running instance with public IP $PUBLIC_IP in the configured compartment." >&2
  exit 3
}
printf 'Target: %s (%s)\n' "$INSTANCE_NAME" "$INSTANCE_ID"

BASE_URL='https://manage.nitutravels.in/whatsapp-dispatch-worker.php'
FULL_URL="${BASE_URL}?key=${WORKER_KEY}&limit=25&budget=45&source=oracle-continuous&worker_version=v17.0"
REMOTE_SCRIPT=$(cat <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
tmp=\$(mktemp)
trap 'rm -f "\$tmp"' EXIT
curl -fsSL '$INSTALLER_URL' -o "\$tmp"
bash -n "\$tmp"
bash "\$tmp" '$FULL_URL'
EOF
)

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
jq -n --arg text "$REMOTE_SCRIPT" '{source:{sourceType:"TEXT",text:$text},output:{outputType:"TEXT"}}' > "$WORKDIR/content.json"
jq -n --arg id "$INSTANCE_ID" '{instanceId:$id}' > "$WORKDIR/target.json"

printf 'Submitting OCI Run Command...\n'
COMMAND_ID="$(oci instance-agent command create \
  --compartment-id "$COMPARTMENT_OCID" \
  --content "file://$WORKDIR/content.json" \
  --target "file://$WORKDIR/target.json" \
  --timeout-in-seconds 600 \
  --display-name 'Install Nitu WhatsApp continuous worker v17' \
  --query 'data.id' --raw-output)"

printf 'Command ID: %s\n' "$COMMAND_ID"
for _ in $(seq 1 60); do
  RESULT="$(oci instance-agent command-execution get --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID")"
  STATE="$(jq -r '.data."lifecycle-state" // .data.lifecycleState // "UNKNOWN"' <<<"$RESULT")"
  printf 'State: %s\n' "$STATE"
  case "$STATE" in
    SUCCEEDED)
      jq '.data.content // .data' <<<"$RESULT"
      echo 'Installed through Oracle Cloud Agent. Refresh Admin -> WhatsApp Delivery in 30 seconds.'
      exit 0
      ;;
    FAILED|CANCELED|TIMED_OUT)
      jq '.data' <<<"$RESULT"
      exit 4
      ;;
  esac
  sleep 10
done

echo 'The command did not finish within 10 minutes. Check OCI Run Command status in the instance console.' >&2
exit 5
