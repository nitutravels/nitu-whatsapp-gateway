#!/usr/bin/env bash
set -Eeuo pipefail

TOKEN="${ADMIN_TOKEN:?ADMIN_TOKEN required}"
DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}"
SOURCE_REF="${NAMS_SOURCE_REF:-c74d8660d516e9330a9ad4f24742b10c43c487c4}"
IMAGE_TAG="${NAMS_IMAGE_TAG:-c74d8660d516e9330a9ad4f24742b10c43c487c4-cdp1}"
APP_DIR=/opt/nams
LOG=/var/log/nams-inplace-repair.log

exec > >(tee -a "$LOG" /dev/console) 2>&1
trap 'rc=$?; echo "NAMS_REPAIR_FAILED rc=$rc line=$LINENO"; cd "$APP_DIR" 2>/dev/null && docker compose ps && docker compose logs --tail=160 || true; exit "$rc"' ERR

export DEBIAN_FRONTEND=noninteractive
if ! command -v docker >/dev/null 2>&1; then
  apt-get -o DPkg::Lock::Timeout=180 update
  apt-get -o DPkg::Lock::Timeout=180 install -y ca-certificates curl gnupg jq
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" >/etc/apt/sources.list.d/docker.list
  apt-get -o DPkg::Lock::Timeout=180 update
  apt-get -o DPkg::Lock::Timeout=180 install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

mkdir -p "$APP_DIR"/{data/lightpanda,data/chromium,assets,config}
BASE="https://raw.githubusercontent.com/nitutravels/fintimesnews-public-worker-v2/${SOURCE_REF}"
curl -fL --retry 6 "$BASE/nams-v6/docker-compose.yml" -o "$APP_DIR/docker-compose.yml"
curl -fL --retry 6 "$BASE/nams-v6/Caddyfile" -o "$APP_DIR/Caddyfile"
curl -fL --retry 6 "$BASE/nams-v5/config/catalog.json" -o "$APP_DIR/config/catalog.json"

cat >"$APP_DIR/.env" <<ENV
TZ=Asia/Kolkata
NAMS_DOMAIN=$DOMAIN
ADMIN_TOKEN=$TOKEN
NAMS_APP_IMAGE=ghcr.io/nitutravels/nams-v6-app:$IMAGE_TAG
NAMS_CHROMIUM_IMAGE=ghcr.io/nitutravels/nams-v6-chromium:$IMAGE_TAG
OLLAMA_BASE_URL=http://ollama:11434
OLLAMA_MODEL=gemma3:1b
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
MAX_DAILY_DISCOVERY=8
MAX_DAILY_SUBMISSIONS=2
AUTO_SEND_EMAIL=false
ENV
chmod 600 "$APP_DIR/.env"

# The original limits totalled almost all 8 GB before Docker, the kernel and the
# temporary model-loader were counted. Use bounded limits that leave host headroom.
python3 - <<'PY'
from pathlib import Path
p=Path('/opt/nams/docker-compose.yml')
s=p.read_text()
s=s.replace('mem_limit: 1g', 'mem_limit: 768m')
s=s.replace('mem_limit: 768m', 'mem_limit: 512m', 1)  # Lightpanda only; app remains 768m above
s=s.replace('mem_limit: 2300m', 'mem_limit: 1500m')
s=s.replace('mem_limit: 3500m', 'mem_limit: 2800m')
p.write_text(s)
PY

cd "$APP_DIR"
docker compose config >/var/lib/nams-compose-rendered.yml
docker compose down --remove-orphans || true
docker system prune -af || true
docker compose pull
# Start core services first to avoid model-loader memory pressure during browser startup.
docker compose up -d caddy app lightpanda chromium ollama

for i in $(seq 1 120); do
  if curl -fsS http://127.0.0.1/_probe/app/health -H "X-NAMS-Probe: $TOKEN" >/tmp/app.json 2>/dev/null && \
     curl -fsS http://127.0.0.1/_probe/chromium/json/version -H "X-NAMS-Probe: $TOKEN" >/tmp/chromium.json 2>/dev/null && \
     curl -fsS http://127.0.0.1/_probe/novnc/vnc.html -H "X-NAMS-Probe: $TOKEN" >/tmp/novnc.html 2>/dev/null && \
     curl -fsS http://127.0.0.1/_probe/lightpanda/json/version -H "X-NAMS-Probe: $TOKEN" >/tmp/lightpanda.json 2>/dev/null; then
    break
  fi
  [ $((i%12)) -eq 0 ] && { free -h; docker compose ps; docker compose logs --tail=30 app chromium lightpanda ollama caddy || true; }
  sleep 5
done
grep -q '"ok"' /tmp/app.json
grep -q webSocketDebuggerUrl /tmp/chromium.json
grep -qi noVNC /tmp/novnc.html

# Pull the small model only after the browsers and app are stable.
docker exec nams-v6-ollama-1 ollama pull gemma3:1b || docker compose run --rm model-loader
for i in $(seq 1 180); do
  if curl -fsS http://127.0.0.1/_probe/ollama/api/tags -H "X-NAMS-Probe: $TOKEN" >/tmp/ollama.json 2>/dev/null && jq -e '.models|length>0' /tmp/ollama.json >/dev/null; then break; fi
  sleep 5
done
jq -e '.models|length>0' /tmp/ollama.json >/dev/null
curl -fsS -H "Authorization: Bearer $TOKEN" http://127.0.0.1/ | grep -q NAMS

cat >/usr/local/sbin/nams-watchdog <<'WATCH'
#!/usr/bin/env bash
set -u
cd /opt/nams || exit 1
TOKEN="$(awk -F= '$1=="ADMIN_TOKEN"{print substr($0,index($0,"=")+1);exit}' .env)"
probe(){ curl -fsS --connect-timeout 4 --max-time 10 -H "X-NAMS-Probe: $TOKEN" "$1" >/dev/null; }
probe http://127.0.0.1/_probe/app/health && probe http://127.0.0.1/_probe/chromium/json/version && probe http://127.0.0.1/_probe/lightpanda/json/version && probe http://127.0.0.1/_probe/ollama/api/tags || docker compose up -d
WATCH
chmod 750 /usr/local/sbin/nams-watchdog
cat >/etc/systemd/system/nams-watchdog.service <<'UNIT'
[Unit]
Description=NAMS health watchdog
After=docker.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nams-watchdog
UNIT
cat >/etc/systemd/system/nams-watchdog.timer <<'UNIT'
[Unit]
Description=Run NAMS watchdog every five minutes
[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Persistent=true
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now nams-watchdog.timer
printf '%s\n' "$TOKEN" >/var/lib/nams-dashboard-token
chmod 600 /var/lib/nams-dashboard-token
echo SUCCESS >/var/lib/nams-install.status
echo NAMS_REPAIR_SUCCESS
