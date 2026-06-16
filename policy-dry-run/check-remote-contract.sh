#!/usr/bin/env bash
# Cross-cluster / handoff contract: KBS bundle, deployment env, TLS expiry, optional probe.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
load_repo_defaults

BUNDLE=""
PROBE_KBS=0
STRICT=0
MIN_CERT_DAYS="${MIN_CERT_DAYS:-30}"

usage() {
  cat <<EOF
Usage: $0 [BUNDLE_DIR] [options]

  BUNDLE_DIR            kbs-tee-attestation/output or operator-bundle
  --probe-kbs           curl KBS /health from this host
  --min-cert-days N     Warn if kbs-ca.pem expires within N days (default: 30)
  --strict
  -h, --help

Also runs check-handoff.sh when bundle path is set.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --probe-kbs) PROBE_KBS=1; shift ;;
    --min-cert-days) MIN_CERT_DAYS="$2"; shift 2 ;;
    --strict) STRICT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) [[ -z "$BUNDLE" ]] && BUNDLE="$1" || { echo "Unexpected: $1" >&2; exit 2; }; shift ;;
  esac
done

[[ -z "$BUNDLE" ]] && BUNDLE="$REPO_ROOT/kbs-tee-attestation/output"

reset_counters
echo "==> Remote KBS contract verification"
echo ""

if [[ -d "$BUNDLE" || -f "$BUNDLE/kbs.url" ]]; then
  if bash "$ROOT/check-handoff.sh" "$BUNDLE"; then
    log_ok "check-handoff.sh passed"
  else
    log_fail "check-handoff.sh reported errors"
  fi
else
  log_warn "bundle not found at $BUNDLE — skipping handoff checks"
fi

echo ""
echo "==> Inference deployment alignment"

deploy_env="$REPO_ROOT/deploy/kbs.env"
dep="$REPO_ROOT/deploy/deployment-confidential.yaml"
kbs_url=""
[[ -f "$BUNDLE/kbs.url" ]] && kbs_url="$(tr -d '\n' <"$BUNDLE/kbs.url")"
[[ -z "$kbs_url" && -f "$deploy_env" ]] && kbs_url="$(grep '^KBS_URL=' "$deploy_env" | head -1 | cut -d= -f2-)"

if [[ -f "$deploy_env" && -n "$kbs_url" ]]; then
  dep_url="$(grep '^KBS_URL=' "$deploy_env" | head -1 | cut -d= -f2-)"
  if [[ "$(url_host "$(normalize_url "$dep_url")")" == "$(url_host "$(normalize_url "$kbs_url")")" ]]; then
    log_ok "deploy/kbs.env KBS_URL matches bundle kbs.url"
  else
    log_fail "deploy/kbs.env host differs from bundle kbs.url"
  fi
fi

if [[ -f "$dep" && -n "$kbs_url" ]]; then
  if grep -qF '${KBS_URL}' "$dep"; then
    log_ok "deployment uses KBS_URL substitution (envsubst at apply time)"
  fi
  if grep -qF '${KBS_RESOURCE_PATH}' "$dep"; then
    log_ok "deployment uses KBS_RESOURCE_PATH substitution"
  fi
fi

resource_path=""
[[ -f "$BUNDLE/kbs-resource-path.txt" ]] && resource_path="$(tr -d '\n' <"$BUNDLE/kbs-resource-path.txt")"
[[ -z "$resource_path" ]] && resource_path="$KBS_RESOURCE_PATH"
if grep -qF "$resource_path" "$dep" 2>/dev/null || grep -q "$resource_path" "$deploy_env" 2>/dev/null; then
  log_ok "DEK resource path consistent ($resource_path)"
else
  log_warn "could not confirm DEK path $resource_path in deployment/kbs.env"
fi

echo ""
echo "==> TLS certificate lifecycle"
ca="$BUNDLE/kbs-ca.pem"
[[ -f "$ca" ]] || ca="$REPO_ROOT/kbs-tee-attestation/output/kbs-ca.pem"
if [[ -f "$ca" ]]; then
  days="$(cert_days_until_expiry "$ca")"
  if [[ "$days" -lt 0 ]]; then
    log_warn "could not parse kbs-ca.pem expiry"
  elif [[ "$days" -lt "$MIN_CERT_DAYS" ]]; then
    log_fail "kbs-ca.pem expires in $days days (< $MIN_CERT_DAYS)"
  else
    log_ok "kbs-ca.pem valid for ~$days days"
  fi
else
  log_warn "kbs-ca.pem not found for expiry check"
fi

if [[ "$PROBE_KBS" -eq 1 && -n "$kbs_url" ]]; then
  echo ""
  echo "==> KBS reachability probe"
  if curl -sk --connect-timeout 8 "${kbs_url%/}/kbs/v0/health" -o /dev/null; then
    log_ok "KBS health reachable from this host"
  else
    log_warn "KBS health not reachable from this host (guest egress may still work)"
  fi
fi

if oc_available; then
  echo ""
  echo "==> Trustee remote attestation prerequisites"
  if oc get kbsconfig trusteeconfig-kbs-config -n "$TRUSTEE_NS" >/dev/null 2>&1; then
    log_ok "KbsConfig present in $TRUSTEE_NS"
  else
    log_warn "KbsConfig not found — remote attestation may be incomplete"
  fi
  tc="$(oc get trusteeconfig trusteeconfig -n "$TRUSTEE_NS" -o json 2>/dev/null || echo '{}')"
  if echo "$tc" | jq -e '.spec.attestationTokenVerificationSpec' >/dev/null 2>&1; then
    log_ok "TrusteeConfig attestationTokenVerificationSpec set"
  else
    log_warn "TrusteeConfig missing attestationTokenVerificationSpec — run ensure-remote-attestation"
  fi
fi

summary_exit "$STRICT"
