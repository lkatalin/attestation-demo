#!/usr/bin/env bash
# Quick checks that KBS is up and configured for hardware attestation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=defaults.sh
source "$SCRIPT_DIR/defaults.sh"

NS="${TRUSTEE_NS}"
FAIL=0

oc whoami >/dev/null || { echo "oc login required" >&2; exit 1; }

check() {
  local label="$1" ok="$2"
  if [[ "$ok" == "1" ]]; then
    echo "  OK   $label"
  else
    echo "  FAIL $label"
    FAIL=1
  fi
}

echo "==> Trustee deployment"
READY="$(oc get deployment trustee-deployment -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
[[ "${READY:-0}" -ge 1 ]] && check "trustee-deployment ready" 1 || check "trustee-deployment ready" 0

echo "==> Secrets registered in KbsConfig"
for sec in "$DEK_SECRET_NAME" "$SIG_SECRET" "$POLICY_SECRET"; do
  listed="$(oc get kbsconfig "$KBS_CONFIG" -n "$NS" -o json | jq -r --arg s "$sec" '.spec.kbsSecretResources // [] | index($s)')"
  [[ "$listed" != "null" ]] && check "kbsSecretResources contains $sec" 1 || check "kbsSecretResources contains $sec" 0
done

echo "==> Resource policy (production: az-snp-vtpm claim key)"
if oc get configmap "$RESOURCE_POLICY_CM" -n "$NS" -o jsonpath='{.data.policy\.rego}' 2>/dev/null | grep -qF 'az-snp-vtpm'; then
  check "resource policy uses JWT key az-snp-vtpm" 1
else
  check "resource policy uses JWT key az-snp-vtpm" 0
fi
if oc get configmap "$RESOURCE_POLICY_CM" -n "$NS" -o jsonpath='{.data.policy\.rego}' 2>/dev/null | grep -qE '\["AzSnpVtpm"\]'; then
  check "resource policy avoids PascalCase AzSnpVtpm path" 0
else
  check "resource policy avoids PascalCase AzSnpVtpm path" 1
fi

echo "==> Remote reachability"
if [[ -f "$OUTPUT_DIR/kbs.url" ]]; then
  KBS_URL="$(tr -d '\n' <"$OUTPUT_DIR/kbs.url")"
else
  KBS_URL="https://$(oc get route "$ROUTE_NAME" -n "$NS" -o jsonpath='{.spec.host}')"
fi
if curl -sk --connect-timeout 5 "${KBS_URL}/kbs/v0/health" -o /dev/null -w '' 2>/dev/null; then
  check "KBS health ${KBS_URL}/kbs/v0/health" 1
else
  check "KBS health ${KBS_URL}/kbs/v0/health (curl from this host)" 0
fi

echo "==> Attestation token verification enabled"
TOKEN_SECRET="$(oc get trusteeconfig "$TRUSTEE_CONFIG" -n "$NS" -o jsonpath='{.spec.attestationTokenVerificationSpec.tlsSecretName}' 2>/dev/null || true)"
[[ -n "$TOKEN_SECRET" ]] && check "TrusteeConfig attestationTokenVerificationSpec" 1 || check "TrusteeConfig attestationTokenVerificationSpec" 0

exit "$FAIL"
