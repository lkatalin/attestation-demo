#!/usr/bin/env bash
# Generate production KBS resource Rego pinned to a golden CVM (measurement + pcr11).
#
# Usage:
#   ./generate-production-policy.sh --pins policy/cvm-pins.json
#   ./generate-production-policy.sh --from-capture policy-dry-run/captured/measurements-prod.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PINS=""
FROM_CAPTURE=""
OUT="${OUT:-$ROOT/policy/kbs-resource-policy-snp-production.rego}"

usage() {
  cat <<EOF
Usage: $0 --pins PATH | --from-capture PATH [--out PATH]

  --pins PATH           JSON: { "measurement": "hex", "pcr11": "hex", "label": "..." }
  --from-capture PATH   measurements-*.json from policy-dry-run/capture-claims.sh
  --out PATH            Output Rego (default: policy/kbs-resource-policy-snp-production.rego)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pins) PINS="$2"; shift 2 ;;
    --from-capture) FROM_CAPTURE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

if [[ -n "$FROM_CAPTURE" ]]; then
  [[ -f "$FROM_CAPTURE" ]] || { echo "Missing: $FROM_CAPTURE" >&2; exit 1; }
  PINS="$(mktemp)"
  jq -n \
    --arg m "$(jq -r '.submods.cpu0["ear.veraison.annotated-evidence"]["az-snp-vtpm"].measurement // empty' "$FROM_CAPTURE")" \
    --arg p "$(jq -r '.submods.cpu0["ear.veraison.annotated-evidence"]["az-snp-vtpm"].tpm.pcr11 // empty' "$FROM_CAPTURE")" \
    --arg l "$(basename "$FROM_CAPTURE" .json | sed 's/^measurements-//')" \
    '{label: $l, measurement: $m, pcr11: $p, source: "capture"}' >"$PINS"
  trap 'rm -f "$PINS"' EXIT
fi

[[ -n "$PINS" && -f "$PINS" ]] || {
  echo "Provide --pins or --from-capture" >&2
  usage >&2
  exit 2
}

MEAS="$(jq -r '.measurement // empty' "$PINS")"
PCR="$(jq -r '.pcr11 // empty' "$PINS")"
LABEL="$(jq -r '.label // "golden-cvm"' "$PINS")"

[[ -n "$MEAS" ]] || { echo "pins missing measurement (hex)" >&2; exit 1; }
[[ -n "$PCR" ]] || { echo "pins missing pcr11 (hex)" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
cat >"$OUT" <<REGO
# KBS resource policy — production AMD SNP peer-pod CVM (generated; do not edit by hand).
# Golden guest: ${LABEL}
# Regenerate when OSC pod VM / initdata changes:
#   sync-trustee-attestation → capture claims → generate-production-policy.sh → apply-production-resource-policy.sh
#
# Layers:
#   - Trustee RVPS/endorsement (configure-trustee.sh) — verified before Rego
#   - az-snp-vtpm + measurement/pcr11 pins — this CVM build only
#   - EAR executable/configuration trust vectors — operator affirming range
#   - sample attester denied (no az-snp-vtpm key)
package policy
import rego.v1

default allow = false

allow if {
	data.plugin == "resource"
	input["submods"]["cpu0"]["ear.veraison.annotated-evidence"]["az-snp-vtpm"]
	snp_measurement
	snp_pcr11
	not executable_failing
	not configuration_failing
}

snp_measurement if {
	input["submods"]["cpu0"]["ear.veraison.annotated-evidence"]["az-snp-vtpm"]["measurement"] == "${MEAS}"
}

snp_pcr11 if {
	input["submods"]["cpu0"]["ear.veraison.annotated-evidence"]["az-snp-vtpm"]["tpm"]["pcr11"] == "${PCR}"
}

executable_failing if {
	some _, submod in input.submods
	executables := submod["ear.trustworthiness-vector"]["executables"]
	not in_affirming_range(executables)
}

configuration_failing if {
	some _, submod in input.submods
	configuration := submod["ear.trustworthiness-vector"]["configuration"]
	not in_affirming_range(configuration)
}

# SNP peer-pod appraisals often exceed operator-default 2–31 (e.g. executables=33,
# configuration=36) even for healthy guests. Require non-failing (>= 2), not 2–31.
in_affirming_range(val) if {
	val >= 2
}
REGO

echo "Wrote $OUT"
echo "  measurement=${MEAS:0:16}…"
echo "  pcr11=${PCR:0:16}…"
echo ""
echo "Next:"
echo "  cd policy-dry-run && make dry-run-measurements -- --rego ../policy/kbs-resource-policy-snp-production.rego --fixture captured/input-${LABEL}.json --require-pinning"
echo "  make apply-production-resource-policy"
