#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

for name in WAHA_API_KEY_B64 WAHA_DASHBOARD_PASSWORD_B64 WAHA_WEBHOOK_SECRET_B64 WAHA_WORKER_KEY_B64; do
  [ -n "${!name:-}" ] || fail "$name is required"
done

b64decode() { printf '%s' "$1" | base64 --decode | tr -d '\r\n'; }
WAHA_API_KEY="$(b64decode "$WAHA_API_KEY_B64")"
WAHA_DASHBOARD_PASSWORD="$(b64decode "$WAHA_DASHBOARD_PASSWORD_B64")"
WAHA_WEBHOOK_SECRET="$(b64decode "$WAHA_WEBHOOK_SECRET_B64")"
WAHA_WORKER_KEY="$(b64decode "$WAHA_WORKER_KEY_B64")"

[ "${#WAHA_API_KEY}" -ge 32 ] || fail 'WAHA API key is shorter than 32 characters'
[ "${#WAHA_DASHBOARD_PASSWORD}" -ge 16 ] || fail 'Dashboard password is shorter than 16 characters'
[ "${#WAHA_WEBHOOK_SECRET}" -ge 32 ] || fail 'Webhook secret is shorter than 32 characters'
[ "${#WAHA_WORKER_KEY}" -ge 32 ] || fail 'Worker key is shorter than 32 characters'

WAHA_DOMAIN="${WAHA_DOMAIN:-wa.nitutravels.in}"
WAHA_SESSION="${WAHA_SESSION:-nitu-travels}"
WEBSITE_WORKER_URL="${WEBSITE_WORKER_URL:-https://manage.nitutravels.in/whatsapp-dispatch-worker.php}"
WEBSITE_WEBHOOK_URL="${WEBSITE_WEBHOOK_URL:-https://manage.nitutravels.in/whatsapp-waha-webhook.php}"
ROOT=/opt/nitu-waha
OLD_ROOT=/opt/nitu-wa
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OLD_BACKUP=""
NEW_STARTED=0
INSTALL_OK=0

case "$(uname -m)" in
  aarch64|arm64) WAHA_IMAGE='devlikeapro/waha:noweb-arm-2026.7.1' ;;
  x86_64|amd64) WAHA_IMAGE='devlikeapro/waha:noweb-2026.6.2' ;;
  *) fail "Unsupported architecture: $(uname -m)" ;;
esac
POSTGRES_PASSWORD="$(printf '%s' "$WAHA_WEBHOOK_SECRET" | sha256sum | awk '{print $1}')"
POSTGRES_USER='waha'
POSTGRES_DB='waha'

rollback() {
  code=$?
  if [ "$INSTALL_OK" -eq 1 ]; then return; fi
  log "WAHA installation failed; attempting rollback to retired gateway"
  if [ "$NEW_STARTED" -eq 1 ] && [ -f "$ROOT/docker-compose.yml" ]; then
    (cd "$ROOT" && docker compose --env-file .env down --remove-orphans) || true
  fi
  if [ -n "$OLD_BACKUP" ] && [ -d "$OLD_BACKUP" ]; then
    rm -rf "$OLD_ROOT" || true
    mv "$OLD_BACKUP" "$OLD_ROOT" || true
    if [ -f "$OLD_ROOT/docker-compose.yml" ] && [ -f "$OLD_ROOT/.env" ]; then
      (cd "$OLD_ROOT" && docker compose --env-file .env up -d --remove-orphans) || true
    fi
  fi
  exit "$code"
}
trap rollback ERR

log "Installing WAHA NOWEB on $(uname -m) using $WAHA_IMAGE"
if ! command -v docker >/dev/null 2>&1; then
  log 'Installing Docker Engine on fresh Oracle instance'
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl gnupg jq
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
fi
command -v jq >/dev/null 2>&1 || { apt-get update && apt-get install -y jq; }
docker compose version >/dev/null || fail 'Docker Compose plugin is not installed'

