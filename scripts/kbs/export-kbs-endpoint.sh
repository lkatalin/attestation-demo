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

if [[ -n "${OPERATOR_INITDATA_PATH:-}" && -f "$OPERATOR_INITDATA_PATH" ]]; then
  cp -f "$OPERATOR_INITDATA_PATH" "$OUT_DIR/initdata.toml"
elif [[ -f "$ROOT/../coco-infra/aro/trustee/initdata.toml" ]]; then
  cp -f "$ROOT/../coco-infra/aro/trustee/initdata.toml" "$OUT_DIR/initdata.toml"
fi

echo "KBS endpoint files in $OUT_DIR:"
ls -la "$OUT_DIR/kbs.url" "$OUT_DIR/kbs-ca.pem" "$OUT_DIR/kbs-resource-path.txt"
[[ -f "$OUT_DIR/initdata.toml" ]] && echo "  initdata.toml (share with model owner for peer-pods)"
