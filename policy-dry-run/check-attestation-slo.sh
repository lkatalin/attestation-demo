#!/usr/bin/env bash
# Attestation SLO / observability contract — expected Trustee patterns and optional log scrape.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
load_repo_defaults

STRICT=0
SCRAPE_LOGS=0
TAIL="${TAIL:-200}"
PATTERNS="$ROOT/fixtures/expected-trustee-log-patterns.txt"

usage() {
  cat <<EOF
Usage: $0 [options]

  --scrape-logs         grep recent trustee-deployment logs for expected patterns (oc login)
  --tail N              Log lines to scan (default: 200)
  --strict
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scrape-logs) SCRAPE_LOGS=1; shift ;;
    --tail) TAIL="$2"; shift 2 ;;
    --strict) STRICT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 2 ;;
  esac
done

reset_counters
echo "==> Attestation observability contract"
echo ""

if [[ -f "$PATTERNS" ]]; then
  log_ok "expected log patterns file present"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    log_info "expect: $line"
  done <"$PATTERNS"
else
  log_warn "missing $PATTERNS"
fi

if [[ -f "$REPO_ROOT/scripts/kbs/measure-attestation-behavior.sh" ]]; then
  log_ok "measure-attestation-behavior.sh available for live matrix"
else
  log_warn "measure-attestation-behavior.sh not found"
fi

echo ""
echo "==> Recommended alerts (configure in your observability stack)"
alerts=(
  "Trustee DEK GET 401 rate > 0 on confidential namespace restarts"
  "Trustee verify tee=Sample on DEK resource path (baseline leak or wrong runtime)"
  "Trustee endorsement failures (RVPS/initdata drift)"
  "Confidential pod CrashLoop after image pull 200 (runtime DEK path)"
)
for a in "${alerts[@]}"; do
  log_info "alert: $a"
done

if [[ "$SCRAPE_LOGS" -eq 1 ]]; then
  echo ""
  echo "==> Trustee log scrape (last $TAIL lines)"
  if ! oc_available; then
    log_fail "--scrape-logs requires oc login"
  else
    logs="$(oc logs -n "$TRUSTEE_NS" deployment/trustee-deployment --tail="$TAIL" 2>/dev/null || true)"
    if [[ -z "$logs" ]]; then
      log_warn "no trustee logs retrieved"
    else
      while IFS= read -r pat || [[ -n "$pat" ]]; do
        [[ -z "$pat" || "$pat" =~ ^# ]] && continue
        if grep -qE "$pat" <<<"$logs"; then
          log_ok "log matches /$pat/"
        else
          log_warn "pattern not seen in recent logs: $pat"
        fi
      done <"$PATTERNS"
      if grep -q 'PolicyDeny' <<<"$logs" && grep -q 'confidential-inferencing-dek' <<<"$logs"; then
        log_warn "PolicyDeny on DEK path in recent logs"
      fi
      if grep -q 'Verifier/endorsement check passed. tee=AzSnpVtpm' <<<"$logs"; then
        log_ok "recent SNP endorsement success in logs"
      fi
    fi
  fi
fi

summary_exit "$STRICT"
