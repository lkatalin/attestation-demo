#!/usr/bin/env bash
# Train the demo model and produce AES-256-GCM encrypted weights + DEK for KBS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS="${ARTIFACTS:-$ROOT/artifacts}"
PYTHON="${PYTHON:-python3}"

mkdir -p "$ARTIFACTS"
VENV="$ROOT/.venv-train"
if [[ ! -d "$VENV" ]]; then
  echo "Creating training venv at $VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q -r "$ROOT/model/requirements-train.txt"
fi
PYTHON="$VENV/bin/python"

echo "==> Training tiny transformer"
"$PYTHON" "$ROOT/model/train.py" --out-dir "$ARTIFACTS"

echo "==> Encrypting model weights"
DEK_FILE="$ARTIFACTS/dek.bin"
ENC_FILE="$ARTIFACTS/model.pt.enc"
MANIFEST="$ARTIFACTS/manifest.json"

ARTIFACTS="$ARTIFACTS" "$PYTHON" - <<'PY'
import hashlib
import json
import os
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

root = Path(os.environ["ARTIFACTS"])
pt = (root / "model.pt").read_bytes()
dek = AESGCM.generate_key(bit_length=256)
iv = os.urandom(12)
ct = AESGCM(dek).encrypt(iv, pt, None)
(root / "dek.bin").write_bytes(dek)
(root / "model.pt.enc").write_bytes(ct)
manifest = {
    "algorithm": "aes-256-gcm",
    "plaintext_sha256": hashlib.sha256(pt).hexdigest(),
    "iv_hex": iv.hex(),
    "ciphertext_file": "model.pt.enc",
}
(root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print("encrypted", len(ct), "bytes")
PY

echo "Artifacts in $ARTIFACTS:"
ls -la "$ARTIFACTS/dek.bin" "$ARTIFACTS/model.pt.enc" "$ARTIFACTS/manifest.json"
echo "Next: register DEK with KBS — scripts/register-dek.sh"
