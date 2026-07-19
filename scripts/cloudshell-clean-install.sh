#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

LOG="$HOME/nitu-waha-install.log"
exec > >(tee -a "$LOG") 2>&1
trap 'rc=$?; echo; echo "INSTALL_FAILED line=$LINENO exit=$rc"; echo "Log: $LOG"; exit $rc' ERR

PROJECT="NituTravelsWAHA"
DOMAIN="wa.nitutravels.in"
SESSION="nitu-travels"
DEPLOYMENT_ID="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="$HOME/.nitu-waha-$DEPLOYMENT_ID"
mkdir -p "$WORK"

say(){ printf '\n==> %s\n' "$*"; }
need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 2; }; }
need oci; need jq; need openssl; need ssh; need base64

say "Validate Oracle Cloud Shell authentication"
oci iam region-subscription list --all >/dev/null
TENANCY_OCID="$(awk -F= '/^[[:space:]]*tenancy[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2;exit}' "$HOME/.oci/config" 2>/dev/null || true)"
REGION="${OCI_CLI_REGION:-$(awk -F= '/^[[:space:]]*region[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2;exit}' "$HOME/.oci/config" 2>/dev/null || true)}"
[[ "$TENANCY_OCID" == ocid1.tenancy.* ]] || { echo "Could not read tenancy OCID from ~/.oci/config"; exit 3; }
[[ -n "$REGION" ]] || REGION="ap-mumbai-1"
COMPARTMENT_OCID="$TENANCY_OCID"
export OCI_CLI_REGION="$REGION"
echo "Region: $REGION"
echo "Compartment: tenancy root"

TAGS="{\"Project\":\"$PROJECT\",\"ManagedBy\":\"CloudShell\",\"DeploymentId\":\"$DEPLOYMENT_ID\"}"

say "Stop previous Nitu Travels gateway compute instances only"
mapfile -t COMPARTMENTS < <(
  printf '%s\n' "$TENANCY_OCID"
  oci iam compartment list --compartment-id "$TENANCY_OCID" --compartment-id-in-subtree true --access-level ACCESSIBLE --all 2>/dev/null \
    | jq -r '.data[] | select(."lifecycle-state"=="ACTIVE") | .id'
)
for cid in "${COMPARTMENTS[@]}"; do
  while IFS=$'\t' read -r iid name state; do
    [[ -n "$iid" ]] || continue
    if [[ "$name" =~ ^(NituTravelsWAHA|nitu-whatsapp-gateway|nitu-wa) ]]; then
      echo "Terminating $name ($state)"
      oci compute instance terminate --instance-id "$iid" --preserve-boot-volume false --force \
        --wait-for-state TERMINATED --max-wait-seconds 600 >/dev/null || true
    fi
  done < <(oci compute instance list --compartment-id "$cid" --all 2>/dev/null \
    | jq -r '.data[] | select(."lifecycle-state"!="TERMINATED") | [.id,."display-name",."lifecycle-state"] | @tsv')
done

say "Generate SSH and application credentials"
SSH_KEY="$HOME/.ssh/nitu_waha_ed25519"
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
if [[ ! -f "$SSH_KEY" ]]; then
  ssh-keygen -q -t ed25519 -N '' -f "$SSH_KEY" -C "nitu-waha-$DEPLOYMENT_ID"
fi
SSH_PUBLIC_KEY="$(cat "$SSH_KEY.pub")"
WAHA_API_KEY="$(openssl rand -hex 32)"
DASHBOARD_PASSWORD="$(openssl rand -base64 30 | tr -d '=+/\n' | cut -c1-32)"
POSTGRES_PASSWORD="$(openssl rand -base64 30 | tr -d '=+/\n' | cut -c1-32)"
WEBHOOK_SECRET="$(openssl rand -hex 32)"

say "Create isolated VCN and public subnet"
VCN_ID="$(oci network vcn create \
  --compartment-id "$COMPARTMENT_OCID" \
  --cidr-block '10.77.0.0/16' \
  --display-name "$PROJECT-VCN-$DEPLOYMENT_ID" \
  --dns-label nituwaha \
  --freeform-tags "$TAGS" \
  --wait-for-state AVAILABLE \
  --query 'data.id' --raw-output)"
IGW_ID="$(oci network internet-gateway create \
  --compartment-id "$COMPARTMENT_OCID" --vcn-id "$VCN_ID" --is-enabled true \
  --display-name "$PROJECT-IGW-$DEPLOYMENT_ID" --freeform-tags "$TAGS" \
  --wait-for-state AVAILABLE --query 'data.id' --raw-output)"
