#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SOURCE_COMMIT='46864a33d72b21257d243b6978fdc788498b9e6b'
RAW_BASE="https://raw.githubusercontent.com/nitutravels/nitu-whatsapp-gateway/${SOURCE_COMMIT}/deploy/gitea-voice-v1"
GITEA='http://127.0.0.1:3001'
OWNER='nituadmin'
REPO='nitu-control'
WORKFLOW='nitu-voice-v1-server.yml'
DEST=".gitea/workflows/${WORKFLOW}"
TARGET='/opt/nitu-control/deploy/voice-v1'
TMP="$(mktemp -d /tmp/nitu-gitea-voice-bootstrap.XXXXXX)"
TOKEN=''
TOKEN_NAME="chatgpt-voice-v1-$(date +%s)-$$"
cleanup(){
  set +e
  if [[ -n "$TOKEN" ]]; then
    curl -sS --max-time 5 -X DELETE -H "Authorization: token $TOKEN" "$GITEA/api/v1/token" >/dev/null 2>&1 || true
  fi
  TOKEN=''
  rm -rf "$TMP"
}
trap cleanup EXIT

log(){ printf '[gitea-voice-bootstrap] %s\n' "$*"; }
die(){ printf '[gitea-voice-bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(hostname)" == 'nitu-server' ]] || die "run this on Wipro nitu-server, got $(hostname)"
command -v sudo >/dev/null || die 'sudo missing'
command -v curl >/dev/null || die 'curl missing'
command -v python3 >/dev/null || die 'python3 missing'
command -v base64 >/dev/null || die 'base64 missing'
sudo -n true || die 'noninteractive sudo not available; Nitu Control bootstrap policy is incomplete'
sudo -n systemctl is-active --quiet gitea || die 'gitea is not active'
sudo -n systemctl is-active --quiet gitea-runner || die 'gitea-runner is not active'
curl -fsS --max-time 5 "$GITEA/" >/dev/null || die 'local Gitea HTTP unavailable'

log 'validate Nitu Control and Wipro MCP before deployment'
sudo -n /usr/local/sbin/nitu-control health || die 'Nitu Control health failed'
curl -fsS --max-time 5 http://127.0.0.1:8781/healthz | python3 -c 'import json,sys;d=json.load(sys.stdin);assert d.get("ok") is True;assert d.get("version")=="0.2.8";assert d.get("mode")=="read_write_guarded_rootless";assert d.get("protected_gps_ports")==[5023,15023,16023]'
sudo -n /usr/local/sbin/nitu-control backup-now || die 'Nitu Control backup failed'

log "download immutable deployment source commit $SOURCE_COMMIT"
for f in install-host.sh agent.py gitea-workflow.yml; do
  curl -fL --retry 4 --retry-delay 2 "$RAW_BASE/$f" -o "$TMP/$f"
  test -s "$TMP/$f"
done
bash -n "$TMP/install-host.sh"
python3 -m py_compile "$TMP/agent.py"
python3 - "$TMP/gitea-workflow.yml" <<'PY'
import sys
p=sys.argv[1]
s=open(p,encoding='utf-8').read()
for needle in ('workflow_dispatch:', 'runs-on: wipro-production', '/opt/nitu-control/deploy/voice-v1/install-host.sh', 'NITU_WIPRO_VOICE_AGENT_V1_INSTALLATION_COMPLETE'):
    assert needle in s, needle
print('GITEA_VOICE_WORKFLOW_STATIC_VALIDATION_PASS')
PY

log 'stage reviewed source under Nitu Control'
sudo install -d -m 0755 -o niturunner -g niturunner "$TARGET"
sudo install -m 0755 -o niturunner -g niturunner "$TMP/install-host.sh" "$TARGET/install-host.sh"
sudo install -m 0644 -o niturunner -g niturunner "$TMP/agent.py" "$TARGET/agent.py"

log 'create short-lived local Gitea token'
TOKEN="$(sudo -n -u git env USER=git HOME=/home/git GITEA_WORK_DIR=/var/lib/gitea GITEA_CUSTOM=/var/lib/gitea/custom \
  /usr/local/bin/gitea --work-path /var/lib/gitea --custom-path /var/lib/gitea/custom --config /etc/gitea/app.ini \
  admin user generate-access-token --username "$OWNER" --token-name "$TOKEN_NAME" --scopes all --raw | tail -n1 | tr -d '\r\n')"
[[ -n "$TOKEN" ]] || die 'Gitea token generation returned empty output'
curl -fsS -H "Authorization: token $TOKEN" "$GITEA/api/v1/user" >/dev/null || die 'generated Gitea token rejected'

log 'publish fixed workflow into local nitu-control'
META="$TMP/meta.json"
HTTP="$(curl -sS -o "$META" -w '%{http_code}' -H "Authorization: token $TOKEN" "$GITEA/api/v1/repos/$OWNER/$REPO/contents/$DEST?ref=main")"
CONTENT="$(base64 -w0 "$TMP/gitea-workflow.yml")"
BODY="$TMP/body.json"
if [[ "$HTTP" == 200 ]]; then
  SHA="$(python3 - "$META" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['sha'])
PY
)"
  python3 - "$CONTENT" "$SHA" > "$BODY" <<'PY'
import json,sys
print(json.dumps({'content':sys.argv[1],'sha':sys.argv[2],'branch':'main','message':'voice: install/repair Nitu voice server v1'}))
PY
  METHOD=PUT
elif [[ "$HTTP" == 404 ]]; then
  python3 - "$CONTENT" > "$BODY" <<'PY'
