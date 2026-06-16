#!/usr/bin/env bash
# Key / cert rotation readiness tabletop (offline artifact checks + runbook hints).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
load_repo_defaults

STRICT=0
MIN_CERT_DAYS="${MIN_CERT_DAYS:-90}"

usage() {
  echo "Usage: $0 [--strict] [--min-cert-days N]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict) STRICT=1; shift ;;
    --min-cert-days) MIN_CERT_DAYS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 2 ;;
  esac
done

reset_counters
echo "==> Rotation readiness tabletop"
echo ""

artifacts="$REPO_ROOT/artifacts"
bundle="$REPO_ROOT/kbs-tee-attestation/output"

check_file() {
  local path="$1" label="$2" required="${3:-1}"
  if [[ -f "$path" ]]; then
    log_ok "$label present"
    return 0
  fi
  if [[ "$required" -eq 1 ]]; then
    log_warn "missing $label ($path) — required for production rotation"
  else
    log_info "optional: $label not found ($path)"
  fi
  return 0
}

echo "==> Signing / DEK artifacts"
check_file "$artifacts/cosign.pub" "cosign public key"
check_file "$artifacts/cosign.key" "cosign private key (rotation source)" 0
check_file "$artifacts/dek.bin" "local DEK copy (for KBS register)" 0
check_file "$bundle/kbs-ca.pem" "KBS TLS CA (handoff)" 0
if [[ ! -f "$artifacts/cosign.pub" ]]; then
  log_warn "generate keys with: make setup-cosign (repo root)"
fi

echo ""
echo "==> Certificate expiry horizon"
for cert in "$bundle/kbs-ca.pem" "$REPO_ROOT/deploy/kbs-ca.pem"; do
  [[ -f "$cert" ]] || continue
  days="$(cert_days_until_expiry "$cert")"
  if [[ "$days" -ge 0 && "$days" -lt "$MIN_CERT_DAYS" ]]; then
    log_warn "$cert expires in ~$days days — plan KBS Route cert rotation"
  elif [[ "$days" -ge 0 ]]; then
    log_ok "$cert valid ~$days days"
  fi
done

echo ""
echo "==> Rotation runbook checkpoints (manual)"
steps=(
  "Register new cosign pub-key in KBS before retiring old key"
  "Sign new image digest with new key; keep legacy .sig tag for CDH"
  "Update verification-policy secret; rollout trustee-deployment"
  "Register new DEK in KBS; update Rego if path/version changes"
  "Regenerate initdata + RVPS after pod VM image change (configure-trustee.sh)"
  "Re-apply peer-pods-cm INITDATA; restart confidential workloads"
  "Verify Trustee logs: image policy GET 200, DEK GET 200, tee=AzSnpVtpm"
)
for s in "${steps[@]}"; do
  log_info "☐ $s"
done

if [[ -f "$REPO_ROOT/scripts/kbs/fix-image-sign.sh" ]]; then
  log_ok "fix-image-sign.sh available for cosign v2 .sig refresh"
else
  log_warn "fix-image-sign.sh not found"
fi

if [[ -f "$REPO_ROOT/scripts/kbs/sync-trustee-attestation.sh" ]]; then
  log_ok "sync-trustee-attestation.sh available for RVPS/initdata refresh"
else
  log_warn "sync-trustee-attestation.sh not found"
fi

summary_exit "$STRICT"
