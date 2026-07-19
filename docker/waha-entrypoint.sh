#!/bin/sh
set -eu

: "${API_KEY:?Existing Oracle API_KEY is required}"
: "${ADMIN_TOKEN:?Existing Oracle ADMIN_TOKEN is required}"

# Compatibility mapping: the Oracle compose file already injects these two
# secrets. Keep them server-side and expose them only through WAHA's supported
# security variables.
export WAHA_API_KEY="$API_KEY"
export WAHA_DASHBOARD_ENABLED="true"
export WAHA_DASHBOARD_USERNAME="${WAHA_DASHBOARD_USERNAME:-admin}"
export WAHA_DASHBOARD_PASSWORD="$ADMIN_TOKEN"
export WHATSAPP_SWAGGER_ENABLED="false"
export WHATSAPP_API_KEY_EXCLUDE_PATH="ping,health"

# Browserless, single-session production settings.
export WHATSAPP_DEFAULT_ENGINE="NOWEB"
export WAHA_SESSION="${WAHA_SESSION:-nitu-travels}"
export WAHA_WORKER_ID="$WAHA_SESSION"
export WAHA_PRINT_QR="False"
export WAHA_WORKER_RESTART_SESSIONS="True"
export WHATSAPP_RESTART_ALL_SESSIONS="True"
export WAHA_AUTO_START_DELAY_SECONDS="1"
export WAHA_HTTP_STRICT_MODE="1"
export WAHA_APPS_ENABLED="False"

# Reuse the already-persistent /data mount without touching retired gateway
# files. WAHA uses dedicated subdirectories.
export WAHA_LOCAL_STORE_BASE_DIR="/data/waha-sessions"
export WHATSAPP_FILES_FOLDER="/data/waha-media"
export WHATSAPP_FILES_LIFETIME="300"
export WHATSAPP_DOWNLOAD_MEDIA="false"
mkdir -p "$WAHA_LOCAL_STORE_BASE_DIR" "$WHATSAPP_FILES_FOLDER"

# Map the website callback contract onto WAHA's signed webhook configuration.
if [ -n "${WEBHOOK_URL:-}" ]; then
  export WHATSAPP_HOOK_URL="$WEBHOOK_URL"
  export WHATSAPP_HOOK_EVENTS="message.ack,session.status"
  export WHATSAPP_HOOK_HMAC_KEY="${WEBHOOK_SECRET:-$API_KEY}"
  export WHATSAPP_HOOK_RETRIES_POLICY="exponential"
  export WHATSAPP_HOOK_RETRIES_DELAY_SECONDS="2"
  export WHATSAPP_HOOK_RETRIES_ATTEMPTS="8"
  export WHATSAPP_HOOK_CUSTOM_HEADERS="X-WAHA-Worker-Key:${API_KEY}"
fi

export WEBSITE_WORKER_URL="${WEBSITE_WORKER_URL:-https://manage.nitutravels.in/whatsapp-dispatch-worker.php}"
export WAHA_WORKER_KEY="${WAHA_WORKER_KEY:-$API_KEY}"

export WAHA_LOG_FORMAT="JSON"
export WAHA_LOG_LEVEL="${LOG_LEVEL:-info}"
export WAHA_HTTP_LOG_LEVEL="warn"
export TZ="Asia/Kolkata"
export NODE_OPTIONS="--max-old-space-size=512"

if [ -n "${PUBLIC_BASE_URL:-}" ]; then
  export WAHA_PUBLIC_URL="$PUBLIC_BASE_URL"
  export WAHA_BASE_URL="$PUBLIC_BASE_URL"
fi

# The supervisor waits for WAHA, creates/starts the session, and drains the
# website outbox once per minute. It never stores or prints private keys.
node /usr/local/lib/nitu-waha-supervisor.mjs &

# WAHA's official image entrypoint is /entrypoint.sh and starts node dist/main.
exec /entrypoint.sh "$@"
