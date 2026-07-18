#!/usr/bin/env bash
set -Eeuo pipefail
: "${BASE_URL:?BASE_URL required}"
: "${ADMIN_TOKEN:?ADMIN_TOKEN required}"

curl -fsS "$BASE_URL/healthz" | jq .
status_code="$(curl -sS -o /tmp/wa-status.json -w '%{http_code}' -H "Authorization: Bearer $ADMIN_TOKEN" "$BASE_URL/admin/api/status")"
[ "$status_code" = 200 ]
jq '{engine,engineVersion,status,phase,ready,registered,account,queue,worker,lastError}' /tmp/wa-status.json
ready_code="$(curl -sS -o /tmp/wa-ready.json -w '%{http_code}' "$BASE_URL/readyz")"
echo "READY_HTTP=$ready_code"
jq . /tmp/wa-ready.json
