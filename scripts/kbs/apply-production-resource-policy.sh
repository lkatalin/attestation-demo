#!/usr/bin/env bash
# Apply generated production resource Rego (pinned CVM + EAR vectors + az-snp-vtpm).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../defaults.sh
source "$SCRIPT_DIR/../defaults.sh"

NS="${TRUSTEE_NS}"
CM=trusteeconfig-resource-policy
POLICY_FILE="${POLICY_FILE:-$ROOT/policy/kbs-resource-policy-snp-production.rego}"

oc whoami >/dev/null || { echo "oc login required (KBS / Trustee cluster)" >&2; exit 1; }
[[ -f "$POLICY_FILE" ]] || {
  echo "Missing $POLICY_FILE — run: bash scripts/kbs/generate-production-policy.sh --pins policy/cvm-pins.json" >&2
  exit 1
}

if grep -qE 'MEASUREMENT_HEX|PCR11_HEX|PIN_' "$POLICY_FILE" 2>/dev/null; then
  echo "Policy still has placeholders — generate from captured golden CVM first." >&2
  exit 1
fi

echo "==> Dry-run (offline) before apply"
FIXTURE="${PRODUCTION_FIXTURE:-}"
SKIP_FIXTURE="${SKIP_PRODUCTION_FIXTURE:-0}"
if [[ -z "$FIXTURE" && "$SKIP_FIXTURE" != "1" ]]; then
  for f in "$ROOT/policy-dry-run/captured/input-"*.json; do
    [[ -f "$f" ]] && FIXTURE="$f" && break
  done
fi
if [[ -x "$ROOT/policy-dry-run/dry-run-measurements.sh" ]]; then
  DRY=(bash "$ROOT/policy-dry-run/dry-run-measurements.sh" --rego "$POLICY_FILE" --require-pinning)
  [[ -n "$FIXTURE" && -f "$FIXTURE" && "$SKIP_FIXTURE" != "1" ]] && DRY+=(--fixture "$FIXTURE")
  "${DRY[@]}" || {
    echo "Dry-run failed — use captured fixture matching pinned measurement/pcr11" >&2
    exit 1
  }
fi

echo "==> Patching $CM (production SNP + CVM pins)"
oc patch configmap "$CM" -n "$NS" --type merge \
  -p "$(jq -nc --rawfile p "$POLICY_FILE" '{data: {"policy.rego": $p}}')"

oc rollout restart deployment/trustee-deployment -n "$NS"
oc rollout status deployment/trustee-deployment -n "$NS" --timeout=300s

echo "==> Act II — prove golden pod re-attests under pinned policy:"
echo "  make demo-act-ii"
echo ""
echo "Expected Trustee after Act II restart:"
echo "  tee=AzSnpVtpm + GET .../confidential-inferencing-dek/dek 200"
