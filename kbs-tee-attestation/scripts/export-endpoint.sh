#!/usr/bin/env bash
# Export KBS URL, CA, resource path, and initdata for the inference cluster operator.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=defaults.sh
source "$SCRIPT_DIR/defaults.sh"

OUT_DIR="${OUTPUT_DIR}"
NS="${TRUSTEE_NS}"

oc whoami >/dev/null || { echo "oc login required (KBS cluster)" >&2; exit 1; }

mkdir -p "$OUT_DIR"
KBS_HOST="$(oc get route "$ROUTE_NAME" -n "$NS" -o jsonpath='{.spec.host}')"
KBS_URL="https://${KBS_HOST}"

printf '%s\n' "$KBS_URL" >"$OUT_DIR/kbs.url"
oc get secret trustee-tls-cert -n "$NS" -o jsonpath='{.data.tls\.crt}' | base64 -d >"$OUT_DIR/kbs-ca.pem"
printf '%s\n' "$KBS_RESOURCE_PATH" >"$OUT_DIR/kbs-resource-path.txt"

if [[ -n "${INITDATA_PATH:-}" && -f "$INITDATA_PATH" ]]; then
  cp -f "$INITDATA_PATH" "$OUT_DIR/initdata.toml"
elif [[ -f "${COCO_ARO:-$REPO_ROOT/../coco-infra/aro}/trustee/initdata.toml" ]]; then
  cp -f "${COCO_ARO:-$REPO_ROOT/../coco-infra/aro}/trustee/initdata.toml" "$OUT_DIR/initdata.toml"
fi

echo "Endpoint bundle written to $OUT_DIR:"
ls -la "$OUT_DIR/kbs.url" "$OUT_DIR/kbs-ca.pem" "$OUT_DIR/kbs-resource-path.txt"
[[ -f "$OUT_DIR/initdata.toml" ]] && echo "  initdata.toml — give to inference cluster for peer-pods INITDATA"
