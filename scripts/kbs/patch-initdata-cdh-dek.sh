#!/usr/bin/env bash
# Idempotently add CDH [[credentials]] for the model DEK to initdata.toml (cdh.toml block).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../defaults.sh
source "$SCRIPT_DIR/../defaults.sh"

IN="${1:?usage: patch-initdata-cdh-dek.sh INPUT.toml [OUTPUT.toml]}"
OUT="${2:-$IN}"

CDH_PATH="/run/confidential-containers/cdh/kbs/${KBS_RESOURCE_PATH}"
RESOURCE_URI="kbs:///${KBS_RESOURCE_PATH}"

python3 - "$IN" "$OUT" "$CDH_PATH" "$RESOURCE_URI" <<'PY'
import re
import sys

src, dst, cdh_path, resource_uri = sys.argv[1:5]
text = open(src, encoding="utf-8").read()

if resource_uri in text and cdh_path in text:
    open(dst, "w", encoding="utf-8").write(text)
    print(f"initdata already contains CDH DEK credential ({cdh_path})")
    sys.exit(0)

cred_block = f'''[[credentials]]
path = "{cdh_path}"
resource_uri = "{resource_uri}"
'''

# Replace empty credentials list inside cdh.toml embedded string.
patched, n = re.subn(
    r"(\"cdh\.toml\"\s*=\s*'''[\s\S]*?)credentials\s*=\s*\[\]\s*\n",
    r"\1" + cred_block,
    text,
    count=1,
)
if n != 1:
    # Append credentials after socket= line if credentials = [] was already replaced differently.
    if "[[credentials]]" in text and cdh_path not in text:
        patched = text.replace(
            "socket = 'unix:///run/confidential-containers/cdh.sock'\n",
            "socket = 'unix:///run/confidential-containers/cdh.sock'\n" + cred_block,
            1,
        )
    else:
        sys.stderr.write("Could not patch cdh.toml credentials block in initdata\n")
        sys.exit(1)

open(dst, "w", encoding="utf-8").write(patched)
print(f"Patched initdata: CDH credential path={cdh_path}")
PY
