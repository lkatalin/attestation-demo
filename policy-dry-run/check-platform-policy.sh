#!/usr/bin/env bash
# OpenShift / platform conformance for confidential inference deployments.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
load_repo_defaults

STRICT=0
DEPLOY_DIR="${DEPLOY_DIR:-$REPO_ROOT/deploy}"

usage() {
  echo "Usage: $0 [--deploy-dir PATH] [--strict]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deploy-dir) DEPLOY_DIR="$2"; shift 2 ;;
    --strict) STRICT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 2 ;;
  esac
done

reset_counters
echo "==> Platform / OpenShift conformance"
echo "Deploy dir: $DEPLOY_DIR"
echo ""

conf="$DEPLOY_DIR/deployment-confidential.yaml"
if [[ ! -f "$conf" ]]; then
  log_fail "missing $conf"
  summary_exit "$STRICT"
  exit 1
fi

if grep -q 'serviceAccountName:' "$conf"; then
  sa="$(grep 'serviceAccountName:' "$conf" | awk '{print $2}')"
  if [[ "$sa" == "default" ]]; then
    log_warn "serviceAccountName: default — production should use dedicated SA"
  else
    log_ok "dedicated serviceAccountName: $sa"
  fi
else
  log_warn "no serviceAccountName — pod uses namespace default SA"
fi

if grep -q 'runtimeClassName: kata-remote' "$conf"; then
  log_ok "runtimeClassName: kata-remote"
else
  log_fail "missing runtimeClassName: kata-remote on confidential deployment"
fi

for yaml in "$DEPLOY_DIR"/deployment-*.yaml; do
  [[ -f "$yaml" ]] || continue
  base="$(basename "$yaml")"
  if grep -q 'privileged: true' "$yaml" || grep -q 'allowPrivilegeEscalation: true' "$yaml"; then
    log_fail "$base allows privileged escalation"
  fi
  if grep -q 'hostPath:' "$yaml"; then
    if grep -q 'confidential-containers' "$yaml"; then
      log_fail "$base hostPath on confidential-containers paths"
    else
      log_warn "$base uses hostPath (review for production)"
    fi
  fi
done
log_ok "hostPath / privileged scan complete"

if grep -q 'imagePullSecrets:' "$conf"; then
  log_ok "imagePullSecrets configured"
else
  log_warn "no imagePullSecrets — private registry pulls may fail"
fi

if oc_available; then
  echo ""
  echo "==> Cluster SCC / runtime (optional)"
  if oc get runtimeclass kata-remote >/dev/null 2>&1; then
    log_ok "RuntimeClass kata-remote exists"
  else
    log_fail "RuntimeClass kata-remote missing"
  fi
  if oc get scc sandboxed-containers-operator-scc >/dev/null 2>&1; then
    log_ok "SCC sandboxed-containers-operator-scc present"
  else
    log_warn "SCC sandboxed-containers-operator-scc not found (non-OSC cluster?)"
  fi
  ns="$DEMO_NAMESPACE"
  if oc get rolebinding -n "$ns" 2>/dev/null | grep -q 'sandboxed-containers-operator-scc'; then
    log_ok "namespace $ns has sandboxed-containers SCC binding"
  else
    log_warn "no sandboxed-containers SCC RoleBinding in $ns — kata-remote pods may fail SCC"
  fi
else
  log_info "oc not logged in — skipping cluster SCC checks"
fi

summary_exit "$STRICT"
