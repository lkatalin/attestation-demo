#!/usr/bin/env bash
# Measurement-pinned Rego validation against captured fixtures.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

REGO=""
FIXTURES=()
REQUIRE_PINNING=0
STRICT=0
SKIP_OPA=0
OPA_AVAILABLE=0

usage() {
  cat <<EOF
Usage: $0 [options] [--rego PATH] [--fixture PATH ...]

  --rego PATH           Rego policy (default: examples/kbs-resource-policy-snp-measurements.rego)
  --fixture PATH        Captured input JSON (repeatable)
  --require-pinning     Fail if MEASUREMENT_HEX / PCR11_HEX placeholders remain
  --skip-opa            Static checks only
  --strict              Warnings fail the run
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rego) REGO="$2"; shift 2 ;;
    --fixture) FIXTURES+=("$2"); shift 2 ;;
    --require-pinning) REQUIRE_PINNING=1; shift ;;
    --skip-opa) SKIP_OPA=1; shift ;;
    --strict) STRICT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$REGO" ]] && REGO="$ROOT/examples/kbs-resource-policy-snp-measurements.rego"
[[ ${#FIXTURES[@]} -eq 0 ]] && FIXTURES=("$ROOT/fixtures/input-snp-cvm.json")
[[ -f "$REGO" ]] || { echo "Missing Rego: $REGO" >&2; exit 1; }

need_cmd jq

detect_opa() {
  [[ "$SKIP_OPA" -eq 1 ]] && return 0
  if command -v opa >/dev/null 2>&1 || { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }; then
    OPA_AVAILABLE=1
  else
    log_warn "OPA unavailable — static checks only"
  fi
}

opa_eval() {
  local policy="$1" input="$2"
  if command -v opa >/dev/null 2>&1; then
    opa eval -d "$policy" -d "$ROOT/fixtures/data-resource-dek.json" -i "$input" \
      --format raw 'data.policy.allow' 2>/dev/null | tr -d '\n'
  else
    docker run --rm -v "$REPO_ROOT:/work" -w /work openpolicyagent/opa:latest eval \
      -d "/work/${policy#"$REPO_ROOT"/}" \
      -d "/work/policy-dry-run/fixtures/data-resource-dek.json" \
      -i "/work/${input#"$REPO_ROOT"/}" \
      --format raw 'data.policy.allow' 2>/dev/null | tr -d '\n'
  fi
}

reset_counters
echo "==> Measurement-pinned Rego validation"
echo "Policy: $REGO"
echo ""

body="$(sed 's/#.*$//' "$REGO")"
if grep -qE 'MEASUREMENT_HEX|PCR11_HEX' <<<"$body"; then
  if [[ "$REQUIRE_PINNING" -eq 1 ]]; then
    log_fail "placeholders MEASUREMENT_HEX/PCR11_HEX still present — run capture-claims.sh and pin values"
  else
    log_warn "placeholders present — OK for template; use --require-pinning in prod CI"
  fi
else
  log_ok "measurement / PCR11 values appear pinned (no placeholders)"
fi

if grep -q 'az-snp-vtpm' <<<"$body"; then
  log_ok "policy keys off az-snp-vtpm evidence"
else
  log_fail "policy missing az-snp-vtpm check"
fi

if grep -qE 'measurement|pcr11' <<<"$body"; then
  log_ok "policy references measurement and/or pcr11"
else
  log_warn "policy does not pin measurement/pcr11 fields"
fi

detect_opa

if [[ "$OPA_AVAILABLE" -eq 1 ]]; then
  echo ""
  echo "==> OPA syntax check"
  if command -v opa >/dev/null 2>&1; then
    if opa check "$REGO" 2>/tmp/opa-check.err; then
      log_ok "opa check passed"
    else
      log_fail "opa check failed — fix Rego before apply ($(head -1 /tmp/opa-check.err))"
    fi
  else
    docker run --rm -v "$REPO_ROOT:/work" -w /work openpolicyagent/opa:latest check \
      "/work/${REGO#"$REPO_ROOT"/}" >/tmp/opa-check.err 2>&1 \
      && log_ok "opa check passed" \
      || log_fail "opa check failed — fix Rego before apply ($(head -1 /tmp/opa-check.err))"
  fi
  echo ""
  echo "==> OPA evaluation"
  sample="$ROOT/fixtures/input-sample-only.json"
  r="$(opa_eval "$REGO" "$sample" || echo error)"
  case "$r" in
    false) log_ok "sample-only fixture → deny" ;;
    true)  log_fail "sample-only fixture → allow (non-CVM could decrypt)" ;;
    *)     log_fail "sample fixture OPA error: $r" ;;
  esac

  for fx in "${FIXTURES[@]}"; do
    [[ -f "$fx" ]] || { log_fail "missing fixture: $fx"; continue; }
    r="$(opa_eval "$REGO" "$fx" || echo error)"
    case "$r" in
      true)  log_ok "$(basename "$fx") → allow" ;;
      false) log_warn "$(basename "$fx") → deny (expected if fixture is not pinned build)" ;;
      *)     log_fail "$(basename "$fx") → OPA error: $r" ;;
    esac
  done
fi

summary_exit "$STRICT"
