#!/usr/bin/env bash
# Install KBS resource Rego: release DEK only to AMD SNP attested guests (AzSnpVtpm).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=defaults.sh
source "$SCRIPT_DIR/defaults.sh"

NS="${TRUSTEE_NS}"
POLICY_FILE="${POLICY_FILE:-$POLICY_DIR/kbs-resource-policy-snp.rego}"

oc whoami >/dev/null || { echo "oc login required" >&2; exit 1; }
[[ -f "$POLICY_FILE" ]] || { echo "Missing $POLICY_FILE" >&2; exit 1; }

echo "==> Patching $RESOURCE_POLICY_CM (allow AzSnpVtpm; deny sample-only attesters)"
oc patch configmap "$RESOURCE_POLICY_CM" -n "$NS" --type merge \
  -p "$(jq -nc --rawfile p "$POLICY_FILE" '{data: {"policy.rego": $p}}')"

oc rollout restart deployment/trustee-deployment -n "$NS"
oc rollout status deployment/trustee-deployment -n "$NS" --timeout=300s

echo "Resource policy applied. Guests must present AzSnpVtpm in attestation token claims."
