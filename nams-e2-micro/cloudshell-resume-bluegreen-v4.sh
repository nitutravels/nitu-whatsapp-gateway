#!/usr/bin/env bash
set -Eeuo pipefail

REGION="${OCI_REGION:-ap-mumbai-1}"
CANDIDATE_NAME="${NAMS_CANDIDATE_NAME:-NAMS-Lightpanda-Agent-Candidate}"
SOURCE_NAME="${NAMS_SOURCE_NAME:-instance-20260723-2200}"
FINAL_NAME="NAMS-Lightpanda-Agent"
DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}"

say(){ printf '\n=== %s ===\n' "$*"; }
fail(){ echo "ERROR: $*" >&2; exit 1; }
trap 'rc=$?; echo; echo "Resume failed at line $LINENO (exit $rc). No new VM was launched and WAHA was never targeted." >&2; exit $rc' ERR

for cmd in oci jq curl; do command -v "$cmd" >/dev/null || fail "$cmd is unavailable in Cloud Shell."; done

echo "NAMS blue-green resume and verification"
echo "This command reuses the existing candidate. It never launches another VM."

find_running(){
  local name="$1"
  oci search resource structured-search --region "$REGION" \
    --query-text "query instance resources where displayName = '$name'" --output json 2>/dev/null |
    jq -r '[.data.items[]? | select((.["lifecycle-state"] // .lifecycleState // "") == "RUNNING")] | sort_by(.["time-created"] // .timeCreated // "") | last | .identifier // empty'
}

capture_console(){
  local instance_id="$1"
  local tail_lines="${2:-80}"
  local history_id state out
  history_id="$(oci compute console-history capture --region "$REGION" --instance-id "$instance_id" --query 'data.id' --raw-output 2>/dev/null || true)"
  [ -n "$history_id" ] || { echo "Console-history capture unavailable."; return 0; }
  for _ in $(seq 1 30); do
    state="$(oci compute console-history get --region "$REGION" --instance-console-history-id "$history_id" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)"
    [ "$state" = "SUCCEEDED" ] && break
    [ "$state" = "FAILED" ] && return 0
    sleep 2
  done
  [ "$state" = "SUCCEEDED" ] || return 0
  out="/tmp/nams-console-${history_id##*.}.txt"
  rm -f "$out"
  oci compute console-history get-content --region "$REGION" --instance-console-history-id "$history_id" --file "$out" >/dev/null 2>&1 || return 0
  echo "--- Recent candidate console output ---"
  tail -n "$tail_lines" "$out" || true
}

say "1/6 Resolving the existing candidate"
CANDIDATE_ID="$(find_running "$CANDIDATE_NAME")"
if [ -z "$CANDIDATE_ID" ]; then
  CANDIDATE_ID="$(find_running "$FINAL_NAME")"
fi
[ -n "$CANDIDATE_ID" ] || fail "No RUNNING NAMS candidate was found. Do not create another VM until the current candidate state is checked in OCI."
CANDIDATE_JSON="$(oci compute instance get --region "$REGION" --instance-id "$CANDIDATE_ID" --output json)"
DISPLAY_NAME="$(jq -r '.data["display-name"]' <<<"$CANDIDATE_JSON")"
[[ "$DISPLAY_NAME" != *WAHA* && "$DISPLAY_NAME" != *WhatsApp* && "$DISPLAY_NAME" != *whatsapp* ]] || fail "Safety stop: candidate resembles WAHA/WhatsApp."
TOKEN="$(jq -r '.data["freeform-tags"].NAMSBootstrapToken // empty' <<<"$CANDIDATE_JSON")"
DOMAIN="$(jq -r --arg fallback "$DOMAIN" '.data["freeform-tags"].NAMSDomain // $fallback' <<<"$CANDIDATE_JSON")"
[ -n "$TOKEN" ] || fail "Candidate token is missing from OCI tags."
VNIC_JSON="$(oci compute instance list-vnics --region "$REGION" --instance-id "$CANDIDATE_ID" --output json)"
PUBLIC_IP="$(jq -r '.data[0]["public-ip"] // empty' <<<"$VNIC_JSON")"
[ -n "$PUBLIC_IP" ] || fail "Candidate has no attached public IP."
echo "Candidate: $DISPLAY_NAME"
echo "Public IP: $PUBLIC_IP"

