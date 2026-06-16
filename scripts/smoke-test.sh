#!/usr/bin/env bash
set -euo pipefail

NS="${NAMESPACE:-confidential-inferencing}"
ROUTE_NAME="${ROUTE_NAME:-inference-confidential}"

if [[ -n "${1:-}" ]]; then
  BASE="$1"
else
  HOST="$(oc get route "$ROUTE_NAME" -n "$NS" -o jsonpath='{.spec.host}')"
  BASE="https://${HOST}"
fi

echo "==> $BASE /healthz"
curl -fsS "${BASE}/healthz" | jq .

echo "==> $BASE /demo/info"
curl -fsS "${BASE}/demo/info" | jq .

echo "==> $BASE /v1/generate"
curl -fsS -X POST "${BASE}/v1/generate" \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"confidential","max_new_tokens":40}' | jq .

echo "OK"
