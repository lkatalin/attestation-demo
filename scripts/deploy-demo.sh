#!/usr/bin/env bash
# Deploy three-arm demo: confidential (works), plaintext control (works), baseline encrypted (fails).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=defaults.sh
source "$(dirname "$0")/defaults.sh"

KBS_MODE="${KBS_MODE:-local}"
DEPLOY_PROFILE="${DEPLOY_PROFILE:-$KBS_MODE}"

oc whoami >/dev/null || { echo "oc login required (inference cluster)" >&2; exit 1; }

oc apply -f "$ROOT/deploy/namespace.yaml"
bash "$ROOT/scripts/kbs/configure-kbs.sh"
# shellcheck source=/dev/null
source "$ROOT/deploy/kbs.env"
export IMAGE KBS_URL KBS_RESOURCE_PATH
echo "==> Deploy profile: $DEPLOY_PROFILE (KBS_URL=$KBS_URL)"

if [[ "${CREATE_PULL_SECRET:-1}" == "1" ]]; then
  bash "$ROOT/scripts/create-pull-secret.sh" || true
fi

oc apply -f "$ROOT/deploy/configmap-entrypoint.yaml"

echo "==> Applying demo workloads"
for f in deployment-confidential deployment-plaintext deployment-baseline-encrypted; do
  envsubst '${IMAGE} ${KBS_URL} ${KBS_RESOURCE_PATH}' <"$ROOT/deploy/${f}.yaml" | oc apply -f -
done
oc apply -f "$ROOT/deploy/service-confidential.yaml"
oc apply -f "$ROOT/deploy/service-plaintext.yaml"
oc apply -f "$ROOT/deploy/route-confidential.yaml"
oc apply -f "$ROOT/deploy/route-plaintext.yaml"

echo "==> Waiting for confidential + plaintext (baseline expected to fail)"
echo "    Peer pods can take 15-30+ min on first CVM; progress deadline may need a retry."
echo "    If sandbox events show Standard_DC* not available in region, fix peer-pods AZURE_INSTANCE_SIZE (see README)."

if ! oc rollout status deployment/inference-confidential -n confidential-inferencing --timeout=900s; then
  echo ""
  echo "ERROR: inference-confidential did not become ready."
  echo "  oc describe pod -n confidential-inferencing -l app=inference-confidential | tail -40"
  echo "  oc logs -n trustee-operator-system deployment/trustee-deployment --tail=40 | grep -E 'trustee-image-policy|PluginInternal|PolicyDeny'"
  echo "  Common:"
  echo "    CDH CreateContainerError + Trustee PluginInternalError on trustee-image-policy"
  echo "      → trustee-image-policy secret not in kbsconfig: bash scripts/kbs/register-policy.sh"
  echo "    Azure InvalidParameter — DC VM size unavailable in this availability zone"
  echo "      → bash scripts/fix-peer-pods-azure.sh"
  exit 1
fi
oc rollout status deployment/inference-plaintext -n confidential-inferencing --timeout=300s

echo ""
echo "Demo routes:"
echo "  confidential: https://$(oc get route inference-confidential -n confidential-inferencing -o jsonpath='{.spec.host}')"
echo "  plaintext:    https://$(oc get route inference-plaintext -n confidential-inferencing -o jsonpath='{.spec.host}')"
echo ""
echo "Run: scripts/demo-present.sh"