say "2/6 Waiting for cloud-init and checking every service"
probe(){ local path="$1"; shift; curl -fsS --connect-timeout 8 --max-time 60 -H "X-NAMS-Probe: $TOKEN" "$@" "http://$PUBLIC_IP$path"; }
READY=0
for i in $(seq 1 1080); do
  if probe /_probe/app/health >/tmp/nams-resume-app.json 2>/dev/null && \
     probe /_probe/chromium/json/version >/tmp/nams-resume-chromium.json 2>/dev/null && \
     probe /_probe/novnc/vnc.html >/tmp/nams-resume-novnc.html 2>/dev/null && \
     probe /_probe/lightpanda/json/version >/tmp/nams-resume-lightpanda.json 2>/dev/null && \
     probe /_probe/ollama/api/tags >/tmp/nams-resume-ollama.json 2>/dev/null; then
    READY=1
    break
  fi
  if [ $((i % 60)) -eq 0 ]; then
    echo "Verification wait: $((i/12)) minute(s)"
    capture_console "$CANDIDATE_ID" 30
  fi
  sleep 5
done
if [ "$READY" -ne 1 ]; then
  capture_console "$CANDIDATE_ID" 200
  fail "Existing candidate did not pass full verification within 90 minutes. It remains running for diagnosis; no replacement VM was created."
fi

grep -q '"ok"' /tmp/nams-resume-app.json
grep -q 'webSocketDebuggerUrl' /tmp/nams-resume-chromium.json
grep -qi 'noVNC' /tmp/nams-resume-novnc.html
jq -e '.models | length > 0' /tmp/nams-resume-ollama.json >/dev/null
curl -fsS --connect-timeout 8 --max-time 60 -H "Authorization: Bearer $TOKEN" "http://$PUBLIC_IP/" >/tmp/nams-resume-dashboard.html
grep -qi 'NAMS' /tmp/nams-resume-dashboard.html

say "3/6 Recording verified status"
VERIFIED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TAGS="$(jq -c '.data["freeform-tags"] // {}' <<<"$CANDIDATE_JSON")"
jq --arg at "$VERIFIED_AT" --arg ip "$PUBLIC_IP" '. + {NAMSStatus:"Verified",NAMSVerifiedAt:$at,NAMSPublicIP:$ip}' <<<"$TAGS" >/tmp/nams-resume-tags.json
oci compute instance update --region "$REGION" --instance-id "$CANDIDATE_ID" --display-name "$FINAL_NAME" --freeform-tags file:///tmp/nams-resume-tags.json --force >/dev/null

say "4/6 Removing the interrupted source only after verification"
SOURCE_ID="$(find_running "$SOURCE_NAME")"
if [ -n "$SOURCE_ID" ] && [ "$SOURCE_ID" != "$CANDIDATE_ID" ]; then
  SOURCE_JSON="$(oci compute instance get --region "$REGION" --instance-id "$SOURCE_ID" --output json)"
  SOURCE_DISPLAY="$(jq -r '.data["display-name"]' <<<"$SOURCE_JSON")"
  [[ "$SOURCE_DISPLAY" != *WAHA* && "$SOURCE_DISPLAY" != *WhatsApp* && "$SOURCE_DISPLAY" != *whatsapp* ]] || fail "Safety stop: source resembles WAHA/WhatsApp."
  oci compute instance terminate --region "$REGION" --instance-id "$SOURCE_ID" --preserve-boot-volume false --force >/dev/null
  echo "Interrupted source termination requested."
else
  echo "No separate running interrupted source remains."
fi

say "5/6 Checking DNS"
DNS_IP="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | head -1 || true)"

say "6/6 NAMS installation verified"
echo "Full NAMS stack: VERIFIED"
echo "Application: OK"
echo "Lightpanda: OK"
echo "Chromium CDP: OK"
echo "Live browser/noVNC: OK"
echo "Ollama local AI: OK"
echo "Public IP: $PUBLIC_IP"
echo "Login token: $TOKEN"
echo "Immediate login: http://$PUBLIC_IP/?token=$TOKEN"
if [ "$DNS_IP" = "$PUBLIC_IP" ]; then
  echo "Domain login: https://$DOMAIN/?token=$TOKEN"
  echo "DNS: already correct"
else
  echo "DNS CHANGE REQUIRED:"
  echo "  Type: A"
  echo "  Host: seo"
  echo "  Value: $PUBLIC_IP"
  echo "  Current resolved IP: ${DNS_IP:-none}"
fi
