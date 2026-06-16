#!/usr/bin/env bash
# KBS tenancy / blast-radius linter for resource Rego and deployment paths.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
load_repo_defaults

REGO="${REGO:-$REPO_ROOT/policy/kbs-resource-policy-snp-demo.rego}"
STRICT=0

usage() {
  echo "Usage: $0 [--rego PATH] [--strict]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rego) REGO="$2"; shift 2 ;;
    --strict) STRICT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 2 ;;
  esac
done

reset_counters
echo "==> KBS tenancy / blast-radius"
echo "Policy: $REGO"
echo "Expected DEK path: $KBS_RESOURCE_PATH"
echo ""

[[ -f "$REGO" ]] || { log_fail "missing Rego: $REGO"; summary_exit "$STRICT"; exit 1; }
body="$(sed 's/#.*$//' "$REGO")"

if grep -qE 'default[[:space:]]+allow[[:space:]]*=[[:space:]]*false' "$REGO"; then
  log_ok "deny-by-default"
else
  log_fail "missing default allow = false"
fi

if grep -qE 'count\([[:space:]]*input\.submods' <<<"$body"; then
  log_fail "count(input.submods) allows sample-only guests"
else
  log_ok "no permissive count(submods) rule"
fi

if grep -qE 'allow[[:space:]]+if[[:space:]]*\{[[:space:]]*\}' <<<"$body" || grep -qE 'allow[[:space:]]*=[[:space:]]*true' <<<"$body"; then
  log_fail "unconditional allow rule detected"
else
  log_ok "no unconditional allow"
fi

if grep -q 'data.plugin == "resource"' <<<"$body"; then
  log_ok "scoped to data.plugin == resource"
else
  log_warn "missing data.plugin guard — policy may apply too broadly"
fi

if grep -q 'az-snp-vtpm' <<<"$body"; then
  log_ok "requires az-snp-vtpm evidence (blocks sample-only baseline)"
else
  log_fail "missing az-snp-vtpm requirement"
fi

tenant="${KBS_RESOURCE_PATH%%/*}"
if [[ "$tenant" != "default" ]]; then
  log_info "non-default tenant prefix: $tenant — ensure Rego scopes resource-path if multi-tenant"
fi

fixture="$ROOT/fixtures/data-resource-dek.json"
if [[ -f "$fixture" ]]; then
  fp="$(jq -r '.["resource-path"] | join("/")' "$fixture")"
  if [[ "$fp" == "$KBS_RESOURCE_PATH" ]]; then
    log_ok "fixture resource-path matches KBS_RESOURCE_PATH"
  else
    log_warn "fixture path ($fp) != KBS_RESOURCE_PATH ($KBS_RESOURCE_PATH)"
  fi
fi

dep="$REPO_ROOT/deploy/deployment-confidential.yaml"
if [[ -f "$dep" ]] && grep -qF '${KBS_RESOURCE_PATH}' "$dep"; then
  log_ok "deployment uses KBS_RESOURCE_PATH substitution"
fi

baseline="$REPO_ROOT/deploy/deployment-baseline-encrypted.yaml"
if [[ -f "$baseline" ]] && grep -q 'DEMO_MODE' "$baseline"; then
  log_ok "baseline deployment exists as negative control (should not get DEK on worker)"
fi

summary_exit "$STRICT"
