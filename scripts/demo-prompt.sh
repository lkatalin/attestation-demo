#!/usr/bin/env bash
# Prompt confidential + plaintext routes; show baseline failure without hanging.
# Usage: bash scripts/demo-prompt.sh
#   PROMPT="confidential inferencing runs inside a" bash scripts/demo-prompt.sh
set -uo pipefail

# shellcheck source=defaults.sh
source "$(dirname "$0")/defaults.sh"

NS="${DEMO_NAMESPACE:-confidential-inferencing}"
PROMPT="${PROMPT:-encrypted model weights stay ciphertext until}"
MAXTOK="${MAXTOK:-35}"
CURL_MAX="${CURL_MAX:-20}"

CURL=(curl -fsS --connect-timeout 5 --max-time "$CURL_MAX")

CONF_URL="https://$(oc get route inference-confidential -n "$NS" -o jsonpath='{.spec.host}')"
PLAIN_URL="https://$(oc get route inference-plaintext -n "$NS" -o jsonpath='{.spec.host}')"
BODY="$(jq -nc --arg p "$PROMPT" --argjson m "$MAXTOK" '{prompt:$p,max_new_tokens:$m}')"

gen() {
  local label="$1" url="$2"
  local prefix=""
  case "${DEMO_ACT:-}" in
    ii) prefix="Act II — " ;;
    iii) prefix="Act III — " ;;
    i) prefix="Act I — " ;;
  esac
  echo "=== ${prefix}${label} ==="
  if "${CURL[@]}" -X POST "${url}/v1/generate" \
    -H 'Content-Type: application/json' -d "$BODY" | jq .; then
    return 0
  fi
  echo "(request failed or timed out after ${CURL_MAX}s)"
  return 1
}

baseline_snapshot() {
  local prefix=""
  case "${DEMO_ACT:-}" in
    ii) prefix="Act II — " ;;
    iii) prefix="Act III — " ;;
    i) prefix="Act I — " ;;
  esac
  echo "=== ${prefix}BASELINE ENCRYPTED (no route — worker pod cannot unlock DEK) ==="
  local base_pod
  base_pod="$(oc get pod -n "$NS" -l demo-role=baseline-encrypted-fail \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  oc get pod -n "$NS" -l demo-role=baseline-encrypted-fail \
    -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount 2>/dev/null \
    || true

  if [[ -n "$base_pod" ]]; then
    echo "Same prompt via port-forward (pod often Running but not Ready — no inference server):"
    ( timeout 10 oc port-forward -n "$NS" "pod/$base_pod" 18080:8080 >/dev/null 2>&1 & local pf=$!
      sleep 2
      curl -sS --max-time 3 -X POST "http://127.0.0.1:18080/v1/generate" \
        -H 'Content-Type: application/json' -d "$BODY" 2>&1 \
        || echo "(expected — connection refused or timeout; entrypoint still waiting or exited)"
      kill "$pf" 2>/dev/null; wait "$pf" 2>/dev/null; true )
  fi

  # Prefer previous container: full failure after CDH wait + kbs-client PolicyDeny.
  local logs
  logs="$(timeout 8 oc logs -n "$NS" deploy/inference-baseline-encrypted --previous --tail=25 2>/dev/null || true)"
  if [[ -n "$logs" ]]; then
    echo "$logs"
    return 0
  fi

  logs="$(timeout 8 oc logs -n "$NS" deploy/inference-baseline-encrypted --tail=12 2>/dev/null || true)"
  if [[ -n "$logs" ]]; then
    echo "$logs"
    echo ""
    echo "Note: if you only see 'Waiting for CDH REST API', the pod is Running but not"
    echo "inferring — no HTTP server yet. It will fail with Sample/PolicyDeny after the wait."
    return 0
  fi

  echo "(no baseline logs yet)"
}

echo "Prompt: $PROMPT"
echo "Confidential: $CONF_URL"
echo "Plaintext:    $PLAIN_URL"
echo ""

gen "CONFIDENTIAL" "$CONF_URL" || true
echo ""
gen "PLAINTEXT" "$PLAIN_URL" || true
echo ""
baseline_snapshot
