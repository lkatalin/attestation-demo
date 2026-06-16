#!/usr/bin/env bash
# Build kbs-client with AMD SNP attester for peer-pod guests (linux/amd64).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TRUSTEE_DIR="${TRUSTEE_DIR:-$ROOT/../trustee}"
OUT="${KBS_CLIENT_OUT:-$ROOT/artifacts/kbs-client}"
TARGET="${KBS_CLIENT_TARGET:-x86_64-unknown-linux-gnu}"
FEATURES="${KBS_CLIENT_FEATURES:-az-snp-vtpm-attester}"
BUILD_PLATFORM="${BUILD_PLATFORM:-linux/amd64}"

[[ -d "$TRUSTEE_DIR/kbs" ]] || {
  echo "Missing $TRUSTEE_DIR — clone confidential-containers/trustee or set TRUSTEE_DIR" >&2
  exit 1
}

build_with_cargo() {
  echo "==> Building kbs-client with local cargo (features=$FEATURES, target=$TARGET)"
  (
    cd "$TRUSTEE_DIR/kbs"
    cargo build -p kbs-client \
      --locked \
      --release \
      --no-default-features \
      --features "$FEATURES" \
      --target "$TARGET"
  )
  install -d "$(dirname "$OUT")"
  install -m 0755 "$TRUSTEE_DIR/target/$TARGET/release/kbs-client" "$OUT"
}

build_with_container() {
  # shellcheck source=container-engine.sh
  source "$(dirname "$0")/container-engine.sh"
  require_container_engine

  local img="confidential-inferencing-kbs-client-build:local"
  echo "==> Building kbs-client in $CONTAINER_ENGINE (platform=$BUILD_PLATFORM, no local cargo)"
  ce build \
    --platform "$BUILD_PLATFORM" \
    --target export \
    --build-arg "KBS_CLIENT_FEATURES=$FEATURES" \
    --build-arg "KBS_CLIENT_TARGET=$TARGET" \
    -f "$ROOT/container/Dockerfile.kbs-client" \
    -t "$img" \
    "$TRUSTEE_DIR"

  install -d "$(dirname "$OUT")"
  ce run --rm --platform "$BUILD_PLATFORM" \
    -v "$(dirname "$OUT"):/out:Z" \
    --entrypoint cp \
    "$img" /usr/local/bin/kbs-client "/out/$(basename "$OUT")"
}

if command -v cargo >/dev/null 2>&1; then
  build_with_cargo
else
  build_with_container
fi

echo "Installed $OUT"
file "$OUT"
"$OUT" --version 2>/dev/null || true
