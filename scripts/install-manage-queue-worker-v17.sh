#!/usr/bin/env bash
set -Eeuo pipefail

# Install/update the continuous Manage Nitu Travels WhatsApp queue worker on the
# existing Oracle WAHA VM.
#
# Usage on the Oracle VM:
#   sudo bash install-manage-queue-worker-v17.sh \
#     'https://manage.nitutravels.in/whatsapp-dispatch-worker.php?key=FULL_KEY'
#
# A separate key argument is also supported:
#   sudo bash install-manage-queue-worker-v17.sh \
#     'https://manage.nitutravels.in/whatsapp-dispatch-worker.php' 'WORKER_KEY'

INPUT_URL="${1:-}"
INPUT_KEY="${2:-}"
INTERVAL_SECONDS="${NITU_WORKER_INTERVAL_SECONDS:-10}"
BATCH_LIMIT="${NITU_WORKER_BATCH_LIMIT:-25}"
TIME_BUDGET="${NITU_WORKER_TIME_BUDGET:-45}"
WORKER_VERSION="v17.0"
ENV_FILE="/etc/nitu-whatsapp-worker.env"
BIN_FILE="/usr/local/bin/nitu-whatsapp-continuous-worker"
SERVICE_FILE="/etc/systemd/system/nitu-whatsapp-continuous-worker.service"
LOG_DIR="/var/log/nitu-travels"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || fail "Run with sudo or as root."
command -v curl >/dev/null 2>&1 || fail "curl is required."
command -v systemctl >/dev/null 2>&1 || fail "systemd is required."
[ -n "$INPUT_URL" ] || fail "Pass the website worker URL as argument 1."
case "$INPUT_URL" in http://*|https://*) ;; *) fail "Worker URL must start with https://" ;; esac

BASE_URL="${INPUT_URL%%\?*}"
if [ -z "$INPUT_KEY" ] && [[ "$INPUT_URL" == *"?"* ]]; then
  query="${INPUT_URL#*?}"
  oldIFS="$IFS"; IFS='&'
  for pair in $query; do case "$pair" in key=*) INPUT_KEY="${pair#key=}" ;; esac; done
  IFS="$oldIFS"
fi
[ -n "$INPUT_KEY" ] || fail "Pass the worker key or use the full URL containing ?key=."
[ "${#INPUT_KEY}" -ge 24 ] || fail "Worker key is unexpectedly short. Generate a fresh key in the website."
[[ "$INTERVAL_SECONDS" =~ ^[0-9]+$ ]] && [ "$INTERVAL_SECONDS" -ge 5 ] && [ "$INTERVAL_SECONDS" -le 300 ] || fail "Interval must be 5-300 seconds."
[[ "$BATCH_LIMIT" =~ ^[0-9]+$ ]] && [ "$BATCH_LIMIT" -ge 1 ] && [ "$BATCH_LIMIT" -le 50 ] || fail "Batch limit must be 1-50."
[[ "$TIME_BUDGET" =~ ^[0-9]+$ ]] && [ "$TIME_BUDGET" -ge 8 ] && [ "$TIME_BUDGET" -le 50 ] || fail "Time budget must be 8-50 seconds."

install -d -m 0750 "$LOG_DIR"
cat >"$ENV_FILE" <<ENV
NITU_WEBSITE_WORKER_URL=$BASE_URL
NITU_WORKER_KEY=$INPUT_KEY
NITU_WORKER_INTERVAL_SECONDS=$INTERVAL_SECONDS
NITU_WORKER_BATCH_LIMIT=$BATCH_LIMIT
NITU_WORKER_TIME_BUDGET=$TIME_BUDGET
NITU_WORKER_VERSION=$WORKER_VERSION
ENV
chmod 0600 "$ENV_FILE"

cat >"$BIN_FILE" <<'WORKER'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/nitu-whatsapp-worker.env
: "${NITU_WEBSITE_WORKER_URL:?missing worker URL}"
: "${NITU_WORKER_KEY:?missing worker key}"
: "${NITU_WORKER_INTERVAL_SECONDS:=10}"
: "${NITU_WORKER_BATCH_LIMIT:=25}"
: "${NITU_WORKER_TIME_BUDGET:=45}"
: "${NITU_WORKER_VERSION:=v17.0}"
LOG_DIR=/var/log/nitu-travels
mkdir -p "$LOG_DIR"
WORKER_ID="$(hostname -s 2>/dev/null || hostname)-continuous"
append_query() { if [[ "$1" == *"?"* ]]; then printf '%s&%s' "$1" "$2"; else printf '%s?%s' "$1" "$2"; fi; }
while true; do
  started="$(date -Is)"
  query="limit=${NITU_WORKER_BATCH_LIMIT}&budget=${NITU_WORKER_TIME_BUDGET}&source=oracle-systemd-continuous&worker_id=${WORKER_ID}&worker_version=${NITU_WORKER_VERSION}"
  endpoint="$(append_query "$NITU_WEBSITE_WORKER_URL" "$query")"
  tmp="$(mktemp "$LOG_DIR/whatsapp-worker-response.XXXXXX")"
  code=000; curl_rc=0
  code="$(curl --silent --show-error --location --max-redirs 2 --connect-timeout 8 \
    --max-time "$((NITU_WORKER_TIME_BUDGET + 10))" --output "$tmp" --write-out '%{http_code}' \
    --header 'Accept: application/json' --header "X-Nitu-Worker-Key: ${NITU_WORKER_KEY}" \
    --header "User-Agent: Nitu-Oracle-Continuous-Worker/${NITU_WORKER_VERSION}" \
    --request POST "$endpoint")" || curl_rc=$?
  mv -f "$tmp" "$LOG_DIR/whatsapp-worker-last-response.json"
  printf '%s http=%s curl_rc=%s endpoint=%s\n' "$started" "$code" "$curl_rc" "$NITU_WEBSITE_WORKER_URL" >"$LOG_DIR/whatsapp-worker-last-status.txt"
  if [ "$curl_rc" -ne 0 ] || [[ "$code" != 2* ]]; then
    printf '%s worker call failed: HTTP %s curl_rc=%s\n' "$started" "$code" "$curl_rc" >&2
    sed -n '1,20p' "$LOG_DIR/whatsapp-worker-last-response.json" >&2 || true
  else
    cat "$LOG_DIR/whatsapp-worker-last-response.json"; printf '\n'
  fi
  sleep "$NITU_WORKER_INTERVAL_SECONDS"
done
WORKER
chmod 0750 "$BIN_FILE"

cat >"$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=Nitu Travels continuous WhatsApp queue worker
Wants=network-online.target
After=network-online.target docker.service
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$BIN_FILE
Restart=always
RestartSec=5
TimeoutStopSec=20
User=root
Group=root
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$LOG_DIR

[Install]
WantedBy=multi-user.target
EOF_SERVICE

systemctl disable --now nitu-whatsapp-worker.timer 2>/dev/null || true
systemctl disable --now nitu-whatsapp-worker.service 2>/dev/null || true
rm -f /etc/systemd/system/nitu-whatsapp-worker.timer /etc/systemd/system/nitu-whatsapp-worker.service
systemctl daemon-reload
systemctl enable --now nitu-whatsapp-continuous-worker.service
sleep 3
systemctl --no-pager --full status nitu-whatsapp-continuous-worker.service || true
cat "$LOG_DIR/whatsapp-worker-last-response.json" 2>/dev/null || true
printf '\nInstalled. The website should report the Oracle worker ONLINE within 30 seconds.\n'