for unit in nitu-wa-config-sync.timer nitu-wa-update.timer nitu-wa-backup.timer; do
  systemctl disable --now "$unit" >/dev/null 2>&1 || true
  systemctl mask "$unit" >/dev/null 2>&1 || true
done
for unit in nitu-wa-config-sync.service nitu-wa-update.service nitu-wa-backup.service; do
  systemctl stop "$unit" >/dev/null 2>&1 || true
done

if [ -d "$OLD_ROOT" ] && [ ! -e "$OLD_ROOT/.retired-by-waha" ]; then
  log 'Stopping and preserving the custom gateway for rollback'
  if [ -f "$OLD_ROOT/docker-compose.yml" ] && [ -f "$OLD_ROOT/.env" ]; then
    (cd "$OLD_ROOT" && docker compose --env-file .env down --remove-orphans) || true
  fi
  OLD_BACKUP="${OLD_ROOT}-retired-${TS}"
  mv "$OLD_ROOT" "$OLD_BACKUP"
  touch "$OLD_BACKUP/.retired-by-waha"
fi

install -d -m 0700 "$ROOT" "$ROOT/backups"
docker volume create nitu-wa_caddy_data >/dev/null
docker volume create nitu-wa_caddy_config >/dev/null

cat > "$ROOT/.env" <<EOF
WAHA_IMAGE=$WAHA_IMAGE
WAHA_DOMAIN=$WAHA_DOMAIN
WAHA_SESSION=$WAHA_SESSION
WAHA_API_KEY=$WAHA_API_KEY
WAHA_DASHBOARD_USERNAME=nitutravels
WAHA_DASHBOARD_PASSWORD=$WAHA_DASHBOARD_PASSWORD
WAHA_WEBHOOK_SECRET=$WAHA_WEBHOOK_SECRET
WAHA_WORKER_KEY=$WAHA_WORKER_KEY
WEBSITE_WORKER_URL=$WEBSITE_WORKER_URL
WEBSITE_WEBHOOK_URL=$WEBSITE_WEBHOOK_URL
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=$POSTGRES_DB
EOF
chmod 0600 "$ROOT/.env"

cat > "$ROOT/Caddyfile" <<'CADDY'
http://{$WAHA_DOMAIN} {
  reverse_proxy waha:3000
}

{$WAHA_DOMAIN} {
  encode zstd gzip
  reverse_proxy waha:3000
  header {
    Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
    X-Content-Type-Options "nosniff"
    X-Frame-Options "DENY"
    Referrer-Policy "no-referrer"
    Permissions-Policy "camera=(), microphone=(), geolocation=()"
    -Server
  }
  log {
    output stdout
    format json
  }
}
CADDY
chmod 0644 "$ROOT/Caddyfile"

