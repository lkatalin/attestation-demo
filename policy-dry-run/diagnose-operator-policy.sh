#!/usr/bin/env bash
# Show why operator-default Rego allows/denies a captured or synthetic fixture.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

FIXTURE="${1:-$ROOT/fixtures/input-snp-cvm.json}"
OPERATOR_REGO="${OPERATOR_REGO:-$REPO_ROOT/policy/operator-default-resource-policy.rego}"
DATA="$ROOT/fixtures/data-resource-dek.json"

[[ -f "$FIXTURE" ]] || { echo "Missing fixture: $FIXTURE" >&2; exit 1; }
[[ -f "$OPERATOR_REGO" ]] || { echo "Missing: $OPERATOR_REGO" >&2; exit 1; }

need_cmd jq
command -v opa >/dev/null 2>&1 || {
  echo "opa required — install Open Policy Agent to diagnose Rego rules" >&2
  exit 2
}

echo "==> Diagnose operator-default policy"
echo "Fixture: $FIXTURE"
echo "Policy:  $OPERATOR_REGO"
echo ""

eval_rule() {
  local query="$1"
  opa eval -d "$OPERATOR_REGO" -d "$DATA" -i "$FIXTURE" --format raw "$query" 2>/dev/null | tr -d '\n'
}

allow="$(eval_rule 'data.policy.allow')"
echo "data.policy.allow = ${allow:-error}"

for rule in executable_failing configuration_failing hardware_failing; do
  v="$(eval_rule "data.policy.${rule}")"
  echo "  ${rule} = ${v:-undefined}"
done

echo ""
echo "Trustworthiness vectors (cpu0):"
jq -r '
  .submods.cpu0["ear.trustworthiness-vector"] // {}
  | to_entries[]
  | "  \(.key)=\(.value) (affirming if 2..31)"
' "$FIXTURE" 2>/dev/null || echo "  (not in fixture — use captured guest claims)"

echo ""
if [[ "$allow" == "false" ]]; then
  echo "Operator default would DENY this token."
  echo "Common fix: sync RVPS (configure-trustee) + use production policy with az-snp-vtpm + measurement pins"
  echo "  (hardware_failing often triggers for SNP without operator TCB RVPS entries)"
elif [[ "$allow" == "true" ]]; then
  echo "Operator default would ALLOW — if cluster denies, check live CM differs or DEK not registered."
else
  echo "Could not evaluate — check OPA and fixture shape."
fi
