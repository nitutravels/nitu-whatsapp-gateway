#!/usr/bin/env bash
set -Eeuo pipefail

REGION="${OCI_REGION:-ap-mumbai-1}"
TENANCY="${OCI_TENANCY_OCID:?required}"
COMPARTMENT="${OCI_COMPARTMENT_OCID:-}"
TARGET="${OCI_TARGET_INSTANCE:-NAMS-Lightpanda-Agent}"
RESERVED_HINT="${OCI_RESERVED_IP:-161.118.166.225}"
DOMAIN="${NAMS_DOMAIN:-seo.nitutravels.in}"
RESULT="${NAMS_RESULT_FILE:-nams-deployment-result.json}"
BASE_CONTROLLER="nams-deploy/deploy-capacity-aware.sh"
WORK="${RUNNER_TEMP:-/tmp}/nams-resume-${GITHUB_RUN_ID:-manual}"
mkdir -p "$WORK"

log(){ printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
valid_ocid(){ [[ "${1:-}" == ocid1.* ]]; }
state(){ oci compute instance get --region "$REGION" --instance-id "$1" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true; }
public_ip(){ oci compute instance list-vnics --region "$REGION" --instance-id "$1" --query 'data[0]."public-ip"' --raw-output 2>/dev/null || true; }
private_ip_id(){ local v; v="$(oci compute instance list-vnics --region "$REGION" --instance-id "$1" --query 'data[0].id' --raw-output)"; oci network private-ip list --region "$REGION" --vnic-id "$v" --all --query 'data[0].id' --raw-output; }
probe(){
  local ip="$1" token="$2"
  curl -fsS --connect-timeout 5 --max-time 20 -H "X-NAMS-Probe: $token" "http://$ip/_probe/app/health" >"$WORK/app.json" 2>/dev/null &&
  curl -fsS --connect-timeout 5 --max-time 20 -H "X-NAMS-Probe: $token" "http://$ip/_probe/chromium/json/version" >"$WORK/chromium.json" 2>/dev/null &&
  curl -fsS --connect-timeout 5 --max-time 20 -H "X-NAMS-Probe: $token" "http://$ip/_probe/novnc/vnc.html" >"$WORK/novnc.html" 2>/dev/null &&
  curl -fsS --connect-timeout 5 --max-time 20 -H "X-NAMS-Probe: $token" "http://$ip/_probe/lightpanda/json/version" >"$WORK/lightpanda.json" 2>/dev/null &&
  curl -fsS --connect-timeout 5 --max-time 20 -H "X-NAMS-Probe: $token" "http://$ip/_probe/ollama/api/tags" >"$WORK/ollama.json" 2>/dev/null &&
  curl -fsS --connect-timeout 5 --max-time 20 -H "Authorization: Bearer $token" "http://$ip/" >"$WORK/dashboard.html" 2>/dev/null &&
  grep -q '"ok"' "$WORK/app.json" && grep -q webSocketDebuggerUrl "$WORK/chromium.json" && grep -qi noVNC "$WORK/novnc.html" && grep -q NAMS "$WORK/dashboard.html" && jq -e '.models|length>0' "$WORK/ollama.json" >/dev/null
}
recover_token(){
  local id="$1" token ud nested
  token="$(oci compute instance get --region "$REGION" --instance-id "$id" --query 'data."freeform-tags".NAMSBootstrapToken' --raw-output 2>/dev/null || true)"
  if [ -n "$token" ] && [ "$token" != null ] && [ "$token" != None ]; then printf '%s' "$token"; return 0; fi
  ud="$(oci compute instance get --region "$REGION" --instance-id "$id" --query 'data.metadata.user_data' --raw-output 2>/dev/null || true)"
  [ -n "$ud" ] && [ "$ud" != null ] && [ "$ud" != None ] || return 1
  printf '%s' "$ud" | base64 -d >"$WORK/cloud-init.yaml" 2>/dev/null || return 1
  nested="$(awk '/^[[:space:]]+content:[[:space:]]/{print $2; exit}' "$WORK/cloud-init.yaml")"
  [ -n "$nested" ] || return 1
  printf '%s' "$nested" | base64 -d >"$WORK/bootstrap.sh" 2>/dev/null || return 1
  sed -n "s/.*ADMIN_TOKEN='\([^']*\)'.*/\1/p" "$WORK/bootstrap.sh" | head -n1
}

if ! valid_ocid "$COMPARTMENT"; then
  COMPARTMENT="$(oci iam compartment list --region "$REGION" --compartment-id "$TENANCY" --compartment-id-in-subtree true --access-level ACCESSIBLE --all --output json | jq -r '[.data[]|select(.name=="NituWAGateway" and .["lifecycle-state"]=="ACTIVE")|.id][0]//empty')"
fi
valid_ocid "$COMPARTMENT"
INVENTORY="$(oci compute instance list --region "$REGION" --compartment-id "$COMPARTMENT" --display-name "$TARGET" --all --output json)"
COUNT="$(jq '[.data[]|select(.["lifecycle-state"]!="TERMINATED")]|length' <<<"$INVENTORY")"
if [ "$COUNT" -gt 1 ]; then
  jq -n --argjson count "$COUNT" '{status:"failed",phase:"inventory",message:("Multiple active NAMS instances: "+($count|tostring))}' >"$RESULT"
  exit 31
fi

if [ "$COUNT" -eq 1 ]; then
  ID="$(jq -r '[.data[]|select(.["lifecycle-state"]!="TERMINATED")][0].id' <<<"$INVENTORY")"
  S="$(state "$ID")"
  log "Found existing NAMS candidate in state $S"
  for _ in $(seq 1 180); do S="$(state "$ID")"; [ "$S" = RUNNING ] && break; [ "$S" = TERMINATED ] && break; sleep 10; done
  if [ "$S" = RUNNING ]; then
    IP=''
    for _ in $(seq 1 60); do IP="$(public_ip "$ID")"; [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break; sleep 5; done
    TOKEN="$(recover_token "$ID" || true)"
    if [ -n "$TOKEN" ] && [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      for i in $(seq 1 180); do
        if probe "$IP" "$TOKEN"; then
          PRIVATE="$(private_ip_id "$ID")"
          RESERVED_JSON="$(oci network public-ip list --region "$REGION" --compartment-id "$COMPARTMENT" --scope REGION --lifetime RESERVED --all --output json | jq -c --arg ip "$RESERVED_HINT" '[.data[]|select(.["ip-address"]==$ip or .["display-name"]=="NAMS-v5-Reserved-IP" or .["display-name"]=="NAMS-Reserved-IP")][0]//empty')"
          RID="$(jq -r '.id' <<<"$RESERVED_JSON")"; RIP="$(jq -r '.["ip-address"]' <<<"$RESERVED_JSON")"
          valid_ocid "$RID"; valid_ocid "$PRIVATE"
          CURRENT="$(oci network public-ip get --region "$REGION" --private-ip-id "$PRIVATE" --query 'data.id' --raw-output 2>/dev/null || true)"
          if valid_ocid "$CURRENT" && [ "$CURRENT" != "$RID" ]; then oci network public-ip delete --region "$REGION" --public-ip-id "$CURRENT" --force >/dev/null; sleep 10; fi
          oci network public-ip update --region "$REGION" --public-ip-id "$RID" --private-ip-id "$PRIVATE" --force >/dev/null
          for _ in $(seq 1 60); do A="$(oci network public-ip get --region "$REGION" --public-ip-id "$RID" --query 'data."assigned-entity-id"' --raw-output 2>/dev/null || true)"; [ "$A" = "$PRIVATE" ] && break; sleep 5; done
          [ "$A" = "$PRIVATE" ]
          probe "$RIP" "$TOKEN"
          oci compute instance update --region "$REGION" --instance-id "$ID" --freeform-tags "{\"NAMSBootstrapToken\":\"$TOKEN\",\"ManagedBy\":\"GitHubActions\"}" --force >/dev/null
          jq -n --arg id "$ID" --arg ip "$RIP" --arg domain "$DOMAIN" '{status:"success",phase:"complete",instance_id:$id,public_ip:$ip,domain:$domain,message:"Existing NAMS candidate resumed, fully certified, and reserved IP attached",shape:"VM.Standard.A1.Flex",ocpus:1,memory_gb:8}' >"$RESULT"
          cat >nams-token-retrieval.txt <<EOF
oci compute instance get --region '$REGION' --instance-id '$ID' --query 'data."freeform-tags".NAMSBootstrapToken' --raw-output
EOF
          exit 0
        fi
        [ $((i % 12)) -eq 0 ] && log "Existing candidate verification: $((i/6)) minute(s)"
        sleep 10
      done
    fi
  fi
  log 'Existing NAMS candidate did not certify; preserving boot volume and replacing only this compute instance'
  oci compute instance terminate --region "$REGION" --instance-id "$ID" --preserve-boot-volume true --force >/dev/null
  for _ in $(seq 1 270); do [ "$(state "$ID")" = TERMINATED ] && break; sleep 10; done
  [ "$(state "$ID")" = TERMINATED ]
fi

exec bash "$BASE_CONTROLLER"
