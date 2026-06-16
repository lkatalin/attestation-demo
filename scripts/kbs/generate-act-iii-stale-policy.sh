#!/usr/bin/env bash
# Generate production Rego with a deliberately stale measurement pin (Act III drill).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PINS="${PINS:-$ROOT/policy-dry-run/captured/cvm-pins-golden.json}"
OUT="${OUT:-$ROOT/policy/kbs-resource-policy-snp-act-iii-stale.rego}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pins) PINS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--pins PATH] [--out PATH]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -f "$PINS" ]] || { echo "Missing golden pins: $PINS" >&2; exit 1; }

STALE_PINS="$(mktemp)"
python3 - "$PINS" "$STALE_PINS" <<'PY'
import json
import sys

src, dst = sys.argv[1:3]
pins = json.load(open(src, encoding="utf-8"))
meas = pins.get("measurement") or ""
if len(meas) < 8:
    sys.stderr.write("golden pins missing measurement\n")
    sys.exit(1)

alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
last = meas[-1]
if last not in alphabet:
    stale = meas[:-1] + "X"
else:
    stale = meas[:-1] + alphabet[(alphabet.index(last) + 1) % len(alphabet)]

if stale == meas:
    stale = meas[:-1] + "A"

pins["measurement"] = stale
pins["label"] = "act-iii-stale-pin"
pins["source"] = "stale-measurement drill (Act III)"
json.dump(pins, open(dst, "w", encoding="utf-8"), indent=2)
print(f"stale measurement={stale[:16]}… (golden={meas[:16]}…)")
PY
trap 'rm -f "$STALE_PINS"' EXIT

bash "$SCRIPT_DIR/generate-production-policy.sh" --pins "$STALE_PINS" --out "$OUT"

echo "Wrote $OUT"
