#!/usr/bin/env bash
# Remove per-pod kernel_params annotation from inference-confidential if it was applied.
# Does NOT revert the kata-oc remote configuration.toml patch — that is required for capture.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../defaults.sh
source "$SCRIPT_DIR/../defaults.sh"

ANNOTATION_KEY="io.katacontainers.config.hypervisor.kernel_params"
DEP=inference-confidential
NS="${DEMO_NAMESPACE}"

oc whoami >/dev/null || { echo "oc login required" >&2; exit 1; }

echo "==> Remove optional $ANNOTATION_KEY from $DEP (if present)"
oc patch deployment "$DEP" -n "$NS" --type merge -p "$(jq -nc \
  --arg k "$ANNOTATION_KEY" \
  '{spec: {template: {metadata: {annotations: {($k): null}}}}}')" \
  || echo "    (annotation was not set)"

echo ""
echo "If rollout was stuck on a broken revision, recreate the pod:"
echo "  oc delete pod -n $NS -l app=inference-confidential"
echo ""
echo "Guest REST for capture comes from kata-oc config, not this deployment annotation:"
echo "  make enable-peer-pods-guest-rest-api"
echo "  make capture-golden-claims"
