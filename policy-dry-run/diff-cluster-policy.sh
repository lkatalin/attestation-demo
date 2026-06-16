#!/usr/bin/env bash
# Diff git-canonical KBS policies against live cluster (optional oc login).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
load_repo_defaults

REGO_GIT="${REGO_GIT:-$REPO_ROOT/policy/kbs-resource-policy-snp-demo.rego}"
VERIFY_TEMPLATE="${VERIFY_TEMPLATE:-$REPO_ROOT/kbs-tee-attestation/policy/verification-policy.template.json}"
ALLOW_DRIFT=0
STRICT=0

usage() {
  cat <<EOF
Usage: $0 [options]

  --rego PATH           Git Rego canonical copy
  --verification PATH   Git verification policy template
  --allow-drift         Report drift as warnings only (not failures)
  --strict
  -h, --help

Requires: oc logged in to KBS / Trustee cluster
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rego) REGO_GIT="$2"; shift 2 ;;
    --verification) VERIFY_TEMPLATE="$2"; shift 2 ;;
    --allow-drift) ALLOW_DRIFT=1; shift ;;
    --strict) STRICT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

need_cmd jq
reset_counters
echo "==> Cluster policy drift detection"
echo "Cluster: $(oc whoami --show-server 2>/dev/null || echo 'not logged in')"
echo ""

if ! oc_available; then
  log_fail "oc login required for diff-cluster-policy"
  summary_exit "$STRICT"
  exit 1
fi

echo "==> Resource Rego (trusteeconfig-resource-policy)"
if [[ -f "$REGO_GIT" ]]; then
  live="$(mktemp)"
  git="$(mktemp)"
  cp "$REGO_GIT" "$git"
  oc get configmap trusteeconfig-resource-policy -n "$TRUSTEE_NS" \
    -o jsonpath='{.data.policy\.rego}' >"$live" 2>/dev/null || true
  if [[ ! -s "$live" ]]; then
    log_fail "could not read live resource policy from cluster"
  elif diff -q "$git" "$live" >/dev/null 2>&1; then
    log_ok "live resource Rego matches git: ${REGO_GIT#"$REPO_ROOT"/}"
  else
    msg="live resource Rego differs from git (${REGO_GIT#"$REPO_ROOT"/})"
    if [[ "$ALLOW_DRIFT" -eq 1 ]]; then log_warn "$msg"; else log_fail "$msg"; fi
    log_info "diff: diff -u $REGO_GIT <(oc get cm trusteeconfig-resource-policy -n $TRUSTEE_NS -o jsonpath='{.data.policy\\.rego}')"
  fi
  rm -f "$live" "$git"
else
  log_warn "git Rego not found: $REGO_GIT"
fi

echo ""
echo "==> Image verification policy ($POLICY_SECRET secret)"
if [[ -f "$VERIFY_TEMPLATE" ]]; then
  rendered="$(mktemp)"
  live="$(mktemp)"
  jq --arg repo "${IMAGE%%:*}" --arg tagged "$IMAGE" \
    '.transports.docker[$repo] = .transports.docker["__IMAGE_REF__"] |
     .transports.docker[$tagged] = .transports.docker["__IMAGE_REF__"] |
     del(.transports.docker["__IMAGE_REF__"])' \
    "$VERIFY_TEMPLATE" >"$rendered"
  oc get secret "$POLICY_SECRET" -n "$TRUSTEE_NS" -o jsonpath='{.data.policy}' 2>/dev/null \
    | base64 -d >"$live" 2>/dev/null || true
  if [[ ! -s "$live" ]]; then
    log_warn "live image policy secret empty or missing"
  elif diff -q <(jq -S . "$rendered") <(jq -S . "$live") >/dev/null 2>&1; then
    log_ok "live image policy matches git template for IMAGE=$IMAGE"
  else
    msg="live image policy differs from git template (IMAGE=$IMAGE)"
    if [[ "$ALLOW_DRIFT" -eq 1 ]]; then log_warn "$msg"; else log_fail "$msg"; fi
  fi
  rm -f "$rendered" "$live"
else
  log_warn "verification template not found: $VERIFY_TEMPLATE"
fi

summary_exit "$STRICT"
