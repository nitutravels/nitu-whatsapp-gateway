#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR=/opt/nams-e2-micro
DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}"
TOKEN="${ADMIN_TOKEN:-}"
RELEASE_REF="${NAMS_E2_RELEASE_REF:-main}"
SOURCE_REF="${NAMS_SOURCE_REF:-c74d8660d516e9330a9ad4f24742b10c43c487c4}"
PRIMARY_MODEL="${OLLAMA_MODEL:-qwen2.5:0.5b-instruct}"
FALLBACK_MODEL="smollm2:135m-instruct-q8_0"
BASE_URL="https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/${RELEASE_REF}/nams-e2-micro"
SOURCE_URL="https://raw.githubusercontent.com/nitutravels/fintimesnews-public-worker-v2/${SOURCE_REF}/nams-v5"
LOG=/var/log/nams-e2-install.log
STATUS=/var/lib/nams-e2-install.status

if [ "$(id -u)" -ne 0 ]; then exec sudo -E bash "$0" "$@"; fi
mkdir -p /var/lib
: >"$LOG"
exec > >(tee -a "$LOG" /dev/console) 2>&1
trap 'rc=$?; echo "FAILED:$rc" >"$STATUS"; echo "NAMS E2 installation failed at line $LINENO with exit code $rc"; cd "$APP_DIR" 2>/dev/null && docker compose ps && docker compose logs --tail=120 || true; exit $rc' ERR

echo RUNNING >"$STATUS"
echo "NAMS E2 micro installation started: $(date -Is)"
[ -n "$TOKEN" ] || TOKEN="$(openssl rand -hex 24)"

. /etc/os-release
if [ "${ID:-}" != "ol" ] || [[ "${VERSION_ID:-}" != 9* ]]; then
  echo "This installer requires Oracle Linux 9. Detected ID=${ID:-unknown} VERSION_ID=${VERSION_ID:-unknown}." >&2
  exit 11
fi

for i in $(seq 1 120); do
  if curl -fsS --connect-timeout 5 https://raw.githubusercontent.com/ >/dev/null 2>&1 && getent hosts docker.com >/dev/null 2>&1; then break; fi
  [ "$i" -eq 120 ] && { echo "Public network did not become ready." >&2; exit 12; }
  sleep 5
done

MEM_MB="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
DISK_FREE_GB="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
echo "Detected memory: ${MEM_MB} MB; root free space: ${DISK_FREE_GB} GB"
[ "$DISK_FREE_GB" -ge 16 ] || { echo "At least 16 GB free disk is required." >&2; exit 13; }

if ! swapon --show=NAME --noheadings | grep -q .; then
  SWAP_GB=8
  [ "$DISK_FREE_GB" -lt 24 ] && SWAP_GB=6
  echo "Creating ${SWAP_GB} GB swap for the 1 GB E2 micro runtime..."
  fallocate -l "${SWAP_GB}G" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_GB*1024)) status=progress
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap defaults 0 0' >>/etc/fstab
fi
cat >/etc/sysctl.d/90-nams-e2.conf <<'SYSCTL'
vm.swappiness=80
vm.vfs_cache_pressure=150
vm.dirty_background_ratio=3
vm.dirty_ratio=10
SYSCTL
sysctl --system >/dev/null
free -h

dnf -y install dnf-plugins-core ca-certificates curl jq openssl firewalld tar gzip
systemctl enable --now firewalld
firewall-cmd --permanent --add-service=ssh >/dev/null
firewall-cmd --permanent --add-service=http >/dev/null
firewall-cmd --permanent --add-service=https >/dev/null
firewall-cmd --reload >/dev/null

dnf remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine podman runc >/dev/null 2>&1 || true
dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo >/dev/null
dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": {"max-size": "8m", "max-file": "3"},
  "live-restore": true
}
JSON
systemctl enable --now docker
docker version
docker compose version

mkdir -p "$APP_DIR"/{app,chromium,config,assets,data/lightpanda,data/chromium}
chmod 755 "$APP_DIR"

