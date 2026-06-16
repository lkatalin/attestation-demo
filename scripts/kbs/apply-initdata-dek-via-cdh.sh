#!/usr/bin/env bash
# Patch initdata with CDH DEK credential, apply to peer-pods-cm, restart confidential workload.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../defaults.sh
source "$SCRIPT_DIR/../defaults.sh"

COCO_ARO="${COCO_ARO:-$ROOT/../coco-infra/aro}"
PEER_NS=openshift-sandboxed-containers-operator
CM=peer-pods-cm
WORKDIR="${ARTIFACTS}/initdata-work"
PATCHED="$WORKDIR/initdata-with-dek-credential.toml"

oc whoami >/dev/null || { echo "oc login required" >&2; exit 1; }

mkdir -p "$WORKDIR"
SRC=""

if [[ -n "${INITDATA_PATH:-}" && -f "$INITDATA_PATH" ]]; then
  SRC="$INITDATA_PATH"
elif [[ -f "$COCO_ARO/trustee/initdata.toml" ]]; then
  SRC="$COCO_ARO/trustee/initdata.toml"
elif [[ -f "$OPERATOR_BUNDLE/initdata.toml" ]]; then
  SRC="$OPERATOR_BUNDLE/initdata.toml"
else
  echo "==> Decoding INITDATA from cluster $CM"
  INITDATA_B64="$(oc get configmap "$CM" -n "$PEER_NS" -o jsonpath='{.data.INITDATA}')"
  [[ -n "$INITDATA_B64" ]] || { echo "No INITDATA in $CM and no local initdata.toml" >&2; exit 1; }
  printf '%s' "$INITDATA_B64" | base64 -d | gunzip >"$WORKDIR/initdata-from-cluster.toml"
  SRC="$WORKDIR/initdata-from-cluster.toml"
fi

echo "==> Patch initdata from $SRC"
bash "$SCRIPT_DIR/patch-initdata-cdh-dek.sh" "$SRC" "$PATCHED"

oc get configmap "$CM" -n "$PEER_NS" >/dev/null || {
  echo "Missing $CM — install/configure OSC on this cluster first" >&2
  exit 1
}

INITDATA_B64="$(gzip -c "$PATCHED" | base64 | tr -d '\n')"
oc patch configmap "$CM" -n "$PEER_NS" --type merge \
  -p "{\"data\":{\"INITDATA\":\"${INITDATA_B64}\"}}"

echo "==> Updated $CM INITDATA (CDH prefetches DEK at guest boot)"
echo "    credential: /run/confidential-containers/cdh/kbs/${KBS_RESOURCE_PATH}"
