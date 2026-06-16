#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=defaults.sh
source "$(dirname "$0")/defaults.sh"
# shellcheck source=container-engine.sh
source "$(dirname "$0")/container-engine.sh"
require_container_engine

[[ -f "$ROOT/artifacts/model.pt.enc" ]] || {
  echo "Run scripts/prepare-model.sh first" >&2
  exit 1
}
[[ -f "$ROOT/artifacts/model.pt" ]] || {
  echo "Missing artifacts/model.pt (run scripts/prepare-model.sh)" >&2
  exit 1
}
[[ -f "$ROOT/artifacts/kbs-client" ]] || {
  echo "==> Building kbs-client with SNP attester (required for CVM DEK policy)"
  bash "$ROOT/scripts/build-kbs-client.sh"
}
[[ -f "$ROOT/artifacts/ttrpc-cdh-tool" ]] || {
  echo "==> Building ttrpc-cdh-tool for CDH GetResource (peer-pod DEK path)"
  bash "$ROOT/scripts/build-cdh-tool.sh"
}

# ARO peer-pod guests on Azure are amd64; build for that platform from Apple Silicon too.
BUILD_PLATFORM="${BUILD_PLATFORM:-linux/amd64}"
echo "==> Building $IMAGE (platform=$BUILD_PLATFORM)"
ce build --platform "$BUILD_PLATFORM" -f "$ROOT/container/Dockerfile" -t "$IMAGE" "$ROOT"

echo "==> Pushing"
ce push "$IMAGE"

if [[ -f "$ROOT/artifacts/cosign.key" ]]; then
  echo "==> Signing (legacy .sig for peer-pod CDH — run make fix-image-sign if this step fails)"
  export COSIGN_PASSWORD="${COSIGN_PASSWORD:-confidential-inferencing-demo}"
  DIGEST="$(skopeo inspect "docker://$IMAGE" | jq -r .Digest)"
  SIGN_REF="${IMAGE%%:*}@${DIGEST}"
  COSIGN_V2="$(bash "$ROOT/scripts/cosign-v2-bin.sh")"
  COSIGN_EXPERIMENTAL=1 "$COSIGN_V2" sign --key "$ROOT/artifacts/cosign.key" -y "$SIGN_REF" \
    || echo "Signing failed — after push run: make fix-image-sign"
else
  echo "No cosign.key — run scripts/setup-cosign.sh and re-push, then cosign sign manually"
fi
