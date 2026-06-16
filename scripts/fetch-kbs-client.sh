#!/usr/bin/env bash
# Optional: pull kbs-client binary via ORAS (not used by Dockerfile; image uses kbs-client-image).
set -euo pipefail

BIN_DIR="$(cd "$(dirname "$0")/../container/bin" && pwd)"
mkdir -p "$BIN_DIR"

if ! command -v oras >/dev/null 2>&1; then
  echo "Install oras: brew install oras" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
oras pull ghcr.io/confidential-containers/staged-images/kbs-client:latest -o "$tmp"
install -m 755 "$tmp/kbs-client" "$BIN_DIR/kbs-client"
echo "Wrote $BIN_DIR/kbs-client (ORAS artifact; prefer kbs-client-image in Docker builds)"
