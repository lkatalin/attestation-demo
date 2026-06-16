#!/usr/bin/env bash
# Live demo script: compare confidential vs plaintext vs failing baseline.
set -euo pipefail

# shellcheck source=defaults.sh
source "$(dirname "$0")/defaults.sh"

NS=confidential-inferencing
PROMPT="${PROMPT:-confidential}"
MAXTOK="${MAXTOK:-40}"

CONF_HOST="$(oc get route inference-confidential -n "$NS" -o jsonpath='{.spec.host}')"
PLAIN_HOST="$(oc get route inference-plaintext -n "$NS" -o jsonpath='{.spec.host}')"
CONF_URL="https://${CONF_HOST}"
PLAIN_URL="https://${PLAIN_HOST}"
CURL=(curl -fsS --connect-timeout 5 --max-time 20)

section() { echo ""; echo "======== $* ========"; }

section "1) Image contents (encrypted weights shipped; DEK not in image)"
bash "$(dirname "$0")/inspect-image.sh" || true

section "2) Pod status — three arms, same image"
oc get pods -n "$NS" -l 'demo-role in (confidential,plaintext-control,baseline-encrypted-fail)' \
  -o custom-columns=NAME:.metadata.name,ROLE:.metadata.labels.demo-role,RUNTIME:.spec.runtimeClassName,STATUS:.status.phase,READY:.status.containerStatuses[0].ready

section "3) Baseline encrypted (ordinary pod) — expected failure"
echo "Pod status:"
oc get pod -n "$NS" -l demo-role=baseline-encrypted-fail \
  -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount 2>/dev/null || true
echo "Logs (previous container if restarted, else last 10 lines — never blocks on CDH wait):"
if logs="$(timeout 8 oc logs -n "$NS" deploy/inference-baseline-encrypted --previous --tail=20 2>/dev/null)" && [[ -n "$logs" ]]; then
  echo "$logs"
else
  timeout 8 oc logs -n "$NS" deploy/inference-baseline-encrypted --tail=10 2>&1 || true
  echo "(If only 'Waiting for CDH REST API': worker pod in ~2min wait, then Sample/PolicyDeny — expected)"
fi
echo "(Expect kbs-client / attestation errors — same image cannot unlock without CVM)"

section "4) /demo/info — confidential vs plaintext"
echo "--- confidential ---"
"${CURL[@]}" "${CONF_URL}/demo/info" | jq .
echo "--- plaintext control ---"
"${CURL[@]}" "${PLAIN_URL}/demo/info" | jq .

section "5) Same prompt to both working endpoints"
BODY=$(jq -nc --arg p "$PROMPT" --argjson m "$MAXTOK" '{prompt:$p,max_new_tokens:$m}')
echo "--- confidential ${CONF_URL} ---"
"${CURL[@]}" -X POST "${CONF_URL}/v1/generate" -H 'Content-Type: application/json' -d "$BODY" | jq .
echo "--- plaintext ${PLAIN_URL} ---"
"${CURL[@]}" -X POST "${PLAIN_URL}/v1/generate" -H 'Content-Type: application/json' -d "$BODY" | jq .

section "Done"
cat <<EOF

Talking points:
  • Image ships model.pt.enc; DEK only in KBS.
  • Confidential pod: kata-remote → attest → decrypt → infer (see demo_runtime).
  • Plaintext pod: same image, DEMO_MODE=plaintext — skips KBS (control only).
  • Baseline encrypted pod: same image, confidential mode, no CVM — fails to start.

EOF
