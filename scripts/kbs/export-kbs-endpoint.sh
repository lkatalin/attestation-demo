#!/usr/bin/env bash
# Export KBS URL + CA cert for the model owner (run on operator / KBS cluster).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../defaults.sh
source "$SCRIPT_DIR/../defaults.sh"

OUT_DIR="${KBS_ENDPOINT_DIR:-$OPERATOR_BUNDLE}"
NS="${TRUSTEE_NS}"

oc whoami >/dev/null || { echo "oc login required (KBS cluster)" >&2; exit 1; }

mkdir -p "$OUT_DIR"
KBS_HOST="$(oc get route kbs-service -n "$NS" -o jsonpath='{.spec.host}')"
KBS_URL="https://${KBS_HOST}"

printf '%s\n' "$KBS_URL" >"$OUT_DIR/kbs.url"
oc get secret trustee-tls-cert -n "$NS" -o jsonpath='{.data.tls\.crt}' | base64 -d >"$OUT_DIR/kbs-ca.pem"
printf '%s\n' "$KBS_RESOURCE_PATH" >"$OUT_DIR/kbs-resource-path.txt"

PEER_NS=openshift-sandboxed-containers-operator
INITDATA_B64="$(oc get configmap peer-pods-cm -n "$PEER_NS" -o jsonpath='{.data.INITDATA}' 2>/dev/null || true)"
if [[ -n "$INITDATA_B64" ]]; then
  echo "$INITDATA_B64" | base64 -d | gunzip > "$OUT_DIR/initdata.toml"
else
  echo "WARNING: no INITDATA in peer-pods-cm — skipping initdata.toml export" >&2
fi

echo "KBS endpoint files in $OUT_DIR:"
ls -la "$OUT_DIR/kbs.url" "$OUT_DIR/kbs-ca.pem" "$OUT_DIR/kbs-resource-path.txt"
[[ -f "$OUT_DIR/initdata.toml" ]] && echo "  initdata.toml (share with model owner for peer-pods)"
