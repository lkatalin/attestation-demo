#!/usr/bin/env bash
# Deploy a second confidential workload with mismatch initdata via pod annotation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../defaults.sh
source "$SCRIPT_DIR/../defaults.sh"

NS="${DEMO_NAMESPACE}"
MISMATCH_B64="${ARTIFACTS}/act-iii-initdata/mismatch-initdata.b64"
DEPLOY_NAME="inference-confidential-act-iii"
INITDATA_ANNOTATION="${ACT_III_INITDATA_ANNOTATION:-io.katacontainers.config.runtime.cc_init_data}"

[[ -f "$MISMATCH_B64" ]] || {
  echo "Missing $MISMATCH_B64 — run inject-act-iii-initdata-mismatch.sh first" >&2
  exit 1
}

# shellcheck source=/dev/null
[[ -f "$ROOT/deploy/kbs.env" ]] && source "$ROOT/deploy/kbs.env"
export IMAGE KBS_URL KBS_RESOURCE_PATH INITDATA_ANNOTATION DEPLOY_NAME
export INITDATA_B64="$(tr -d '\n' <"$MISMATCH_B64")"
[[ -n "$INITDATA_B64" ]] || { echo "Empty mismatch initdata b64" >&2; exit 1; }

envsubst '${IMAGE} ${KBS_URL} ${KBS_RESOURCE_PATH} ${INITDATA_B64} ${INITDATA_ANNOTATION} ${DEPLOY_NAME}' \
  <"$ROOT/deploy/deployment-confidential-act-iii.yaml" \
  | oc apply -f -

echo "==> Wait for mismatch deployment rollout"
oc rollout status "deployment/$DEPLOY_NAME" -n "$NS" --timeout=1800s
