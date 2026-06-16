#!/usr/bin/env bash
# Dry-run KBS attestation policies offline (no cluster required).
#
# Usage:
#   ./dry-run.sh [options] [rego-policy ...]
#
# Defaults to repo reference policies if none are passed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
FIXTURES="$ROOT/fixtures"
NAMING_MAP="$ROOT/tee-naming-map.json"

REGO_POLICIES=()
VERIFY_POLICY=""
IMAGE="${IMAGE:-}"
CUSTOM_FIXTURES=()
STRICT=0
VERBOSE=0
SKIP_OPA=0

FAIL=0
WARN=0
OPA_AVAILABLE=0

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \?//'
  cat <<EOF

Options:
  --rego PATH           Rego resource policy (repeatable)
  --verification PATH   Sigstore verification-policy JSON
  --image REF           Image ref for verification-policy template substitution
  --fixture PATH        Extra input JSON to evaluate (repeatable; from capture-claims.sh)
  --strict              Treat warnings as failures
  --verbose             Print OPA commands and extra detail
  --skip-opa            Static checks only (no OPA eval)
  -h, --help            Show this help

Environment:
  OPA, OPA_IMAGE        Override opa binary or Docker image (default: openpolicyagent/opa:latest)
  IMAGE                 Same as --image

Examples:
  $0
  $0 --rego ../kbs-tee-attestation/policy/kbs-resource-policy-snp.rego
  $0 --rego my.rego --verification ../policy/verification-policy.template.json --image quay.io/me/demo:latest
EOF
}

log_ok()   { printf '  OK   %s\n' "$1"; }
log_fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }
log_warn() { printf '  WARN %s\n' "$1"; WARN=1; }
log_info() { [[ "$VERBOSE" -eq 1 ]] && printf '       %s\n' "$1" || true; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 2
  }
}