cat > "$WORK/routes.json" <<JSON
[{"cidrBlock":"0.0.0.0/0","networkEntityId":"$IGW_ID"}]
JSON
ROUTE_TABLE_ID="$(oci network route-table create \
  --compartment-id "$COMPARTMENT_OCID" --vcn-id "$VCN_ID" \
  --display-name "$PROJECT-RT-$DEPLOYMENT_ID" --route-rules "file://$WORK/routes.json" \
  --freeform-tags "$TAGS" --wait-for-state AVAILABLE --query 'data.id' --raw-output)"
cat > "$WORK/egress.json" <<'JSON'
[{"destination":"0.0.0.0/0","protocol":"all","isStateless":false}]
JSON
cat > "$WORK/ingress.json" <<'JSON'
[
 {"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":22,"max":22}}},
 {"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":80,"max":80}}},
 {"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":443,"max":443}}},
 {"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":3000,"max":3000}}}
]
JSON
SECURITY_LIST_ID="$(oci network security-list create \
  --compartment-id "$COMPARTMENT_OCID" --vcn-id "$VCN_ID" \
  --display-name "$PROJECT-SL-$DEPLOYMENT_ID" \
  --egress-security-rules "file://$WORK/egress.json" \
  --ingress-security-rules "file://$WORK/ingress.json" \
  --freeform-tags "$TAGS" --wait-for-state AVAILABLE --query 'data.id' --raw-output)"
SUBNET_ID="$(oci network subnet create \
  --compartment-id "$COMPARTMENT_OCID" --vcn-id "$VCN_ID" \
  --cidr-block '10.77.1.0/24' --display-name "$PROJECT-Subnet-$DEPLOYMENT_ID" \
  --dns-label waha --route-table-id "$ROUTE_TABLE_ID" \
  --security-list-ids "[\"$SECURITY_LIST_ID\"]" \
  --prohibit-public-ip-on-vnic false --freeform-tags "$TAGS" \
  --wait-for-state AVAILABLE --query 'data.id' --raw-output)"

say "Select Ampere A1 and latest compatible Ubuntu 24.04 ARM image"
SHAPE="VM.Standard.A1.Flex"
IMAGE_ID="$(oci compute image list --compartment-id "$COMPARTMENT_OCID" \
  --operating-system 'Canonical Ubuntu' --operating-system-version '24.04' \
  --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC --all \
  | jq -r '.data[0].id // empty')"
