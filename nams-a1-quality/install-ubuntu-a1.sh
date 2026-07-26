#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR=/opt/nams-a1-quality
DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}"
TOKEN="${ADMIN_TOKEN:-}"
SUPPORT_REF="${NAMS_SUPPORT_REF:-main}"
SOURCE_REF="${NAMS_SOURCE_REF:-c74d8660d516e9330a9ad4f24742b10c43c487c4}"
MODEL="${OLLAMA_MODEL:-qwen2.5:7b-instruct}"
BASE_URL="https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/${SUPPORT_REF}/nams-a1-quality"
SOURCE_URL="https://raw.githubusercontent.com/nitutravels/fintimesnews-public-worker-v2/${SOURCE_REF}/nams-v5"
LOG=/var/log/nams-a1-install.log
STATUS=/var/lib/nams-a1-install.status

if [ "$(id -u)" -ne 0 ]; then exec sudo -E bash "$0" "$@"; fi
mkdir -p /var/lib
: >"$LOG"
exec > >(tee -a "$LOG" /dev/console) 2>&1
trap 'rc=$?; echo "FAILED:$rc" >"$STATUS"; echo "NAMS A1 installation failed at line $LINENO with exit code $rc"; cd "$APP_DIR" 2>/dev/null && docker compose ps && docker compose logs --tail=160 || true; exit $rc' ERR

echo RUNNING >"$STATUS"
echo "NAMS A1 quality installation started: $(date -Is)"
[ -n "$TOKEN" ] || TOKEN="$(openssl rand -hex 24)"

. /etc/os-release
if [ "${ID:-}" != "ubuntu" ] || [[ "${VERSION_ID:-}" != 24.04* ]]; then
  echo "This installer requires Ubuntu 24.04. Detected ID=${ID:-unknown} VERSION_ID=${VERSION_ID:-unknown}." >&2
  exit 11
fi
ARCH="$(dpkg --print-architecture)"
[ "$ARCH" = "arm64" ] || { echo "This installer requires ARM64. Detected $ARCH." >&2; exit 12; }
MEM_MB="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
[ "$MEM_MB" -ge 10000 ] || { echo "At least 10 GB RAM is required. Detected ${MEM_MB} MB." >&2; exit 13; }
DISK_FREE_GB="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
[ "$DISK_FREE_GB" -ge 25 ] || { echo "At least 25 GB free disk is required. Detected ${DISK_FREE_GB} GB." >&2; exit 14; }
echo "Detected ARM64, ${MEM_MB} MB RAM and ${DISK_FREE_GB} GB free disk."

for i in $(seq 1 120); do
  if curl -fsS --connect-timeout 5 https://raw.githubusercontent.com/ >/dev/null 2>&1 && getent hosts docker.com >/dev/null 2>&1; then break; fi
  [ "$i" -eq 120 ] && { echo "Public network did not become ready." >&2; exit 15; }
  sleep 5
done

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg jq openssl ufw python3 make g++

if ! swapon --show=NAME --noheadings | grep -q .; then
  echo "Creating 4 GB emergency swap..."
  fallocate -l 4G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap defaults 0 0' >>/etc/fstab
fi
cat >/etc/sysctl.d/90-nams-a1.conf <<'SYSCTL'
vm.swappiness=20
vm.vfs_cache_pressure=100
vm.dirty_background_ratio=5
vm.dirty_ratio=15
SYSCTL
sysctl --system >/dev/null

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" >/etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "4"},
  "live-restore": true
}
JSON
systemctl enable --now docker

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"/{app,chromium,config,assets,data/app,data/chromium}
fetch(){ curl -fL --retry 8 --retry-delay 3 --connect-timeout 20 "$1" -o "$2"; }
fetch "$BASE_URL/docker-compose.yml" "$APP_DIR/docker-compose.yml"
fetch "$BASE_URL/Caddyfile" "$APP_DIR/Caddyfile"
fetch "$BASE_URL/app/Dockerfile" "$APP_DIR/app/Dockerfile"
fetch "$BASE_URL/chromium/Dockerfile" "$APP_DIR/chromium/Dockerfile"
fetch "$BASE_URL/chromium/supervisord.conf" "$APP_DIR/chromium/supervisord.conf"
fetch "$SOURCE_URL/app/package.json" "$APP_DIR/app/package.json"
fetch "$SOURCE_URL/app/index.js" "$APP_DIR/app/index.js"
fetch "$SOURCE_URL/config/catalog.json" "$APP_DIR/config/catalog.json"

cat >"$APP_DIR/.env" <<ENV
TZ=Asia/Kolkata
NAMS_DOMAIN=$DOMAIN
ADMIN_TOKEN=$TOKEN
OLLAMA_BASE_URL=http://ollama:11434
OLLAMA_MODEL=$MODEL
LIGHTPANDA_CDP=http://chromium:9223
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
MAX_DAILY_DISCOVERY=6
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

cd "$APP_DIR"
docker compose config >/tmp/nams-a1-compose-rendered.yml

echo "Pulling public runtime images..."
docker compose pull caddy ollama model-loader

echo "Building NAMS application image..."
COMPOSE_PARALLEL_LIMIT=1 DOCKER_BUILDKIT=1 docker compose build app

