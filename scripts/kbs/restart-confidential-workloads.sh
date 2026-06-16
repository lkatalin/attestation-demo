#!/usr/bin/env bash
# Request confidential workload pod restart (non-blocking by default).
#
# Peer-pod / CVM teardown can take 15–30+ minutes; oc delete --wait=true hangs scripts.
#
# Usage:
#   bash scripts/kbs/restart-confidential-workloads.sh
#   POD_DELETE_WAIT=true bash scripts/kbs/restart-confidential-workloads.sh
#   FORCE_POD_DELETE=1 bash scripts/kbs/restart-confidential-workloads.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../defaults.sh
source "$SCRIPT_DIR/../defaults.sh"

NS="${DEMO_NAMESPACE}"
WAIT="${POD_DELETE_WAIT:-false}"
FORCE="${FORCE_POD_DELETE:-0}"
RESTART_BASELINE="${RESTART_BASELINE:-0}"

oc whoami >/dev/null || { echo "oc login required" >&2; exit 1; }

delete_pods() {
  local label="$1"
  local extra=()
  [[ "$FORCE" == "1" ]] && extra+=(--force --grace-period=0)
  [[ "$WAIT" == "true" ]] && extra+=(--wait=true) || extra+=(--wait=false)

  if ! oc get deployment inference-confidential -n "$NS" >/dev/null 2>&1; then
    echo "No inference-confidential deployment in $NS — skipping pod restart"
    return 0
  fi

  oc scale deployment inference-confidential -n "$NS" --replicas=1 2>/dev/null || true
  oc delete pod -n "$NS" -l "$label" --ignore-not-found "${extra[@]}"
}

echo "==> Restart confidential workload pods (namespace=$NS wait=$WAIT force=$FORCE)"
delete_pods "demo-role=confidential"

if [[ "$RESTART_BASELINE" == "1" ]]; then
  delete_pods "demo-role=baseline-encrypted-fail"
fi

if [[ "$WAIT" != "true" ]]; then
  echo ""
  echo "Delete sent (--wait=false). Peer-pod CVM teardown runs in the background and may take 15–30+ min."
  echo "  oc get pods -n $NS -l demo-role=confidential -w"
  echo "  oc describe pod -n $NS -l demo-role=confidential | tail -20   # if stuck Terminating"
  echo ""
  echo "Stuck Terminating? FORCE_POD_DELETE=1 bash scripts/kbs/restart-confidential-workloads.sh"
else
  echo "Pods removed (waited for delete to complete)."
fi
