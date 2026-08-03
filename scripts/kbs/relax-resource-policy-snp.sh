#!/usr/bin/env bash
# Trustee resource policy for AMD SNP demos.
#
# Problem A: default operator policy can return PolicyDeny on trustee-image-policy even when
# attest verify passes (EAR trust vectors / affirming).
# Problem B: an overly permissive fix (allow any submods) lets the sample attester fetch the
# DEK from ordinary pods — baseline-encrypted incorrectly goes Running.
#
# This policy requires az-snp-vtpm in token claims (see docs/attestation-and-policy.md).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../defaults.sh
source "$SCRIPT_DIR/../defaults.sh"

NS="${TRUSTEE_NS}"
CM=trusteeconfig-resource-policy
POLICY_FILE="${POLICY_FILE:-$ROOT/policy/kbs-resource-policy-snp-demo.rego}"

oc whoami >/dev/null || { echo "oc login required" >&2; exit 1; }

echo "==> Patching $CM (allow AzSnpVtpm only — baseline sample attester denied)"
oc patch configmap "$CM" -n "$NS" --type merge \
  -p "$(jq -nc --rawfile p "$POLICY_FILE" '{data: {"resource-policy.rego": $p}}')"

oc rollout restart deployment/trustee-deployment -n "$NS"
oc rollout status deployment/trustee-deployment -n "$NS" --timeout=300s

echo "==> Restart workloads (confidential + baseline pick up policy on next KBS request)"
RESTART_BASELINE=1 bash "$SCRIPT_DIR/restart-confidential-workloads.sh"

echo "Expected:"
echo "  confidential (kata-remote): GET .../confidential-inferencing-dek/dek 200"
echo "  baseline (default runtime): PolicyDeny or KBS auth failure — CrashLoop, no Route to prompt"
