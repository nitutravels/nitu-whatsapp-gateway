#!/bin/sh
set -eu

APP_PID=''
STOPPING=0

cleanup_transient_profile() {
  session_root="${DATA_DIR:-/data}/auth/session-primary"
  [ -d "$session_root" ] || return 0
  find "$session_root" -type f \( -name SingletonLock -o -name SingletonCookie -o -name SingletonSocket \) -delete 2>/dev/null || true
  find "$session_root" -type d \( -name Cache -o -name 'Code Cache' -o -name GPUCache -o -name DawnCache -o -name GrShaderCache -o -name ShaderCache \) -prune -exec rm -rf {} + 2>/dev/null || true
}

stop_child() {
  STOPPING=1
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
}

trap stop_child TERM INT HUP

cleanup_transient_profile
node src/server.js &
APP_PID=$!

# Give Chromium and WhatsApp Web enough time to restore the linked session.
sleep 180

stuck_count=0
unreachable_count=0
while kill -0 "$APP_PID" 2>/dev/null; do
  status="$(node - <<'NODE' 2>/dev/null || true
const token = process.env.ADMIN_TOKEN || '';
const controller = new AbortController();
const timer = setTimeout(() => controller.abort(), 12000);
fetch('http://127.0.0.1:3000/admin/api/status', {
  headers: { Authorization: `Bearer ${token}` },
  signal: controller.signal,
}).then(async response => {
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const body = await response.json();
  process.stdout.write(String(body.status || 'unknown'));
}).catch(() => process.exit(2)).finally(() => clearTimeout(timer));
NODE
)"

  case "$status" in
    ready|awaiting_pairing|auth_failure)
      stuck_count=0
      unreachable_count=0
      ;;
    loading|starting|authenticated|disconnected|error)
      stuck_count=$((stuck_count + 1))
      unreachable_count=0
      ;;
    *)
      unreachable_count=$((unreachable_count + 1))
      ;;
  esac

  # Ten consecutive 30-second unhealthy linked-session checks = five minutes.
  # Exit the container so Docker restarts the complete process tree cleanly.
  if [ "$stuck_count" -ge 10 ] || [ "$unreachable_count" -ge 6 ]; then
    echo "Gateway readiness watchdog restarting container: status=${status:-unreachable} stuck_count=$stuck_count unreachable_count=$unreachable_count" >&2
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
      kill -TERM "$APP_PID" 2>/dev/null || true
      wait "$APP_PID" 2>/dev/null || true
    fi
    cleanup_transient_profile
    exit 75
  fi

  sleep 30
done

wait "$APP_PID"
exit_code=$?
[ "$STOPPING" -eq 1 ] && exit 0
exit "$exit_code"