echo "Building Chromium/noVNC image..."
COMPOSE_PARALLEL_LIMIT=1 DOCKER_BUILDKIT=1 docker compose build chromium

echo "Starting browser, AI server, application and proxy..."
docker compose up -d chromium ollama app caddy

probe(){ local url="$1"; shift; curl -fsS --connect-timeout 5 --max-time "${PROBE_TIMEOUT:-30}" -H "X-NAMS-Probe: $TOKEN" "$@" "$url"; }
CORE_READY=0
for i in $(seq 1 180); do
  if probe http://127.0.0.1/_probe/app/health >/tmp/nams-app-health.json 2>/dev/null && \
     probe http://127.0.0.1/_probe/chromium/json/version >/tmp/nams-chromium.json 2>/dev/null && \
     probe http://127.0.0.1/_probe/novnc/vnc.html >/tmp/nams-novnc.html 2>/dev/null && \
     probe http://127.0.0.1/_probe/ollama/api/tags >/tmp/nams-ollama.json 2>/dev/null; then
    CORE_READY=1
    break
  fi
  if [ $((i % 12)) -eq 0 ]; then
    echo "Core readiness wait: $((i/12)) minute(s)"
    docker compose ps || true
    free -h || true
  fi
  sleep 5
done
[ "$CORE_READY" -eq 1 ] || { echo "Core services did not become ready." >&2; exit 20; }
grep -q '"ok"' /tmp/nams-app-health.json
grep -q 'webSocketDebuggerUrl' /tmp/nams-chromium.json
grep -qi 'noVNC' /tmp/nams-novnc.html

echo "Downloading the high-quality local writing model: $MODEL"
docker compose run --rm model-loader

MODEL_READY=0
for i in $(seq 1 240); do
  if probe http://127.0.0.1/_probe/ollama/api/tags >/tmp/nams-ollama.json 2>/dev/null && jq -e --arg model "$MODEL" '.models[]? | select(.name==$model or .model==$model or (.name|startswith($model+":")))' /tmp/nams-ollama.json >/dev/null; then
    MODEL_READY=1
    break
  fi
  [ $((i % 12)) -eq 0 ] && echo "Model readiness wait: $((i/12)) minute(s)"
  sleep 5
done
[ "$MODEL_READY" -eq 1 ] || { echo "Writing model was not loaded." >&2; exit 21; }

PROBE_TIMEOUT=900 probe http://127.0.0.1/_probe/ollama/api/generate \
  -X POST -H 'Content-Type: application/json' \
  --data "{\"model\":\"$MODEL\",\"prompt\":\"Write one clear paragraph of practical Delhi group-transport advice and return strict JSON with key paragraph. Do not invent facts.\",\"stream\":false,\"format\":\"json\",\"keep_alive\":600}" \
  >/tmp/nams-model-test.json
jq -e '.response | length > 40' /tmp/nams-model-test.json >/dev/null

curl -fsS -H "Authorization: Bearer $TOKEN" http://127.0.0.1/ >/tmp/nams-dashboard.html
grep -qi 'NAMS' /tmp/nams-dashboard.html

cat >/usr/local/sbin/nams-a1-watchdog <<'WATCHDOG'
#!/usr/bin/env bash
set -u
cd /opt/nams-a1-quality || exit 1
TOKEN="$(awk -F= '$1=="ADMIN_TOKEN"{print substr($0,index($0,"=")+1);exit}' .env)"
probe(){ curl -fsS --connect-timeout 4 --max-time 15 -H "X-NAMS-Probe: $TOKEN" "$1" >/dev/null; }
if ! probe http://127.0.0.1/_probe/app/health; then docker compose restart app; fi
if ! probe http://127.0.0.1/_probe/chromium/json/version; then docker compose restart chromium; fi
if ! probe http://127.0.0.1/_probe/ollama/api/tags; then docker compose restart ollama; fi
docker image prune -f --filter 'until=168h' >/dev/null 2>&1 || true
WATCHDOG
chmod 750 /usr/local/sbin/nams-a1-watchdog

cat >/etc/systemd/system/nams-a1.service <<'UNIT'
[Unit]
Description=NAMS A1 Quality Authority Agent
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/nams-a1-quality
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose stop
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
UNIT

cat >/etc/systemd/system/nams-a1-watchdog.service <<'UNIT'
[Unit]
Description=NAMS A1 health watchdog
After=nams-a1.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nams-a1-watchdog
UNIT

cat >/etc/systemd/system/nams-a1-watchdog.timer <<'UNIT'
[Unit]
Description=Run NAMS A1 watchdog every five minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable nams-a1.service nams-a1-watchdog.timer
systemctl restart nams-a1-watchdog.timer

curl -fsS -X POST -H "Authorization: Bearer $TOKEN" http://127.0.0.1/run/discovery >/dev/null || true
printf '%s\n' "$TOKEN" >/var/lib/nams-a1-dashboard-token
printf '%s\n' "$MODEL" >/var/lib/nams-a1-active-model
chmod 600 /var/lib/nams-a1-dashboard-token /var/lib/nams-a1-active-model
echo SUCCESS >"$STATUS"

echo "NAMS_A1_READY"
echo "DOMAIN=$DOMAIN"
echo "MODEL=$MODEL"
echo "Completed: $(date -Is)"
