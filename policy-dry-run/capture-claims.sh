#!/usr/bin/env bash
# Extract attestation claim values for Rego fixtures and measurement pinning.
#
# Input can be:
#   - KBS/OPA "input" JSON (has submods)
#   - Full eval context { "input": {...}, "data": {...} }
#   - Raw JWT (three dot-separated segments)
#
# Usage:
#   ./capture-claims.sh --from claims.json --label snp-prod
#   ./capture-claims.sh --from-jwt token.jwt --label probe-1 --out-dir captured/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$ROOT/captured"
LABEL=""
FROM=""
FROM_JWT=""

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \?//'
  cat <<EOF

Options:
  --from PATH       Claims or eval-context JSON
  --from-jwt PATH   Attestation JWT file (payload decoded)
  --label NAME      Output basename (default: derived from --from)
  --out-dir PATH    Write fixture here (default: captured/)
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --from-jwt) FROM_JWT="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$FROM" || -n "$FROM_JWT" ]] || {
  echo "Provide --from or --from-jwt" >&2
  usage >&2
  exit 2
}

command -v python3 >/dev/null || { echo "python3 required" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }

mkdir -p "$OUT_DIR"

if [[ -n "$FROM_JWT" ]]; then
  [[ -f "$FROM_JWT" ]] || { echo "Missing JWT file: $FROM_JWT" >&2; exit 1; }
  TMP="$(mktemp)"
  python3 - "$FROM_JWT" >"$TMP" <<'PY'
import base64, json, sys

def b64url(data: str) -> bytes:
    pad = "=" * (-len(data) % 4)
    return base64.urlsafe_b64decode(data + pad)

raw = open(sys.argv[1], "r", encoding="utf-8").read().strip()
parts = raw.split(".")
if len(parts) < 2:
    raise SystemExit("JWT must have at least header.payload")
claims = json.loads(b64url(parts[1]))
json.dump(claims, sys.stdout, indent=2)
PY
  FROM="$TMP"
  trap 'rm -f "$TMP"' EXIT
fi

[[ -f "$FROM" ]] || { echo "Missing input: $FROM" >&2; exit 1; }

if [[ -z "$LABEL" ]]; then
  LABEL="$(basename "$FROM" .json)"
  LABEL="${LABEL%.jwt}"
fi

INPUT_FIXTURE="$OUT_DIR/input-${LABEL}.json"
META="$OUT_DIR/measurements-${LABEL}.json"
REGO_SNIPPET="$OUT_DIR/rego-measurements-${LABEL}.rego"

python3 - "$FROM" "$INPUT_FIXTURE" "$META" "$REGO_SNIPPET" <<'PY'
import json, sys

src_path, out_input, out_meta, out_rego = sys.argv[1:5]
doc = json.load(open(src_path, encoding="utf-8"))

if "input" in doc and isinstance(doc["input"], dict):
    claims = doc["input"]
elif "submods" in doc:
    claims = doc
else:
    # Some tokens nest EAR claims under a top-level key
    for key in ("attestation", "ear", "custom", "extensions"):
        if key in doc and isinstance(doc[key], dict) and "submods" in doc[key]:
            claims = doc[key]
            break
    else:
        claims = doc

if "submods" not in claims:
    raise SystemExit(
        "Could not find submods in input. Save KBS evaluation 'input' JSON or a JWT whose payload contains submods."
    )

json.dump(claims, open(out_input, "w", encoding="utf-8"), indent=2)
json.dump({"source": src_path, "submods": claims.get("submods", {})}, open(out_meta, "w", encoding="utf-8"), indent=2)

evidence = (
    claims.get("submods", {})
    .get("cpu0", {})
    .get("ear.veraison.annotated-evidence", {})
)

lines = [
    "# Suggested measurement pins from captured guest claims.",
    "# Test: ./dry-run.sh --rego this-file --fixture captured/input-LABEL.json",
    "",
]

snp = evidence.get("az-snp-vtpm") or {}
meas = snp.get("measurement")
pcr11 = (snp.get("tpm") or {}).get("pcr11")

if meas:
    lines += [
        "# SNP launch measurement (hex):",
        f"#   {meas}",
        "snp_measurement if {",
        f'\tinput["submods"]["cpu0"]["ear.veraison.annotated-evidence"]["az-snp-vtpm"]["measurement"] == "{meas}"',
        "}",
        "",
    ]
if pcr11:
    lines += [
        "# TPM PCR11 (hex):",
        f"#   {pcr11}",
        "snp_pcr11 if {",
        f'\tinput["submods"]["cpu0"]["ear.veraison.annotated-evidence"]["az-snp-vtpm"]["tpm"]["pcr11"] == "{pcr11}"',
        "}",
        "",
    ]

if not meas and not pcr11:
    lines += [
        "# No az-snp-vtpm measurement/pcr11 found in captured claims.",
        "# Token may be sample-only or use a different TEE key — check tee-naming-map.json.",
        "",
    ]

lines += [
    "# Example allow rule combining TEE type + measurement pin:",
    "allow if {",
    '\tdata.plugin == "resource"',
    '\tinput["submods"]["cpu0"]["ear.veraison.annotated-evidence"]["az-snp-vtpm"]',
]
if meas:
    lines.append("\tsnp_measurement")
if pcr11:
    lines.append("\tsnp_pcr11")
lines.append("}")

open(out_rego, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY

echo "Captured attestation claims"

# Write cvm-pins.json alongside capture
PINS_JSON="$OUT_DIR/cvm-pins-${LABEL}.json"
if jq -e '.submods.cpu0["ear.veraison.annotated-evidence"]["az-snp-vtpm"].measurement' "$INPUT_FIXTURE" >/dev/null 2>&1; then
  jq -n \
    --arg l "$LABEL" \
    --arg m "$(jq -r '.submods.cpu0["ear.veraison.annotated-evidence"]["az-snp-vtpm"].measurement' "$INPUT_FIXTURE")" \
    --arg p "$(jq -r '.submods.cpu0["ear.veraison.annotated-evidence"]["az-snp-vtpm"].tpm.pcr11' "$INPUT_FIXTURE")" \
    --arg s "$FROM" \
    '{label: $l, measurement: $m, pcr11: $p, source: $s}' >"$PINS_JSON"
fi
echo "  input fixture : $INPUT_FIXTURE"
echo "  measurements  : $META"
echo "  rego snippet  : $REGO_SNIPPET"
[[ -f "$PINS_JSON" ]] && echo "  cvm pins      : $PINS_JSON"
echo ""

echo "==> Evidence summary"
jq -r '
  .submods["cpu0"]["ear.veraison.annotated-evidence"] // {}
  | to_entries[]
  | "  \(.key): measurement=\(.value.measurement // "n/a") pcr11=\(.value.tpm.pcr11 // "n/a")"
' "$INPUT_FIXTURE" 2>/dev/null || jq '.' "$META"

echo ""
echo "Test policy against captured fixture:"
echo "  ./dry-run-measurements.sh --rego ../policy/kbs-resource-policy-snp-production.rego --fixture $INPUT_FIXTURE --require-pinning"
[[ -f "$PINS_JSON" ]] && echo "  bash ../scripts/kbs/generate-production-policy.sh --pins $PINS_JSON"