fetch(){ curl -fL --retry 6 --retry-delay 3 --connect-timeout 20 "$1" -o "$2"; }
fetch "$BASE_URL/docker-compose.yml" "$APP_DIR/docker-compose.yml"
fetch "$BASE_URL/Caddyfile" "$APP_DIR/Caddyfile"
fetch "$BASE_URL/app/Dockerfile.e2" "$APP_DIR/app/Dockerfile"
fetch "$BASE_URL/chromium/Dockerfile" "$APP_DIR/chromium/Dockerfile"
fetch "$BASE_URL/chromium/supervisord.conf" "$APP_DIR/chromium/supervisord.conf"
fetch "$SOURCE_URL/app/package.json" "$APP_DIR/app/package.json"
fetch "$SOURCE_URL/app/index.js" "$APP_DIR/app/index.js"
fetch "$SOURCE_URL/config/catalog.json" "$APP_DIR/config/catalog.json"

write_env(){
  local model="$1"
  cat >"$APP_DIR/.env" <<ENV
TZ=Asia/Kolkata
NAMS_DOMAIN=$DOMAIN
ADMIN_TOKEN=$TOKEN
OLLAMA_BASE_URL=http://ollama:11434
OLLAMA_MODEL=$model
LIGHTPANDA_CDP=http://lightpanda:9222
CHROMIUM_CDP=http://chromium:9223
BUSINESS_NAME=Nitu Travels
CONTACT_NAME=Ashu Grover
BUSINESS_WEBSITE=https://www.nitutravels.in/
TARGET_PAGE=https://www.nitutravels.in/bus-rental-delhi.html
BUSINESS_EMAIL=nitutravels@gmail.com
BUSINESS_PHONE=+91 98188 37830
BUSINESS_WHATSAPP=+91 89010 66699
BUSINESS_ADDRESS=216, A/5 Gautam Nagar, New Delhi, Delhi 110049
SERVICE_FOCUS=bus on hire in Delhi NCR
MAX_DAILY_DISCOVERY=4
MAX_DAILY_SUBMISSIONS=1
CRON_DISCOVERY=0 9 * * *
CRON_SUBMIT=0 12 * * *
CRON_RECHECK=0 18 * * *
AUTO_SEND_EMAIL=false
SMTP_HOST=smtp.gmail.com
SMTP_PORT=465
SMTP_USER=
SMTP_APP_PASSWORD=
ENV
  chmod 600 "$APP_DIR/.env"
}
write_env "$PRIMARY_MODEL"

cd "$APP_DIR"
docker compose config >/tmp/nams-e2-compose-rendered.yml

echo "Pulling public base services..."
docker compose pull caddy lightpanda ollama model-loader

echo "Building NAMS application image sequentially..."
COMPOSE_PARALLEL_LIMIT=1 DOCKER_BUILDKIT=1 docker compose build app

echo "Building low-memory Chromium/noVNC image sequentially..."
COMPOSE_PARALLEL_LIMIT=1 DOCKER_BUILDKIT=1 docker compose build chromium

echo "Starting core services..."
docker compose up -d lightpanda chromium ollama app caddy

probe(){ curl -fsS --connect-timeout 5 --max-time 20 -H "X-NAMS-Probe: $TOKEN" "$1"; }
READY=0
for i in $(seq 1 180); do
  if probe http://127.0.0.1/_probe/app/health >/tmp/nams-app-health.json 2>/dev/null && \
     probe http://127.0.0.1/_probe/chromium/json/version >/tmp/nams-chromium.json 2>/dev/null && \
     probe http://127.0.0.1/_probe/novnc/vnc.html >/tmp/nams-novnc.html 2>/dev/null && \
     probe http://127.0.0.1/_probe/lightpanda/json/version >/tmp/nams-lightpanda.json 2>/dev/null && \
     probe http://127.0.0.1/_probe/ollama/api/tags >/tmp/nams-ollama.json 2>/dev/null; then
    READY=1
    break
  fi
  if [ $((i % 12)) -eq 0 ]; then
    echo "Core readiness wait: $((i/12)) minute(s)"
    docker compose ps || true
    free -h || true
  fi
  sleep 5
done
[ "$READY" -eq 1 ] || { echo "Core services did not become ready." >&2; exit 20; }
grep -q '"ok"' /tmp/nams-app-health.json
grep -q 'webSocketDebuggerUrl' /tmp/nams-chromium.json
grep -qi 'noVNC' /tmp/nams-novnc.html

