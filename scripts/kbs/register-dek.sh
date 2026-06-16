#!/usr/bin/env bash
# Register the model DEK as a KBS resource (Trustee operator secret propagation).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../defaults.sh
source "$SCRIPT_DIR/../defaults.sh"

DEK_FILE="${DEK_FILE:-$ARTIFACTS/dek.bin}"
NS="${TRUSTEE_NS}"

[[ -f "$DEK_FILE" ]] || {
  echo "Missing $DEK_FILE — run: make prepare  (or set DEK_FILE=)" >&2
  exit 1
}

oc whoami >/dev/null || { echo "oc login required (KBS / Trustee cluster)" >&2; exit 1; }

echo "==> Cluster: $(oc whoami --show-server 2>/dev/null || true)"
echo "==> DEK secret $DEK_SECRET_NAME in $NS"

oc create secret generic "$DEK_SECRET_NAME" \
  --from-file=dek="$DEK_FILE" \
  -n "$NS" \
  --dry-run=client -o yaml | oc apply -f -

CURRENT="$(oc get kbsconfig "$KBS_CONFIG" -n "$NS" -o json | jq -r --arg s "$DEK_SECRET_NAME" '.spec.kbsSecretResources // [] | index($s)')"
if [[ "$CURRENT" == "null" ]]; then
  oc patch kbsconfig "$KBS_CONFIG" -n "$NS" --type=json \
    -p="[{\"op\": \"add\", \"path\": \"/spec/kbsSecretResources/-\", \"value\": \"$DEK_SECRET_NAME\"}]"
else
  echo "Secret already listed in kbsSecretResources"
fi

oc rollout restart deployment/trustee-deployment -n "$NS"
oc rollout status deployment/trustee-deployment -n "$NS" --timeout=300s

echo "KBS resource path for guests: $KBS_RESOURCE_PATH"
