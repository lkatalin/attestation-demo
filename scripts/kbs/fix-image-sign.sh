#!/usr/bin/env bash
# Re-sign image for peer-pod CDH (no Rekor required) and refresh KBS image policy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../defaults.sh
source "$SCRIPT_DIR/../defaults.sh"

[[ -f "$ARTIFACTS/cosign.key" ]] || {
  echo "Missing $ARTIFACTS/cosign.key — run: make setup-cosign" >&2
  exit 1
}

export COSIGN_PASSWORD="${COSIGN_PASSWORD:-confidential-inferencing-demo}"
IMAGE_REPO="${IMAGE%%:*}"

# Peer-pod CDH uses containers/image sigstoreSigned, which does not verify cosign v3
# bundle referrers. Quay accepts legacy .sig tags from cosign v2, not v3's docker media type.
DIGEST="$(skopeo inspect "docker://$IMAGE" | jq -r .Digest)"
SIGN_REF="${IMAGE%%:*}@${DIGEST}"
COSIGN_BIN="${COSIGN_BIN:-cosign}"
if [[ "${COSIGN_BIN}" == "cosign" ]] && cosign version 2>/dev/null | grep -q 'GitVersion:.*v3\.'; then
  COSIGN_BIN="$(bash "$SCRIPT_DIR/../cosign-v2-bin.sh")"
fi
echo "==> Sign $SIGN_REF with $COSIGN_BIN (legacy .sig tag for CDH)"
COSIGN_EXPERIMENTAL=1 "$COSIGN_BIN" sign --key "$ARTIFACTS/cosign.key" -y "$SIGN_REF"

echo "==> Verify locally"
"$COSIGN_BIN" verify --key "$ARTIFACTS/cosign.pub" "$IMAGE"

echo "==> Update KBS policy (repo + :tag keys)"
bash "$SCRIPT_DIR/register-policy.sh"

echo "==> Restart confidential pod"
oc scale deployment inference-confidential -n "$DEMO_NAMESPACE" --replicas=1 2>/dev/null || true
oc rollout restart deployment/inference-confidential -n "$DEMO_NAMESPACE" 2>/dev/null || true
bash "$(dirname "$0")/restart-confidential-workloads.sh" 2>/dev/null || \
  oc delete pod -n "$DEMO_NAMESPACE" -l app=inference-confidential --ignore-not-found --wait=false 2>/dev/null || true

echo "Done. Watch: oc get pods -n $DEMO_NAMESPACE -l app=inference-confidential -w"
