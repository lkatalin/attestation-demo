#!/usr/bin/env bash
# Fix KBS PolicyDeny on trustee-image-policy after peer-pod attest succeeds.
# Rebuilds RVPS + initdata from the OSC podvm image, reapplies peer-pods INITDATA, restarts Trustee.
#
# Pod restart at the end uses --wait=false (peer-pod CVM delete can take 15–30+ min).
#   SKIP_POD_RESTART=1 make sync-trustee-attestation   # RVPS/initdata only
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COCO_ARO="${COCO_ARO:-$ROOT/../coco-infra/aro}"
INITDATA_PATH="${INITDATA_PATH:-$COCO_ARO/trustee/initdata.toml}"

oc whoami >/dev/null || { echo "oc login required" >&2; exit 1; }

[[ -d "$COCO_ARO" ]] || {
  echo "coco-infra not found at $COCO_ARO — set COCO_ARO=" >&2
  exit 1
}

echo "==> Re-run configure-trustee (RVPS reference values + initdata.toml)"
TRUSTEE_ENV=gen bash "$COCO_ARO/configure-trustee.sh"

echo "==> Ensure CDH DEK credential in initdata (idempotent)"
bash "$SCRIPT_DIR/patch-initdata-cdh-dek.sh" "$INITDATA_PATH" "$INITDATA_PATH"

echo "==> Wait for Trustee rollout"
oc rollout status deployment/trustee-deployment -n trustee-operator-system --timeout=300s

echo "==> Re-apply peer-pods INITDATA from $INITDATA_PATH"
INITDATA_PATH="$INITDATA_PATH" bash "$SCRIPT_DIR/apply-peer-pods-initdata.sh"

echo "==> Re-apply inference image policy + DEK (idempotent)"
bash "$ROOT/scripts/kbs/register-policy.sh"
bash "$ROOT/scripts/kbs/register-dek.sh"

if [[ "${SKIP_POD_RESTART:-0}" == "1" ]]; then
  echo "==> Skipping pod restart (SKIP_POD_RESTART=1). New initdata applies on next pod create."
  echo "  bash scripts/kbs/restart-confidential-workloads.sh"
else
  echo "==> Restart confidential demo pods (non-blocking — peer-pod delete can take 15–30+ min)"
  bash "$SCRIPT_DIR/restart-confidential-workloads.sh"
fi

echo ""
echo "Done. Watch Trustee for GET .../trustee-image-policy/policy HTTP/1.1 200 (not 401 PolicyDeny):"
echo "  oc logs -n trustee-operator-system deployment/trustee-deployment -f | grep trustee-image-policy"
