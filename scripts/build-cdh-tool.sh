#!/usr/bin/env bash
# Build ttrpc-cdh-tool (linux/amd64) for runtime GetResource via CDH socket in peer pods.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=container-engine.sh
source "$ROOT/scripts/container-engine.sh"
require_container_engine

OUT="${CDH_TOOL_BIN:-$ROOT/artifacts/ttrpc-cdh-tool}"
BUILD_PLATFORM="${BUILD_PLATFORM:-linux/amd64}"
GUEST_COMPONENTS_REF="${GUEST_COMPONENTS_REF:-main}"
IMG="confidential-inferencing-cdh-tool:build"

mkdir -p "$(dirname "$OUT")"

echo "==> Building ttrpc-cdh-tool ($BUILD_PLATFORM) from guest-components@${GUEST_COMPONENTS_REF}"
ce build --platform "$BUILD_PLATFORM" \
  --target export \
  --build-arg "GUEST_COMPONENTS_REF=${GUEST_COMPONENTS_REF}" \
  -f "$ROOT/container/Dockerfile.cdh-tool" \
  -t "$IMG" \
  "$ROOT"

ce run --rm --platform "$BUILD_PLATFORM" \
  -v "$(dirname "$OUT"):/out:Z" \
  --entrypoint cp \
  "$IMG" /usr/local/bin/ttrpc-cdh-tool "/out/$(basename "$OUT")"

chmod +x "$OUT"
file "$OUT"
echo "Installed $OUT"