import json,sys
print(json.dumps({'content':sys.argv[1],'branch':'main','message':'voice: install/repair Nitu voice server v1'}))
PY
  METHOD=POST
else
  cat "$META" >&2 || true
  die "Gitea workflow lookup returned HTTP $HTTP"
fi
CODE="$(curl -sS -o "$TMP/write.json" -w '%{http_code}' -X "$METHOD" -H "Authorization: token $TOKEN" -H 'Content-Type: application/json' --data-binary @"$BODY" "$GITEA/api/v1/repos/$OWNER/$REPO/contents/$DEST")"
case "$CODE" in 200|201) ;; *) cat "$TMP/write.json" >&2 || true; die "Gitea workflow write HTTP $CODE";; esac

for i in $(seq 1 30); do
  if curl -fsS -H "Authorization: token $TOKEN" "$GITEA/api/v1/repos/$OWNER/$REPO/actions/workflows/$WORKFLOW" > "$TMP/workflow.json" 2>/dev/null; then break; fi
  sleep 2
done
[[ -s "$TMP/workflow.json" ]] || die 'Gitea did not index the voice workflow'

log 'dispatch voice server install on wipro-production'
CODE="$(curl -sS -o "$TMP/dispatch.json" -w '%{http_code}' -X POST \
  -H "Authorization: token $TOKEN" -H 'Content-Type: application/json' \
  --data '{"ref":"refs/heads/main","inputs":{}}' \
  "$GITEA/api/v1/repos/$OWNER/$REPO/actions/workflows/$WORKFLOW/dispatches?return_run_details=true")"
[[ "$CODE" == 200 ]] || { cat "$TMP/dispatch.json" >&2 || true; die "Gitea dispatch HTTP $CODE"; }
RUN_ID="$(python3 - "$TMP/dispatch.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); print(d['workflow_run_id'])
PY
)"
[[ "$RUN_ID" =~ ^[0-9]+$ ]] || die "invalid Gitea run id: $RUN_ID"
echo "GITEA_VOICE_RUN_ID=$RUN_ID"

log 'wait for local Gitea install/repair loop to complete'
FINAL=''
for i in $(seq 1 720); do
  curl -fsS -H "Authorization: token $TOKEN" "$GITEA/api/v1/repos/$OWNER/$REPO/actions/runs/$RUN_ID" > "$TMP/run.json"
  read -r STATUS CONCLUSION <<<"$(python3 - "$TMP/run.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]));print(d.get('status') or '', d.get('conclusion') or '')
PY
)"
  if (( i == 1 || i % 6 == 0 )); then printf 'poll=%s status=%s conclusion=%s\n' "$i" "${STATUS:-unknown}" "${CONCLUSION:-none}"; fi
  case "${CONCLUSION:-}" in success) FINAL=success; break;; failure|cancelled|canceled|timed_out|skipped) FINAL="$CONCLUSION"; break;; esac
  case "${STATUS:-}" in success) FINAL=success; break;; failure|cancelled|canceled|timed_out|skipped) FINAL="$STATUS"; break;; esac
  sleep 10
done

curl -fsS -H "Authorization: token $TOKEN" "$GITEA/api/v1/repos/$OWNER/$REPO/actions/runs/$RUN_ID/jobs" > "$TMP/jobs.json" || true
python3 - "$TMP/jobs.json" <<'PY'
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: raise SystemExit()
for j in d.get('jobs',[]):
    print('JOB',j.get('id'),j.get('name'),'status='+str(j.get('status')),'conclusion='+str(j.get('conclusion')),'runner='+str(j.get('runner_name')))
    for s in j.get('steps') or []:
        print(' STEP',s.get('number'),s.get('name'),'status='+str(s.get('status')),'conclusion='+str(s.get('conclusion')))
PY

if [[ "$FINAL" != success ]]; then
  sudo -n journalctl -u gitea-runner --since '-3 hours' --no-pager | tail -n 500 || true
  sudo -n journalctl -u nitu-voice-agent.service -u nitu-voice-asterisk.service --since '-3 hours' --no-pager | tail -n 300 || true
  die "Gitea voice deployment did not succeed: ${FINAL:-timeout}"
fi

log 'independent Wipro server acceptance after Gitea job'
sudo -n /usr/local/sbin/nitu-voice-server-status --verify
sudo -n systemctl is-enabled --quiet nitu-voice-agent.service
sudo -n systemctl is-enabled --quiet nitu-voice-asterisk.service
sudo -n systemctl is-active --quiet nitu-voice-agent.service
sudo -n systemctl is-active --quiet nitu-voice-asterisk.service
sudo -n /usr/local/sbin/nitu-control health
python3 - <<'PY'
import json
p='/opt/nitu-control/voice-v1/state/installed.json'
d=json.load(open(p))
assert d.get('server_complete') is True, d
assert d.get('phone_pending') is True, d
assert d.get('mcp_version') == '0.2.8', d
assert d.get('gitea_repo') == 'nituadmin/nitu-control', d
assert d.get('runner') == 'wipro-production', d
print(json.dumps(d,indent=2))
print('NITU_VOICE_FINAL_STATE_PASS')
PY

echo NITU_WIPRO_VOICE_AGENT_V1_INSTALLATION_COMPLETE
echo NITU_WIPRO_VOICE_AGENT_V1_SERVER_COMPLETE_PHONE_PENDING
echo 'NEXT_ONLY: sudo /usr/local/sbin/nitu-voice-phone-config'
