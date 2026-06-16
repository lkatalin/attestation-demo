#!/usr/bin/env bash
# Build Act III mismatch initdata from the cluster's current golden peer-pods INITDATA.
# Does NOT patch peer-pods-cm by default — use pod annotation (see demo-act-iii-mismatch.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../defaults.sh
source "$SCRIPT_DIR/../defaults.sh"

PEER_NS="${PEER_NS:-openshift-sandboxed-containers-operator}"
CM="${PEER_CM:-peer-pods-cm}"
WORKDIR="${ARTIFACTS}/act-iii-initdata"
GOLDEN_BACKUP="$WORKDIR/golden-initdata.toml"
MISMATCH_OUT="$WORKDIR/mismatch-initdata.toml"
MISMATCH_B64="$WORKDIR/mismatch-initdata.b64"
MARKER="act-iii-mismatch-drill"

oc whoami >/dev/null || { echo "oc login required" >&2; exit 1; }
oc get configmap "$CM" -n "$PEER_NS" >/dev/null || {
  echo "Missing $CM in $PEER_NS" >&2
  exit 1
}

mkdir -p "$WORKDIR"

echo "==> Snapshot peer-pods INITDATA (golden baseline — do not patch CM during Act III)"
oc get configmap "$CM" -n "$PEER_NS" -o jsonpath='{.data.INITDATA}' \
  | base64 -d | gunzip >"$GOLDEN_BACKUP"

# Strip any prior drill marker so re-runs start from golden content.
python3 - "$GOLDEN_BACKUP" "$GOLDEN_BACKUP" "$MARKER" <<'PY'
import re
import sys

src, dst, marker = sys.argv[1:4]
text = open(src, encoding="utf-8").read()
text = re.sub(rf'^# {re.escape(marker)}.*\n', '', text, flags=re.M)
text = re.sub(rf'-{re.escape(marker)}"', '"', text)
text = re.sub(rf'"{re.escape(marker)}\.toml" = \'\'\'demo=mismatch\\n\'\'\'\n', '', text)
text = text.replace('default ExecProcessRequest := true', 'default ExecProcessRequest := false')
open(dst, "w", encoding="utf-8").write(text)
PY

python3 - "$GOLDEN_BACKUP" "$MISMATCH_OUT" "$MARKER" <<'PY'
import re
import sys

src, dst, marker = sys.argv[1:4]
text = open(src, encoding="utf-8").read()

# Substantive edits (comments alone do not change SNP measurement / PCR11 on Azure peer pods).
text, n = re.subn(
    r'^version = "([^"]+)"',
    rf'version = "\1-{marker}"',
    text,
    count=1,
    flags=re.M,
)
if n != 1:
    sys.stderr.write("Could not bump initdata version\n")
    sys.exit(1)

text = text.replace(
    "default ExecProcessRequest := false",
    "default ExecProcessRequest := true",
    1,
)

needle = '[data]\n'
extra = f'"{marker}.toml" = \'\'\'demo=mismatch\\n\'\'\'\n'
if extra not in text:
    if needle not in text:
        sys.stderr.write("Could not locate [data] in initdata\n")
        sys.exit(1)
    text = text.replace(needle, needle + extra, 1)

open(dst, "w", encoding="utf-8").write(text)
print("Built mismatch initdata (version bump + agent policy + drill key)")
PY

golden_sha="$(sha256sum "$GOLDEN_BACKUP" | awk '{print $1}')"
mismatch_sha="$(sha256sum "$MISMATCH_OUT" | awk '{print $1}')"
if [[ "$golden_sha" == "$mismatch_sha" ]]; then
  echo "FAIL: mismatch initdata identical to golden — cannot demo PolicyDeny" >&2
  exit 1
fi

gzip -c "$MISMATCH_OUT" | base64 | tr -d '\n' >"$MISMATCH_B64"

echo "  golden initdata sha256=${golden_sha:0:16}…"
echo "  mismatch initdata sha256=${mismatch_sha:0:16}…"
echo "  mismatch b64: $MISMATCH_B64"

if [[ "${ACT_III_PATCH_PEER_PODS_CM:-0}" == "1" ]]; then
  echo "==> ACT_III_PATCH_PEER_PODS_CM=1 — patching peer-pods-cm (not recommended during demo)"
  INITDATA_PATH="$MISMATCH_OUT" bash "$SCRIPT_DIR/apply-peer-pods-initdata.sh"
fi
