#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ $EUID -eq 0 ]] || { echo 'root helper must be invoked through sudo' >&2; exit 77; }
SOURCE_FILE='/etc/nitu-voice-source-commit'
[[ -r "$SOURCE_FILE" ]] || { echo 'voice source pin missing' >&2; exit 2; }
SOURCE_COMMIT="$(tr -d '[:space:]' < "$SOURCE_FILE")"
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo 'invalid voice source pin' >&2; exit 2; }
RAW_BASE="https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/${SOURCE_COMMIT}/deploy/gitea-voice-v1"

case "${1:-install}" in
  install|repair)
    TMP="$(mktemp -d /var/tmp/nitu-voice-root-helper.XXXXXX)"
    trap 'rm -rf "$TMP"' EXIT
    curl -fL --retry 4 --retry-delay 2 "$RAW_BASE/install-host.sh" -o "$TMP/original-install-host.sh"
    curl -fL --retry 4 --retry-delay 2 "$RAW_BASE/agent.py" -o "$TMP/agent.py"
    python3 - "$TMP/original-install-host.sh" "$TMP/install-host.sh" <<'PY'
from pathlib import Path
import sys
src,dst=map(Path,sys.argv[1:])
s=src.read_text()
old='[[ "$(id -un)" == \'niturunner\' ]] || die "Gitea production job must run as niturunner, got $(id -un)"\nneed sudo;'
new='if (( EUID == 0 )); then\n  [[ "${NITU_GITEA_ROOT_HELPER:-}" == \'1\' ]] || die \'root execution allowed only through nitu-voice-install-root\'\nelse\n  [[ "$(id -un)" == \'niturunner\' ]] || die "Gitea production job must run as niturunner, got $(id -un)"\nfi\nneed sudo;'
assert old in s, 'runner identity guard not found'
s=s.replace(old,new,1)
old='sudo install -d -m 0755 -o niturunner -g niturunner "$SRC_ROOT" "$ROOT" "$STATE"'
assert old in s, 'source ownership line not found'
s=s.replace(old,'sudo install -d -m 0755 -o niturunner -g niturunner "$ROOT" "$STATE"',1)
old="crontab -l 2>/dev/null | sed '/# NITU_VOICE_V1_BEGIN/,/# NITU_VOICE_V1_END/d' > \"$TMP_CRON\" || true\ncrontab \"$TMP_CRON\" || true"
assert old in s, 'legacy cron cleanup not found'
new="sudo crontab -u niturunner -l 2>/dev/null | sed '/# NITU_VOICE_V1_BEGIN/,/# NITU_VOICE_V1_END/d' > \"$TMP_CRON\" || true\nsudo crontab -u niturunner \"$TMP_CRON\" || true"
s=s.replace(old,new,1)
dst.write_text(s)
PY
    chmod 0700 "$TMP/install-host.sh"
    chmod 0644 "$TMP/agent.py"
    bash -n "$TMP/install-host.sh"
    python3 -m py_compile "$TMP/agent.py"
    install -d -m 0755 -o root -g root /opt/nitu-control/deploy/voice-v1
    install -m 0644 -o root -g root "$TMP/agent.py" /opt/nitu-control/deploy/voice-v1/agent.py
    NITU_GITEA_ROOT_HELPER=1 bash "$TMP/install-host.sh"
    ;;
  verify)
    test -x /usr/local/sbin/nitu-voice-server-status
    /usr/local/sbin/nitu-voice-server-status --verify
    /usr/local/sbin/nitu-control health
    systemctl is-active --quiet gitea
    systemctl is-active --quiet gitea-runner
    python3 - <<'PY'
import json
p='/opt/nitu-control/voice-v1/state/installed.json'
d=json.load(open(p))
assert d.get('server_complete') is True, d
assert d.get('phone_pending') is True, d
assert d.get('mcp_version') == '0.2.8', d
assert d.get('runner') == 'wipro-production', d
print('NITU_VOICE_ROOT_HELPER_VERIFY_PASS')
PY
    ;;
  *)
    echo 'usage: nitu-voice-install-root {install|repair|verify}' >&2
    exit 64
    ;;
esac