opa_run() {
  if [[ "$OPA_AVAILABLE" -eq 1 ]]; then
    if [[ -n "${OPA:-}" ]]; then
      "$OPA" "$@"
    elif command -v opa >/dev/null 2>&1; then
      opa "$@"
    else
      # Docker: mount repo root; translate absolute paths under REPO_ROOT to /work/...
      local args=() arg
      for arg in "$@"; do
        case "$arg" in
          "$REPO_ROOT"/*) args+=("/work/${arg#"$REPO_ROOT"/}") ;;
          *) args+=("$arg") ;;
        esac
      done
      docker run --rm \
        -v "$REPO_ROOT:/work" \
        -w /work \
        "${OPA_IMAGE:-openpolicyagent/opa:latest}" \
        "${args[@]}"
    fi
  else
    return 127
  fi
}

detect_opa() {
  [[ "$SKIP_OPA" -eq 1 ]] && return 0
  if [[ -n "${OPA:-}" ]] && command -v "$OPA" >/dev/null 2>&1; then
    OPA_AVAILABLE=1
    return 0
  fi
  if command -v opa >/dev/null 2>&1; then
    OPA_AVAILABLE=1
    return 0
  fi
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    OPA_AVAILABLE=1
    return 0
  fi
  log_warn "OPA not found (install opa or Docker); skipping Rego evaluation — static checks only"
}

strip_comments() {
  sed 's/#.*$//' "$1"
}

rego_uses_pascal_tee_keys() {
  local policy="$1"
  local body
  body="$(strip_comments "$policy")"
  while IFS= read -r log_tee; do
    [[ -z "$log_tee" ]] && continue
    if grep -qE "\[\"${log_tee}\"\]|\['${log_tee}'\]|\\.${log_tee}\\b|\[\"${log_tee}\"\\]" <<<"$body"; then
      echo "$log_tee"
    fi
  done < <(jq -r '.mappings[].log_tee' "$NAMING_MAP")
}

rego_uses_token_keys() {
  local policy="$1"
  local body
  body="$(strip_comments "$policy")"
  jq -r '.mappings[].token_key' "$NAMING_MAP" | while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    if grep -qE "\[\"${key}\"\]|\['${key}'\]" <<<"$body"; then
      echo "$key"
    fi
  done
}

check_rego_static() {
  local policy="$1"
  local label="$2"
  local body
  body="$(strip_comments "$policy")"

  echo "==> Static Rego: $label"

  if ! grep -qE '^package[[:space:]]+policy\b' "$policy"; then
    log_fail "package policy (KBS resource plugin expects package policy)"
  else
    log_ok "package policy"
  fi

  if grep -qE 'default[[:space:]]+allow[[:space:]]*=[[:space:]]*false' "$policy"; then
    log_ok "default allow = false (deny-by-default)"
  else
    log_warn "missing explicit 'default allow = false' — policy may be overly permissive"
  fi

  if grep -qE 'count\([[:space:]]*input\.submods[[:space:]]*\)[[:space:]]*>' <<<"$body"; then
    log_fail "uses count(input.submods) — allows sample-only baseline guests to decrypt"
  else
    log_ok "no count(input.submods) shortcut"
  fi

  local pascal_hits
  pascal_hits="$(rego_uses_pascal_tee_keys "$policy" || true)"
  if [[ -n "$pascal_hits" ]]; then
    while IFS= read -r tee; do
      [[ -z "$tee" ]] && continue
      local token_key
      token_key="$(jq -r --arg t "$tee" '.mappings[] | select(.log_tee == $t) | .token_key' "$NAMING_MAP")"
      log_fail "PascalCase tee key \"$tee\" in Rego path — token uses \"$token_key\" (see tee-naming-map.json)"
    done <<<"$pascal_hits"
  else
    log_ok "no PascalCase tee keys in annotated-evidence paths"
  fi

  if grep -qE 'annotated-evidence|ear\.veraison\.annotated-evidence' <<<"$body"; then
    local token_hits
    token_hits="$(rego_uses_token_keys "$policy" | sort -u | tr '\n' ' ')"
    if [[ -n "${token_hits// /}" ]]; then
      log_ok "references token evidence keys: ${token_hits% }"
    else
      log_warn "mentions annotated-evidence but no known token keys (az-snp-vtpm, sample, …)"
    fi
  else
    log_warn "policy does not reference ear.veraison.annotated-evidence — may not inspect TEE type"
  fi

  if grep -qE 'data\.plugin[[:space:]]*==[[:space:]]*"resource"' <<<"$body"; then
    log_ok "scopes to data.plugin == \"resource\""
  else
    log_warn "missing data.plugin == \"resource\" guard"
  fi

  if grep -qiE '\bAzSnpVtpm\b' "$policy" && ! grep -qF 'az-snp-vtpm' <<<"$body"; then
    log_fail "mentions AzSnpVtpm (log label) but not az-snp-vtpm (JWT claim key)"
  fi

  if grep -qE 'MEASUREMENT_HEX|PCR11_HEX' "$policy"; then
    log_warn "measurement placeholders (MEASUREMENT_HEX/PCR11_HEX) not replaced — run capture-claims.sh"
  fi
}

opa_eval_allow() {
  local policy="$1"
  local input_fixture="$2"
  local abs_policy abs_input abs_data
  abs_policy="$(cd "$(dirname "$policy")" && pwd)/$(basename "$policy")"
  abs_input="$(cd "$(dirname "$input_fixture")" && pwd)/$(basename "$input_fixture")"
  abs_data="$(cd "$(dirname "$FIXTURES")" && pwd)/fixtures/data-resource-dek.json"

  log_info "opa eval -d $abs_policy -d $abs_data -i $abs_input 'data.policy.allow'"

  local result
  if ! result="$(opa_run eval \
    -d "$abs_policy" \
    -d "$abs_data" \
    -i "$abs_input" \
    --format raw \
    'data.policy.allow' 2>&1)"; then
    echo "$result" >&2
    echo "error"
    return 1
  fi
  echo "$result" | tr -d '\n'
}

check_rego_opa() {
  local policy="$1"
  local label="$2"

  [[ "$OPA_AVAILABLE" -eq 1 ]] || return 0

  echo "==> OPA evaluation: $label"

  local snp sample empty both
  snp="$(opa_eval_allow "$policy" "$FIXTURES/input-snp-cvm.json" || echo "error")"
  sample="$(opa_eval_allow "$policy" "$FIXTURES/input-sample-only.json" || echo "error")"
  empty="$(opa_eval_allow "$policy" "$FIXTURES/input-empty-submods.json" || echo "error")"
  both="$(opa_eval_allow "$policy" "$FIXTURES/input-snp-and-sample.json" || echo "error")"

  case "$snp" in
    true)  log_ok "SNP CVM fixture → allow" ;;
    false) log_fail "SNP CVM fixture → deny (confidential guest would not get DEK)" ;;
    *)     log_fail "SNP CVM fixture → OPA error: $snp" ;;
  esac

  case "$sample" in
    false) log_ok "sample-only fixture → deny (baseline worker blocked)" ;;
    true)  log_fail "sample-only fixture → allow (non-CVM could decrypt DEK)" ;;
    *)     log_fail "sample-only fixture → OPA error: $sample" ;;
  esac

  case "$empty" in
    false) log_ok "empty submods fixture → deny" ;;
    true)  log_fail "empty submods fixture → allow" ;;
    *)     log_fail "empty submods fixture → OPA error: $empty" ;;
  esac

  case "$both" in
    true)  log_ok "SNP+sample fixture → allow (SNP evidence present)" ;;
    false) log_warn "SNP+sample fixture → deny (policy may require exclusive SNP token)" ;;
    *)     log_fail "SNP+sample fixture → OPA error: $both" ;;
  esac

  local fixture base result
  for fixture in "${CUSTOM_FIXTURES[@]}"; do
    [[ -f "$fixture" ]] || { log_fail "custom fixture missing: $fixture"; continue; }
    base="$(basename "$fixture")"
    result="$(opa_eval_allow "$policy" "$fixture" || echo "error")"
    case "$result" in
      true)  log_ok "captured $base → allow" ;;
      false) log_warn "captured $base → deny (expected for pinned-measurement policy if fixture differs)" ;;
      *)     log_fail "captured $base → OPA error: $result" ;;
    esac
  done
}

render_verification_policy() {
  local template="$1"
  local out="$2"
  if [[ -n "$IMAGE" ]]; then
    local repo="${IMAGE%%:*}"
    jq --arg repo "$repo" --arg tagged "$IMAGE" \
      '.transports.docker[$repo] = .transports.docker["__IMAGE_REF__"] |
       .transports.docker[$tagged] = .transports.docker["__IMAGE_REF__"] |
       del(.transports.docker["__IMAGE_REF__"])' \
      "$template" >"$out"
  else
    cp "$template" "$out"
  fi
}

check_verification_policy() {
  local template="$1"
  local label="$2"
  local rendered
  rendered="$(mktemp)"
  trap 'rm -f "$rendered"' RETURN

  echo "==> Sigstore verification policy: $label"

  if ! jq empty "$template" 2>/dev/null; then
    log_fail "invalid JSON"
    return
  fi
  log_ok "valid JSON"

  render_verification_policy "$template" "$rendered"

  if jq -e '.default[]? | select(.type == "reject")' "$rendered" >/dev/null; then
    log_ok "default action is reject (deny unsigned images)"
  else
    log_fail "missing default reject rule"
  fi

  if [[ -z "$IMAGE" ]] && jq -e '.transports.docker["__IMAGE_REF__"]' "$rendered" >/dev/null; then
    log_warn "template still has __IMAGE_REF__ — pass --image or IMAGE= to validate substitution"
  elif [[ -n "$IMAGE" ]]; then
    if jq -e '.transports.docker["__IMAGE_REF__"]' "$rendered" >/dev/null; then
      log_fail "__IMAGE_REF__ placeholder not substituted for IMAGE=$IMAGE"
    else
      log_ok "image refs substituted for $IMAGE"
    fi
  fi

  local bad_keys
  bad_keys="$(jq -r '
    [.transports.docker // {} | .. | objects | select(has("keyPath")) | .keyPath
     | select(startswith("kbs:///") | not)] | unique | .[]?' "$rendered")"
  if [[ -n "$bad_keys" ]]; then
    while IFS= read -r kp; do
      [[ -z "$kp" ]] && continue
      log_fail "keyPath must use kbs:/// scheme: $kp"
    done <<<"$bad_keys"
  else
    log_ok "sigstoreSigned keyPath values use kbs:///"
  fi

  local paths
  paths="$(jq -r '[.transports.docker // {} | .. | objects | select(has("keyPath")) | .keyPath] | unique | .[]?' "$rendered")"
  if [[ -n "$paths" ]]; then
    log_info "keyPath entries: $(echo "$paths" | tr '\n' ', ')"
    if grep -q 'confidential-inferencing-signature' <<<"$paths"; then
      log_ok "references confidential-inferencing-signature KBS resource"
    fi
  fi
}

check_naming_reference() {
  echo "==> TEE naming reference (log label vs JWT key)"
  jq -r '.mappings[] | "  \(.log_tee) (Trustee logs) → \(.token_key) (Rego / JWT)"' "$NAMING_MAP"
}

run_workload_kbs_path_check() {
  echo "==> Runtime DEK fetch stack (see also: check-workload-kbs-path.sh)"
  if bash "$ROOT/check-workload-kbs-path.sh"; then
    return 0
  fi
  FAIL=1
  return 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rego)
      REGO_POLICIES+=("$2")
      shift 2
      ;;
    --verification)
      VERIFY_POLICY="$2"
      shift 2
      ;;
    --image)
      IMAGE="$2"
      shift 2
      ;;
    --fixture)
      CUSTOM_FIXTURES+=("$2")
      shift 2
      ;;
    --strict)
      STRICT=1
      shift
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    --skip-opa)
      SKIP_OPA=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do REGO_POLICIES+=("$1"); shift; done
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      REGO_POLICIES+=("$1")
      shift
      ;;
  esac
done

need_cmd jq
need_cmd grep
need_cmd sed

if [[ ${#REGO_POLICIES[@]} -eq 0 ]]; then
  REGO_POLICIES=(
    "$REPO_ROOT/kbs-tee-attestation/policy/kbs-resource-policy-snp.rego"
    "$REPO_ROOT/policy/kbs-resource-policy-snp-demo.rego"
  )
fi

if [[ -z "$VERIFY_POLICY" ]]; then
  VERIFY_POLICY="$REPO_ROOT/kbs-tee-attestation/policy/verification-policy.template.json"
fi

detect_opa

echo "Attestation policy dry-run"
echo "Repo: $REPO_ROOT"
echo ""

check_naming_reference
echo ""

run_workload_kbs_path_check
echo ""

for policy in "${REGO_POLICIES[@]}"; do
  [[ -f "$policy" ]] || {
    log_fail "missing Rego policy: $policy"
    continue
  }
  label="${policy#"$REPO_ROOT"/}"
  check_rego_static "$policy" "$label"
  check_rego_opa "$policy" "$label"
  echo ""
done

if [[ -f "$VERIFY_POLICY" ]]; then
  check_verification_policy "$VERIFY_POLICY" "${VERIFY_POLICY#"$REPO_ROOT"/}"
  echo ""
else
  log_warn "verification policy not found: $VERIFY_POLICY"
fi

echo "==> Summary"
if [[ "$FAIL" -eq 0 && "$WARN" -eq 0 ]]; then
  echo "All checks passed."
elif [[ "$FAIL" -eq 0 ]]; then
  echo "Passed with $WARN warning(s)."
  [[ "$STRICT" -eq 1 ]] && FAIL=1
else
  echo "Failed with $FAIL failure(s) and $WARN warning(s)."
fi

exit "$FAIL"
