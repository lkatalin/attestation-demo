#!/usr/bin/env bash
# End-to-end: RVPS sync → capture golden CVM → generate → dry-run → apply production Rego.
#
# Prerequisites:
#   - oc logged in (same cluster or KBS cluster for apply; inference for RVPS sync)
#   - ../coco-infra for configure-trustee (RVPS from OSC verity image)
#   - One attestation JWT or claims JSON from a known-good AzSnpVtpm guest
#
# Usage:
#   # Full RVPS refresh + apply pins from file:
#   PINS=policy/cvm-pins.json bash scripts/kbs/bootstrap-production-policy.sh
#
#   # Skip RVPS (pins only):
#   SKIP_RVPS=1 PINS=policy/cvm-pins.json bash scripts/kbs/bootstrap-production-policy.sh
#
#   # Capture then bootstrap:
#   bash scripts/kbs/bootstrap-production-policy.sh --capture policy-dry-run/captured/input-golden.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PINS="${PINS:-$ROOT/policy/cvm-pins.json}"
CAPTURE_INPUT=""
SKIP_RVPS="${SKIP_RVPS:-0}"
TEMP_DEMO="${TEMP_DEMO:-0}"

usage() {
  cat <<EOF
Usage: $0 [options]

  --capture PATH     claims/input JSON → capture-claims → generate → apply
  --pins PATH        cvm-pins.json (default: policy/cvm-pins.json)
  --skip-rvps        skip sync-trustee-attestation
  --temp-demo        if capture missing, apply demo policy first (bootstrap only)
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --capture) CAPTURE_INPUT="$2"; shift 2 ;;
    --pins) PINS="$2"; shift 2 ;;
    --skip-rvps) SKIP_RVPS=1; shift ;;
    --temp-demo) TEMP_DEMO=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 2 ;;
  esac
done

oc whoami >/dev/null || { echo "oc login required" >&2; exit 1; }

if [[ "$SKIP_RVPS" != "1" ]]; then
  echo "==> Step 1: Sync RVPS + initdata from OSC pod VM image (configure-trustee)"
  bash "$SCRIPT_DIR/sync-trustee-attestation.sh"
else
  echo "==> Step 1: skipped (--skip-rvps)"
fi

if [[ -n "$CAPTURE_INPUT" ]]; then
  echo "==> Step 2: Capture pins from $CAPTURE_INPUT"
  LABEL="${CAPTURE_LABEL:-golden-cvm}"
  bash "$ROOT/policy-dry-run/capture-claims.sh" --from "$CAPTURE_INPUT" --label "$LABEL"
  bash "$SCRIPT_DIR/generate-production-policy.sh" \
    --from-capture "$ROOT/policy-dry-run/captured/measurements-${LABEL}.json"
elif [[ -f "$PINS" ]]; then
  echo "==> Step 2: Generate from $PINS"
  bash "$SCRIPT_DIR/generate-production-policy.sh" --pins "$PINS"
else
  echo "==> Step 2: No pins file and no --capture"
  if [[ "$TEMP_DEMO" == "1" ]]; then
    echo "    Applying demo policy temporarily so guest can complete one attest cycle…"
    bash "$SCRIPT_DIR/relax-resource-policy-snp.sh"
    echo ""
    echo "    After confidential pod attests with tee=AzSnpVtpm, save JWT/claims and re-run:"
    echo "      $0 --capture /path/to/claims.json"
    exit 0
  fi
  cat <<EOF >&2
Missing golden CVM pins. After wide SNP policy allows one good attest:

  make enable-peer-pods-guest-rest-api
  make capture-golden-claims
  $0 --pins policy-dry-run/captured/cvm-pins-golden.json

Or bootstrap with demo policy once: $0 --temp-demo
EOF
  exit 2
fi

echo "==> Step 3: Dry-run measurement policy"
LABEL="${CAPTURE_LABEL:-golden-cvm}"
FIXTURE="$ROOT/policy-dry-run/captured/input-${LABEL}.json"
DRY_ARGS=(--rego "$ROOT/policy/kbs-resource-policy-snp-production.rego" --require-pinning)
[[ -f "$FIXTURE" ]] && DRY_ARGS+=(--fixture "$FIXTURE")
bash "$ROOT/policy-dry-run/dry-run-measurements.sh" "${DRY_ARGS[@]}"

echo "==> Step 4: Apply production policy on KBS"
bash "$SCRIPT_DIR/apply-production-resource-policy.sh"

echo ""
echo "Done. On inference cluster — Act II re-attest under pins:"
echo "  make demo-act-ii"
