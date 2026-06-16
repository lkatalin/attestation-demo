#!/usr/bin/env bash
# Patch peer-pods-cm INITDATA from operator initdata.toml (remote KBS / cross-cluster).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../defaults.sh
source "$SCRIPT_DIR/../defaults.sh"

INITDATA_PATH="${INITDATA_PATH:-}"
PEER_NS=openshift-sandboxed-containers-operator
CM=peer-pods-cm

[[ -n "$INITDATA_PATH" && -f "$INITDATA_PATH" ]] || {
  echo "Set INITDATA_PATH to operator initdata.toml (e.g. \$OPERATOR_BUNDLE/initdata.toml)" >&2
  exit 1
}

oc whoami >/dev/null || { echo "oc login required (inference cluster)" >&2; exit 1; }
oc get configmap "$CM" -n "$PEER_NS" >/dev/null || {
  echo "Missing $CM — install/configure OSC on this cluster first" >&2
  exit 1
}

INITDATA_B64="$(gzip -c "$INITDATA_PATH" | base64 | tr -d '\n')"
oc patch configmap "$CM" -n "$PEER_NS" --type merge \
  -p "{\"data\":{\"INITDATA\":\"${INITDATA_B64}\"}}"

echo "Updated $CM INITDATA from $INITDATA_PATH"
echo "Restart confidential workloads so new peer pods pick up initdata:"
echo "  oc delete pod -n $DEMO_NAMESPACE -l app=inference-confidential"
