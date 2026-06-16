#!/usr/bin/env bash
# Generate cosign key pair for signing the inference container image.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS="${ARTIFACTS:-$ROOT/artifacts}"
mkdir -p "$ARTIFACTS"

if [[ -f "$ARTIFACTS/cosign.key" ]]; then
  echo "cosign keys already exist in $ARTIFACTS"
  exit 0
fi

command -v cosign >/dev/null || {
  echo "Install cosign (e.g. brew install cosign)" >&2
  exit 1
}

export COSIGN_PASSWORD="${COSIGN_PASSWORD:-confidential-inferencing-demo}"
(
  cd "$ARTIFACTS"
  cosign generate-key-pair
)
echo "Wrote $ARTIFACTS/cosign.key and cosign.pub"
echo "Use COSIGN_PASSWORD when signing (default for demo: $COSIGN_PASSWORD)"
