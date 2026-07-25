#!/usr/bin/env bash
set -Eeuo pipefail

REGION="${OCI_REGION:-ap-mumbai-1}"
CANDIDATE_NAME="${NAMS_CANDIDATE_NAME:-NAMS-Lightpanda-Agent-Candidate}"
SOURCE_NAME="${NAMS_SOURCE_NAME:-instance-20260723-2200}"
FINAL_NAME="NAMS-Lightpanda-Agent"
DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}"
STATUS_FILE="${NAMS_STATUS_FILE:-status/nams-candidate-finalizer.json}"
mkdir -p "$(dirname "$STATUS_FILE")"

find_running(){
  local name="$1"
  oci search resource structured-search --region "$REGION" \
    --query-text "query instance resources where displayName = '$name'" --output json 2>/dev/null |
    jq -r '[.data.items[]? | select((.["lifecycle-state"] // .lifecycleState // "") == "RUNNING")] | sort_by(.["time-created"] // .timeCreated // "") | last | .identifier // empty'
}

write_status(){
  local state="$1" message="$2" ip="${3:-}" domain_ip="${4:-}"
  jq -n --arg state "$state" --arg message "$message" --arg ip "$ip" --arg domain "$DOMAIN" --arg domainIp "$domain_ip" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{state:$state,message:$message,public_ip:$ip,domain:$domain,domain_ip:$domainIp,checked_at:$at}' >"$STATUS_FILE"
}

CANDIDATE_ID="$(find_running "$CANDIDATE_NAME")"
[ -n "$CANDIDATE_ID" ] || CANDIDATE_ID="$(find_running "$FINAL_NAME")"
if [ -z "$CANDIDATE_ID" ]; then
  write_status pending "No running NAMS candidate is visible yet."
  echo "NAMS candidate is not visible yet; no OCI changes made."
  exit 0
fi

CANDIDATE_JSON="$(oci compute instance get --region "$REGION" --instance-id "$CANDIDATE_ID" --output json)"
DISPLAY_NAME="$(jq -r '.data["display-name"]' <<<"$CANDIDATE_JSON")"
[[ "$DISPLAY_NAME" != *WAHA* && "$DISPLAY_NAME" != *WhatsApp* && "$DISPLAY_NAME" != *whatsapp* ]] || { write_status blocked "Safety stop: resolved instance resembles WAHA/WhatsApp."; exit 1; }
TOKEN="$(jq -r '.data["freeform-tags"].NAMSBootstrapToken // empty' <<<"$CANDIDATE_JSON")"
DOMAIN="$(jq -r --arg fallback "$DOMAIN" '.data["freeform-tags"].NAMSDomain // $fallback' <<<"$CANDIDATE_JSON")"
VNIC_JSON="$(oci compute instance list-vnics --region "$REGION" --instance-id "$CANDIDATE_ID" --output json)"
PUBLIC_IP="$(jq -r '.data[0]["public-ip"] // empty' <<<"$VNIC_JSON")"
if [ -z "$TOKEN" ] || [ -z "$PUBLIC_IP" ]; then
  write_status pending "Candidate exists but token or public IP is not available yet." "$PUBLIC_IP"
  echo "Candidate exists but is not ready for verification."
  exit 0
fi

probe(){ local path="$1"; shift; curl -fsS --connect-timeout 8 --max-time 45 -H "X-NAMS-Probe: $TOKEN" "$@" "http://$PUBLIC_IP$path"; }
if ! probe /_probe/app/health >/tmp/nams-final-app.json 2>/dev/null || \
   ! probe /_probe/chromium/json/version >/tmp/nams-final-chromium.json 2>/dev/null || \
   ! probe /_probe/novnc/vnc.html >/tmp/nams-final-novnc.html 2>/dev/null || \
   ! probe /_probe/lightpanda/json/version >/tmp/nams-final-lightpanda.json 2>/dev/null || \
   ! probe /_probe/ollama/api/tags >/tmp/nams-final-ollama.json 2>/dev/null; then
  write_status installing "Cloud-init installation is still running or one service is not ready." "$PUBLIC_IP"
  echo "NAMS candidate is still installing; no retry, rebuild, termination, or WAHA change performed."
  exit 0
fi

grep -q '"ok"' /tmp/nams-final-app.json
grep -q 'webSocketDebuggerUrl' /tmp/nams-final-chromium.json
grep -qi 'noVNC' /tmp/nams-final-novnc.html
jq -e '.models | length > 0' /tmp/nams-final-ollama.json >/dev/null
curl -fsS --connect-timeout 8 --max-time 45 -H "Authorization: Bearer $TOKEN" "http://$PUBLIC_IP/" >/tmp/nams-final-dashboard.html
grep -qi 'NAMS' /tmp/nams-final-dashboard.html

VERIFIED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TAGS="$(jq -c '.data["freeform-tags"] // {}' <<<"$CANDIDATE_JSON")"
jq --arg at "$VERIFIED_AT" --arg ip "$PUBLIC_IP" '. + {NAMSStatus:"Verified",NAMSVerifiedAt:$at,NAMSPublicIP:$ip}' <<<"$TAGS" >/tmp/nams-final-tags.json
oci compute instance update --region "$REGION" --instance-id "$CANDIDATE_ID" --display-name "$FINAL_NAME" --freeform-tags file:///tmp/nams-final-tags.json --force >/dev/null

SOURCE_ID="$(find_running "$SOURCE_NAME")"
if [ -n "$SOURCE_ID" ] && [ "$SOURCE_ID" != "$CANDIDATE_ID" ]; then
  SOURCE_JSON="$(oci compute instance get --region "$REGION" --instance-id "$SOURCE_ID" --output json)"
  SOURCE_DISPLAY="$(jq -r '.data["display-name"]' <<<"$SOURCE_JSON")"
  [[ "$SOURCE_DISPLAY" != *WAHA* && "$SOURCE_DISPLAY" != *WhatsApp* && "$SOURCE_DISPLAY" != *whatsapp* ]] || { write_status blocked "Safety stop: source resembles WAHA/WhatsApp." "$PUBLIC_IP"; exit 1; }
  oci compute instance terminate --region "$REGION" --instance-id "$SOURCE_ID" --preserve-boot-volume false --force >/dev/null
fi

DNS_IP="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | head -1 || true)"
write_status success "Full NAMS stack verified and candidate finalized." "$PUBLIC_IP" "$DNS_IP"
echo "NAMS FINALIZED"
echo "Public IP: $PUBLIC_IP"
echo "Token retrieval: oci compute instance get --region $REGION --instance-id $CANDIDATE_ID --query 'data.\"freeform-tags\".NAMSBootstrapToken' --raw-output"
if [ "$DNS_IP" = "$PUBLIC_IP" ]; then
  echo "Domain: https://$DOMAIN"
else
  echo "DNS change required: A record seo -> $PUBLIC_IP (currently ${DNS_IP:-none})"
fi
