#!/usr/bin/env bash
# Register cosign verification policy + public key for signed workload images.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=defaults.sh
source "$SCRIPT_DIR/defaults.sh"

NS="${TRUSTEE_NS}"
POLICY_KEY="${POLICY_KEY:-policy}"

[[ -f "$COSIGN_PUB" ]] || {
  echo "Missing $COSIGN_PUB — place cosign.pub under inputs/ (or set COSIGN_PUB=)" >&2
  exit 1
}

oc whoami >/dev/null || { echo "oc login required (KBS / Trustee cluster)" >&2; exit 1; }

IMAGE_REPO="${IMAGE%%:*}"
POLICY_JSON="$(mktemp)"
jq --arg repo "$IMAGE_REPO" --arg tagged "$IMAGE" \
  '.transports.docker[$repo] = .transports.docker["__IMAGE_REF__"] |
   .transports.docker[$tagged] = .transports.docker["__IMAGE_REF__"] |
   del(.transports.docker["__IMAGE_REF__"])' \
  "$POLICY_DIR/verification-policy.template.json" >"$POLICY_JSON"

echo "==> Cluster: $(oc whoami --show-server 2>/dev/null || true)"
echo "==> Image verification policy for: $IMAGE_REPO (and tag $IMAGE)"

oc create secret generic "$SIG_SECRET" \
  --from-file=pub-key="$COSIGN_PUB" \
  -n "$NS" \
  --dry-run=client -o yaml | oc apply -f -

SIG_IN_KBS="$(oc get kbsconfig "$KBS_CONFIG" -n "$NS" -o json | jq -r '.spec.kbsSecretResources[]?' | grep -x "$SIG_SECRET" || true)"
if [[ -z "$SIG_IN_KBS" ]]; then
  oc patch kbsconfig "$KBS_CONFIG" -n "$NS" --type=json \
    -p="[{\"op\": \"add\", \"path\": \"/spec/kbsSecretResources/-\", \"value\": \"$SIG_SECRET\"}]"
fi

POLICY_IN_KBS="$(oc get kbsconfig "$KBS_CONFIG" -n "$NS" -o json | jq -r '.spec.kbsSecretResources[]?' | grep -x "$POLICY_SECRET" || true)"
if [[ -z "$POLICY_IN_KBS" ]]; then
  oc patch kbsconfig "$KBS_CONFIG" -n "$NS" --type=json \
    -p="[{\"op\": \"add\", \"path\": \"/spec/kbsSecretResources/-\", \"value\": \"$POLICY_SECRET\"}]"
fi

oc create secret generic "$POLICY_SECRET" \
  --from-file="$POLICY_KEY=$POLICY_JSON" \
  -n "$NS" \
  --dry-run=client -o yaml | oc apply -f -

rm -f "$POLICY_JSON"

oc rollout restart deployment/trustee-deployment -n "$NS"
oc rollout status deployment/trustee-deployment -n "$NS" --timeout=300s