cat > "$ROOT/docker-compose.yml" <<'COMPOSE'
services:
  postgres:
    image: postgres:17-alpine
    container_name: nitu-waha-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    command:
      - postgres
      - -c
      - shared_buffers=64MB
      - -c
      - max_connections=40
      - -c
      - work_mem=2MB
      - -c
      - maintenance_work_mem=32MB
    volumes:
      - waha_postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 12
    networks: [waha_net]
    security_opt: [no-new-privileges:true]

  waha:
    image: ${WAHA_IMAGE}
    container_name: nitu-waha
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "127.0.0.1:3000:3000"
    environment:
      WHATSAPP_DEFAULT_ENGINE: NOWEB
      WHATSAPP_SESSIONS_POSTGRESQL_URL: postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}?sslmode=disable
      WAHA_NAMESPACE: all
      WAHA_API_KEY: ${WAHA_API_KEY}
      WHATSAPP_API_KEY_EXCLUDE_PATH: health,ping
      WAHA_DASHBOARD_ENABLED: "true"
      WAHA_DASHBOARD_USERNAME: ${WAHA_DASHBOARD_USERNAME}
      WAHA_DASHBOARD_PASSWORD: ${WAHA_DASHBOARD_PASSWORD}
      WHATSAPP_SWAGGER_ENABLED: "false"
      WAHA_BASE_URL: https://${WAHA_DOMAIN}
      WAHA_PUBLIC_URL: https://${WAHA_DOMAIN}
      WAHA_LOG_FORMAT: JSON
      WAHA_LOG_LEVEL: info
      WAHA_HTTP_LOG_LEVEL: warn
      WAHA_PRINT_QR: "false"
      WAHA_PRESENCE_AUTO_ONLINE: "false"
      WAHA_SESSION_CONFIG_IGNORE_STATUS: "true"
      WAHA_SESSION_CONFIG_IGNORE_GROUPS: "true"
      WAHA_SESSION_CONFIG_IGNORE_CHANNELS: "true"
      WAHA_SESSION_CONFIG_IGNORE_BROADCAST: "true"
      WHATSAPP_DOWNLOAD_MEDIA: "false"
      WHATSAPP_HOOK_URL: ${WEBSITE_WEBHOOK_URL}
      WHATSAPP_HOOK_EVENTS: message.ack,session.status
      WHATSAPP_HOOK_HMAC_KEY: ${WAHA_WEBHOOK_SECRET}
      WHATSAPP_HOOK_RETRIES_POLICY: exponential
      WHATSAPP_HOOK_RETRIES_DELAY_SECONDS: "2"
      WHATSAPP_HOOK_RETRIES_ATTEMPTS: "8"
      WHATSAPP_HOOK_CUSTOM_HEADERS: X-WAHA-Worker-Key:${WAHA_WORKER_KEY}
      TZ: Asia/Kolkata
      NODE_OPTIONS: --max-old-space-size=384
    volumes:
      - waha_sessions_backup:/app/.sessions
    networks: [waha_net]
    security_opt: [no-new-privileges:true]
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:3000/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
      interval: 30s
      timeout: 8s
      start_period: 90s
      retries: 5

  dispatcher:
    image: curlimages/curl:8.12.1
    container_name: nitu-waha-dispatcher
    restart: unless-stopped
    environment:
      WEBSITE_WORKER_URL: ${WEBSITE_WORKER_URL}
      WAHA_WORKER_KEY: ${WAHA_WORKER_KEY}
    command:
      - /bin/sh
      - -ec
      - |
        while true; do
          curl --fail --silent --show-error --connect-timeout 5 --max-time 25 \
            -H "X-Worker-Key: $${WAHA_WORKER_KEY}" \
            -H "X-Api-Key: $${WAHA_WORKER_KEY}" \
            -X POST "$${WEBSITE_WORKER_URL}" >/dev/null || true
          sleep 60
        done
    networks: [waha_net]
    security_opt: [no-new-privileges:true]

  caddy:
    image: caddy:2.11.1-alpine
    container_name: nitu-waha-caddy
    restart: unless-stopped
    depends_on: [waha]
    environment:
      WAHA_DOMAIN: ${WAHA_DOMAIN}
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks: [waha_net]
    security_opt: [no-new-privileges:true]

networks:
  waha_net:
    driver: bridge

volumes:
  waha_postgres:
    name: nitu-waha_postgres
  waha_sessions_backup:
    name: nitu-waha_sessions_backup
  caddy_data:
    external: true
    name: nitu-wa_caddy_data
  caddy_config:
    external: true
    name: nitu-wa_caddy_config
COMPOSE
chmod 0644 "$ROOT/docker-compose.yml"

