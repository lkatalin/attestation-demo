#!/usr/bin/env bash
# Resolve cosign v2 binary for legacy .sig tags (peer-pod CDH rejects cosign v3 bundles).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS="${ARTIFACTS:-$ROOT/artifacts}"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"
BIN="$ARTIFACTS/cosign-v2.4.3-${OS}-${ARCH}"

if [[ -x "$BIN" ]]; then
  echo "$BIN"
  exit 0
fi

if command -v cosign-v2 >/dev/null 2>&1; then
  echo "$(command -v cosign-v2)"
  exit 0
fi

mkdir -p "$ARTIFACTS"
curl -fsSL -o "$BIN" \
  "https://github.com/sigstore/cosign/releases/download/v2.4.3/cosign-${OS}-${ARCH}"
chmod +x "$BIN"
echo "$BIN"