[[ "$IMAGE_ID" == ocid1.image.* ]] || { echo "No compatible Ubuntu 24.04 ARM image found"; exit 4; }
mapfile -t ADS < <(oci iam availability-domain list --compartment-id "$COMPARTMENT_OCID" --all | jq -r '.data[].name')
((${#ADS[@]})) || { echo "No availability domain found"; exit 5; }

say "Build first-boot WAHA installation"
cat > "$WORK/cloud-init.sh" <<CLOUD
#!/usr/bin/env bash
set -Eeuo pipefail
exec > >(tee -a /var/log/nitu-waha-cloud-init.log) 2>&1
trap 'rc=\$?; mkdir -p /opt/nitu-waha; echo "FAILED line=\$LINENO exit=\$rc" > /opt/nitu-waha/INSTALL_FAILED; exit \$rc' ERR
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg ufw jq
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \$VERSION_CODENAME stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 3000/tcp
ufw --force enable
mkdir -p /opt/nitu-waha/{postgres,sessions,media,caddy-data,caddy-config}
cd /opt/nitu-waha
cat > .env <<'ENV'
WAHA_API_KEY=$WAHA_API_KEY
WAHA_DASHBOARD_USERNAME=admin
WAHA_DASHBOARD_PASSWORD=$DASHBOARD_PASSWORD
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
WEBHOOK_SECRET=$WEBHOOK_SECRET
ENV
chmod 600 .env
cat > docker-compose.yml <<'YAML'
services:
  postgres:
    image: postgres:17-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: waha
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: postgres
    volumes:
      - ./postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U waha -d postgres"]
      interval: 10s
      timeout: 5s
      retries: 12

  waha:
    image: devlikeapro/waha:noweb-arm-2026.7.1
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "3000:3000"
    environment:
      WHATSAPP_DEFAULT_ENGINE: NOWEB
      WAHA_API_KEY: \${WAHA_API_KEY}
      WAHA_DASHBOARD_ENABLED: "true"
      WAHA_DASHBOARD_USERNAME: \${WAHA_DASHBOARD_USERNAME}
      WAHA_DASHBOARD_PASSWORD: \${WAHA_DASHBOARD_PASSWORD}
      WHATSAPP_SWAGGER_ENABLED: "false"
      WHATSAPP_SESSIONS_POSTGRESQL_URL: postgres://waha:\${POSTGRES_PASSWORD}@postgres:5432/postgres?sslmode=disable
      WAHA_NAMESPACE: all
      WAHA_WORKER_ID: nitu-travels
      WAHA_WORKER_RESTART_SESSIONS: "True"
      WHATSAPP_RESTART_ALL_SESSIONS: "True"
      WAHA_PRINT_QR: "False"
      WAHA_LOG_FORMAT: JSON
      WAHA_LOG_LEVEL: info
      WAHA_HTTP_LOG_LEVEL: warn
      WAHA_PRESENCE_AUTO_ONLINE: "True"
      WHATSAPP_DOWNLOAD_MEDIA: "false"
      WAHA_PUBLIC_URL: https://wa.nitutravels.in
      WAHA_BASE_URL: https://wa.nitutravels.in
      WHATSAPP_HOOK_URL: https://manage.nitutravels.in/whatsapp-waha-webhook.php
      WHATSAPP_HOOK_EVENTS: message.ack,session.status
      WHATSAPP_HOOK_HMAC_KEY: \${WEBHOOK_SECRET}
      WHATSAPP_HOOK_RETRIES_POLICY: exponential
      WHATSAPP_HOOK_RETRIES_DELAY_SECONDS: "2"
      WHATSAPP_HOOK_RETRIES_ATTEMPTS: "8"
      TZ: Asia/Kolkata
    volumes:
      - ./sessions:/app/.sessions
      - ./media:/app/.media

  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    depends_on:
      - waha
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy-data:/data
      - ./caddy-config:/config

YAML
cat > Caddyfile <<'CADDY'
wa.nitutravels.in {
  encode zstd gzip
  reverse_proxy waha:3000
}
CADDY

docker compose pull
docker compose up -d --wait --wait-timeout 300
curl -fsS http://127.0.0.1:3000/health >/tmp/waha-health.json
code=\$(curl -sS -o /tmp/session.json -w '%{http_code}' -H "X-Api-Key: $WAHA_API_KEY" http://127.0.0.1:3000/api/sessions/$SESSION)
if [ "\$code" = "404" ]; then
  curl -fsS -H "X-Api-Key: $WAHA_API_KEY" -H 'Content-Type: application/json' \
    -X POST --data '{"name":"$SESSION","config":{"noweb":{"store":{"enabled":true,"fullSync":false}},"metadata":{"project":"NituTravels"}}}' \
    http://127.0.0.1:3000/api/sessions >/tmp/session-create.json
fi
curl -sS -H "X-Api-Key: $WAHA_API_KEY" -H 'Content-Type: application/json' \
  -X POST --data '{}' http://127.0.0.1:3000/api/sessions/$SESSION/start >/tmp/session-start.json || true
cat > /opt/nitu-waha/INSTALL_OK <<EOF
installed_at=\$(date -Is)
engine=NOWEB
session=$SESSION
EOF
CLOUD
chmod 700 "$WORK/cloud-init.sh"
USER_DATA_B64="$(base64 -w0 "$WORK/cloud-init.sh")"
jq -n --arg ssh "$SSH_PUBLIC_KEY" --arg ud "$USER_DATA_B64" '{ssh_authorized_keys:$ssh,user_data:$ud}' > "$WORK/metadata.json"

say "Launch one clean Ampere instance; capacity plans are 2 OCPU/8 GB then 1 OCPU/6 GB"
INSTANCE_ID=""
for plan in '2 8' '1 6'; do
  read -r OCPUS MEMORY <<<"$plan"
  for AD in "${ADS[@]}"; do
    echo "Trying $SHAPE in $AD with ${OCPUS} OCPU / ${MEMORY} GB"
    set +e
    INSTANCE_ID="$(oci compute instance launch \
      --availability-domain "$AD" --compartment-id "$COMPARTMENT_OCID" \
      --display-name "$PROJECT-$DEPLOYMENT_ID" --shape "$SHAPE" \
      --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY}" \
      --subnet-id "$SUBNET_ID" --assign-public-ip false \
      --source-details "{\"sourceType\":\"image\",\"imageId\":\"$IMAGE_ID\",\"bootVolumeSizeInGBs\":50}" \
      --metadata "file://$WORK/metadata.json" --freeform-tags "$TAGS" \
      --instance-options '{"areLegacyImdsEndpointsDisabled":true}' \
      --wait-for-state RUNNING --max-wait-seconds 600 \
      --query 'data.id' --raw-output 2>"$WORK/launch.err")"
    rc=$?
    set -e
    if [[ $rc -eq 0 && "$INSTANCE_ID" == ocid1.instance.* ]]; then
      SELECTED_AD="$AD"; SELECTED_OCPUS="$OCPUS"; SELECTED_MEMORY="$MEMORY"; break 2
    fi
    cat "$WORK/launch.err"
    INSTANCE_ID=""
  done
done
[[ "$INSTANCE_ID" == ocid1.instance.* ]] || { echo "No Ampere A1 capacity was available. No paid shape was created."; exit 6; }

say "Attach a reserved public IPv4 address"
VNIC_ID="$(oci compute vnic-attachment list --compartment-id "$COMPARTMENT_OCID" --instance-id "$INSTANCE_ID" \
  --query 'data[0]."vnic-id"' --raw-output)"
PRIVATE_IP_ID="$(oci network private-ip list --vnic-id "$VNIC_ID" --query 'data[0].id' --raw-output)"
RESERVED_IP_ID=""
for cid in "${COMPARTMENTS[@]}"; do
  candidate="$(oci network public-ip list --scope REGION --compartment-id "$cid" --all 2>/dev/null \
    | jq -r '.data[] | select(.lifetime=="RESERVED" and (."display-name"|tostring|test("NituTravelsWAHA|nitu-wa";"i"))) | .id' | head -1)"
  if [[ "$candidate" == ocid1.publicip.* ]]; then RESERVED_IP_ID="$candidate"; break; fi
done
if [[ "$RESERVED_IP_ID" == ocid1.publicip.* ]]; then
  oci network public-ip update --public-ip-id "$RESERVED_IP_ID" --private-ip-id "$PRIVATE_IP_ID" --force >/dev/null
else
  RESERVED_IP_ID="$(oci network public-ip create --compartment-id "$COMPARTMENT_OCID" --lifetime RESERVED \
    --private-ip-id "$PRIVATE_IP_ID" --display-name "$PROJECT-IP" --freeform-tags "$TAGS" \
    --wait-for-state ASSIGNED --query 'data.id' --raw-output)"
fi
PUBLIC_IP="$(oci network public-ip get --public-ip-id "$RESERVED_IP_ID" --query 'data."ip-address"' --raw-output)"
[[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Public IP assignment failed"; exit 7; }
echo "Public IP: $PUBLIC_IP"

say "Wait once for SSH, then let cloud-init report its own completion"
SSH_READY=0
for _ in $(seq 1 18); do
  if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 ubuntu@"$PUBLIC_IP" 'true' 2>/dev/null; then SSH_READY=1; break; fi
  sleep 10
done
[[ $SSH_READY -eq 1 ]] || { echo "Instance is RUNNING but SSH did not become reachable within 3 minutes"; exit 8; }
ssh -tt -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"$PUBLIC_IP" \
  'sudo cloud-init status --wait --long; sudo test -f /opt/nitu-waha/INSTALL_OK; sudo curl -fsS http://127.0.0.1:3000/health; echo; sudo docker compose -f /opt/nitu-waha/docker-compose.yml --env-file /opt/nitu-waha/.env ps'

cat > "$HOME/nitu-waha-credentials.txt" <<EOF
Deployment ID: $DEPLOYMENT_ID
Oracle region: $REGION
Instance OCID: $INSTANCE_ID
Shape: $SHAPE, $SELECTED_OCPUS OCPU, $SELECTED_MEMORY GB
Public IP: $PUBLIC_IP
Dashboard by IP: http://$PUBLIC_IP:3000/dashboard
HTTPS dashboard after DNS points here: https://$DOMAIN/dashboard
Dashboard username: admin
Dashboard password: $DASHBOARD_PASSWORD
WAHA API key: $WAHA_API_KEY
Webhook HMAC secret: $WEBHOOK_SECRET
Session: $SESSION
SSH private key: $SSH_KEY
EOF
chmod 600 "$HOME/nitu-waha-credentials.txt"

say "INSTALLATION COMPLETE"
echo "Dashboard now: http://$PUBLIC_IP:3000/dashboard"
echo "Username: admin"
echo "Credentials saved in: $HOME/nitu-waha-credentials.txt"
echo "Set the DNS A record for $DOMAIN to $PUBLIC_IP if it is different."
echo "Then open the dashboard, enter the API key from the credentials file, and scan the QR for session $SESSION."