load_and_test_model(){
  local model="$1"
  echo "Loading local model $model..."
  OLLAMA_MODEL="$model" docker compose run --rm -e OLLAMA_MODEL="$model" model-loader
  for i in $(seq 1 180); do
    if probe http://127.0.0.1/_probe/ollama/api/tags >/tmp/nams-ollama.json 2>/dev/null && jq -e --arg model "$model" '.models[]? | select(.name==$model or .model==$model or (.name|startswith($model+":")))' /tmp/nams-ollama.json >/dev/null; then
      break
    fi
    [ $((i % 12)) -eq 0 ] && echo "Model readiness wait: $((i/12)) minute(s)"
    sleep 5
  done
  jq -e --arg model "$model" '.models[]? | select(.name==$model or .model==$model or (.name|startswith($model+":")))' /tmp/nams-ollama.json >/dev/null
  probe http://127.0.0.1/_probe/ollama/api/generate \
    -X POST -H 'Content-Type: application/json' \
    --data "{\"model\":\"$model\",\"prompt\":\"Return strict JSON only: {\\\"status\\\":\\\"ok\\\"}\",\"stream\":false,\"format\":\"json\",\"keep_alive\":0}" \
    >/tmp/nams-model-test.json
  jq -e '.response | length > 0' /tmp/nams-model-test.json >/dev/null
}

ACTIVE_MODEL="$PRIMARY_MODEL"
if ! load_and_test_model "$PRIMARY_MODEL"; then
  echo "Primary model could not complete within the E2 memory envelope; activating verified compact fallback."
  ACTIVE_MODEL="$FALLBACK_MODEL"
  write_env "$ACTIVE_MODEL"
  docker compose up -d --force-recreate app
  load_and_test_model "$ACTIVE_MODEL"
fi

curl -fsS -H "Authorization: Bearer $TOKEN" http://127.0.0.1/ >/tmp/nams-dashboard.html
grep -qi 'NAMS' /tmp/nams-dashboard.html

cat >/usr/local/sbin/nams-e2-watchdog <<'WATCHDOG'
#!/usr/bin/env bash
set -u
cd /opt/nams-e2-micro || exit 1
TOKEN="$(awk -F= '$1=="ADMIN_TOKEN"{print substr($0,index($0,"=")+1);exit}' .env)"
probe(){ curl -fsS --connect-timeout 4 --max-time 12 -H "X-NAMS-Probe: $TOKEN" "$1" >/dev/null; }
if ! probe http://127.0.0.1/_probe/app/health; then docker compose restart app; fi
if ! probe http://127.0.0.1/_probe/lightpanda/json/version; then docker compose restart lightpanda; fi
if ! probe http://127.0.0.1/_probe/chromium/json/version; then docker compose restart chromium; fi
if ! probe http://127.0.0.1/_probe/ollama/api/tags; then docker compose restart ollama; fi
docker image prune -f --filter 'until=168h' >/dev/null 2>&1 || true
WATCHDOG
chmod 750 /usr/local/sbin/nams-e2-watchdog

cat >/etc/systemd/system/nams-e2.service <<'UNIT'
[Unit]
Description=NAMS E2 Micro Authority Agent
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/nams-e2-micro
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose stop
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
UNIT

cat >/etc/systemd/system/nams-e2-watchdog.service <<'UNIT'
[Unit]
Description=NAMS E2 health watchdog
After=nams-e2.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nams-e2-watchdog
UNIT

cat >/etc/systemd/system/nams-e2-watchdog.timer <<'UNIT'
[Unit]
Description=Run NAMS E2 watchdog every five minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable nams-e2.service nams-e2-watchdog.timer
systemctl restart nams-e2-watchdog.timer

curl -fsS -X POST -H "Authorization: Bearer $TOKEN" http://127.0.0.1/run/discovery >/dev/null || true
printf '%s\n' "$TOKEN" >/var/lib/nams-e2-dashboard-token
printf '%s\n' "$ACTIVE_MODEL" >/var/lib/nams-e2-active-model
chmod 600 /var/lib/nams-e2-dashboard-token /var/lib/nams-e2-active-model
echo SUCCESS >"$STATUS"

echo "NAMS_E2_READY"
echo "DOMAIN=$DOMAIN"
echo "MODEL=$ACTIVE_MODEL"
echo "PUBLIC_HTTP=http://$(curl -fsS http://169.254.169.254/opc/v2/vnics/ -H 'Authorization: Bearer Oracle' | jq -r '.[0].publicIp // empty')/"
echo "Completed: $(date -Is)"
