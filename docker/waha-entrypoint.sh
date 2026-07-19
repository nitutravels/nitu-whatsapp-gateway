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
export WAHA_WORKER_ID="nitu-travels"
export WAHA_PRINT_QR="False"
export WAHA_WORKER_RESTART_SESSIONS="True"
export WHATSAPP_RESTART_ALL_SESSIONS="True"
export WAHA_AUTO_START_DELAY_SECONDS="1"
export WAHA_HTTP_STRICT_MODE="1"
export WAHA_APPS_ENABLED="False"

# Reuse the already-persistent /data mount without touching retired gateway
# files. Local WAHA storage is documented for production and avoids requiring
# another database on the 1 GB Oracle instance.
export WAHA_LOCAL_STORE_BASE_DIR="/data/waha-sessions"
export WHATSAPP_FILES_FOLDER="/data/waha-media"
export WHATSAPP_FILES_LIFETIME="300"
export WHATSAPP_DOWNLOAD_MEDIA="false"
mkdir -p "$WAHA_LOCAL_STORE_BASE_DIR" "$WHATSAPP_FILES_FOLDER"

export WAHA_LOG_FORMAT="JSON"
export WAHA_LOG_LEVEL="${LOG_LEVEL:-info}"
export WAHA_HTTP_LOG_LEVEL="warn"
export TZ="Asia/Kolkata"
export NODE_OPTIONS="--max-old-space-size=512"

if [ -n "${PUBLIC_BASE_URL:-}" ]; then
  export WAHA_PUBLIC_URL="$PUBLIC_BASE_URL"
  export WAHA_BASE_URL="$PUBLIC_BASE_URL"
fi

# The official image provides this entrypoint. Passing the inherited CMD keeps
# the pinned WAHA release's own startup command intact.
exec /usr/local/bin/docker-entrypoint.sh "$@"