cat > /usr/local/sbin/nitu-waha-backup <<'BACKUP'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
root=/opt/nitu-waha
[ -f "$root/.env" ] || exit 0
set -a; . "$root/.env"; set +a
install -d -m 0700 "$root/backups"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
docker exec nitu-waha-postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc > "$root/backups/waha-$ts.dump"
find "$root/backups" -type f -mtime +14 -delete
BACKUP
chmod 0755 /usr/local/sbin/nitu-waha-backup
cat > /etc/systemd/system/nitu-waha-backup.service <<'UNIT'
[Unit]
Description=Back up Nitu Travels WAHA PostgreSQL state
After=docker.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nitu-waha-backup
UNIT
cat > /etc/systemd/system/nitu-waha-backup.timer <<'TIMER'
[Unit]
Description=Daily Nitu Travels WAHA backup
[Timer]
OnCalendar=*-*-* 02:45:00 UTC
RandomizedDelaySec=300
Persistent=true
[Install]
WantedBy=timers.target
TIMER
systemctl daemon-reload
systemctl enable --now nitu-waha-backup.timer >/dev/null

log 'Pulling WAHA, PostgreSQL and Caddy images'
cd "$ROOT"
docker compose --env-file .env pull
log 'Starting WAHA stack'
docker compose --env-file .env up -d --remove-orphans
NEW_STARTED=1

health=0
for attempt in $(seq 1 90); do
  if curl -fsS --connect-timeout 3 --max-time 10 http://127.0.0.1:3000/health >/tmp/waha-health.json 2>/dev/null; then
    health=1
    break
  fi
  sleep 10
done
[ "$health" -eq 1 ] || fail 'WAHA did not become healthy within 15 minutes'

version_json="$(curl -fsS --connect-timeout 5 --max-time 20 -H "X-Api-Key: $WAHA_API_KEY" http://127.0.0.1:3000/api/server/version)"
engine="$(printf '%s' "$version_json" | jq -r '.engine // empty')"
[ "$engine" = 'NOWEB' ] || fail "WAHA engine is '$engine', expected NOWEB"

session_payload="$(jq -nc --arg name "$WAHA_SESSION" '{name:$name,start:true,config:{noweb:{markOnline:false,store:{enabled:false,fullSync:false}}}}')"
session_code="$(curl -sS --connect-timeout 5 --max-time 30 -o /tmp/waha-session.json -w '%{http_code}' \
  -H "X-Api-Key: $WAHA_API_KEY" -H 'Content-Type: application/json' \
  -X POST http://127.0.0.1:3000/api/sessions -d "$session_payload" || true)"
if [ "$session_code" != 200 ] && [ "$session_code" != 201 ] && [ "$session_code" != 409 ]; then
  fail "Could not create WAHA session (HTTP $session_code): $(head -c 300 /tmp/waha-session.json)"
fi
curl -fsS --connect-timeout 5 --max-time 30 -H "X-Api-Key: $WAHA_API_KEY" \
  -X POST "http://127.0.0.1:3000/api/sessions/$WAHA_SESSION/start" >/tmp/waha-start.json 2>/dev/null || true

session_status='UNKNOWN'
for attempt in $(seq 1 60); do
  if curl -fsS --connect-timeout 5 --max-time 15 -H "X-Api-Key: $WAHA_API_KEY" \
      "http://127.0.0.1:3000/api/sessions/$WAHA_SESSION" >/tmp/waha-status.json 2>/dev/null; then
    session_status="$(jq -r '.status // "UNKNOWN"' /tmp/waha-status.json)"
    case "$session_status" in
      WORKING|SCAN_QR|STARTING|STOPPED) break ;;
    esac
  fi
  sleep 5
done

jq -n \
  --arg installedAt "$(date -u +%FT%TZ)" \
  --arg image "$WAHA_IMAGE" \
  --arg engine "$engine" \
  --arg session "$WAHA_SESSION" \
  --arg status "$session_status" \
  --arg retired "${OLD_BACKUP:-none}" \
  '{installedAt:$installedAt,image:$image,engine:$engine,session:$session,sessionStatus:$status,retiredGateway:$retired}' \
  > "$ROOT/install-result.json"
chmod 0600 "$ROOT/install-result.json"

INSTALL_OK=1
trap - ERR
log "WAHA installation completed: engine=$engine session=$WAHA_SESSION status=$session_status"
log "Dashboard: https://$WAHA_DOMAIN/dashboard"
