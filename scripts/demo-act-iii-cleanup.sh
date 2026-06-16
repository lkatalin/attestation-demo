#!/usr/bin/env bash
# Restore Act II production Rego, remove Act III extra replica / canary deployment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=defaults.sh
source "$SCRIPT_DIR/defaults.sh"

NS="${DEMO_NAMESPACE}"
MISMATCH_DEPLOY="inference-confidential-act-iii"
POLICY_BACKUP="${ARTIFACTS}/act-iii-production.rego.backup"

oc whoami >/dev/null || { echo "oc login required" >&2; exit 1; }

if oc get deployment "$MISMATCH_DEPLOY" -n "$NS" >/dev/null 2>&1; then
  echo "==> Delete legacy Act III canary deployment: $MISMATCH_DEPLOY"
  oc delete deployment "$MISMATCH_DEPLOY" -n "$NS" --wait=false
fi

ORIGINAL_REPLICAS="${ARTIFACTS}/act-iii-original-replicas"
if [[ -f "$ORIGINAL_REPLICAS" ]]; then
  echo "==> Scale golden deployment back to $(cat "$ORIGINAL_REPLICAS")"
  oc scale deployment inference-confidential -n "$NS" --replicas="$(cat "$ORIGINAL_REPLICAS")"
  NEWEST="$(oc get pods -n "$NS" -l demo-role=confidential \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)"
  [[ -n "$NEWEST" ]] && oc delete pod -n "$NS" "$NEWEST" --wait=false 2>/dev/null || true
  rm -f "$ORIGINAL_REPLICAS"
fi

if [[ -f "$POLICY_BACKUP" ]]; then
  echo "==> Restore Act II production Rego on KBS"
  POLICY_FILE="$POLICY_BACKUP" bash "$SCRIPT_DIR/kbs/apply-production-resource-policy.sh"
  rm -f "$POLICY_BACKUP"
else
  echo "==> No policy backup — re-promote from golden pins"
  make -C "$ROOT" promote-production-policy
fi

GOLDEN_BACKUP="${ARTIFACTS}/act-iii-initdata/golden-initdata.toml"
if [[ -f "$GOLDEN_BACKUP" ]]; then
  cluster_sha="$(oc get configmap peer-pods-cm -n openshift-sandboxed-containers-operator \
    -o jsonpath='{.data.INITDATA}' 2>/dev/null | base64 -d | gunzip | sha256sum | awk '{print $1}' || true)"
  golden_sha="$(sha256sum "$GOLDEN_BACKUP" | awk '{print $1}')"
  if [[ -n "$cluster_sha" && "$cluster_sha" != "$golden_sha" ]]; then
    echo "==> Restore peer-pods INITDATA to golden baseline"
    INITDATA_PATH="$GOLDEN_BACKUP" bash "$SCRIPT_DIR/kbs/apply-peer-pods-initdata.sh"
  fi
fi

echo "Done. Watch: oc get pods -n $NS -l demo-role=confidential"
