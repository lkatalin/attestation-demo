#!/usr/bin/env bash
# Regenerate deploy/configmap-entrypoint.yaml from container/entrypoint.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTRY="$ROOT/container/entrypoint.sh"
OUT="$ROOT/deploy/configmap-entrypoint.yaml"

python3 - "$ENTRY" "$OUT" <<'PY'
import pathlib
import sys

entry_path, out_path = map(pathlib.Path, sys.argv[1:3])
script = entry_path.read_text()
# Indent embedded script for YAML literal block (4 spaces under data.entrypoint.sh).
indented = "\n".join("    " + line for line in script.splitlines())
if script.endswith("\n"):
    indented += "\n"

yaml = f"""apiVersion: v1
kind: ConfigMap
metadata:
  name: inference-entrypoint
  namespace: confidential-inferencing
data:
  entrypoint.sh: |
{indented}"""

out_path.write_text(yaml)
print(f"Wrote {out_path}")
PY
