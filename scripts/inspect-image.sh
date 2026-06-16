#!/usr/bin/env bash
# Show what is inside the container image (encrypted shipping artifact vs demo plaintext control).
set -euo pipefail

# shellcheck source=defaults.sh
source "$(dirname "$0")/defaults.sh"
# shellcheck source=container-engine.sh
source "$(dirname "$0")/container-engine.sh"
require_container_engine

echo "==> Files under /app in image $IMAGE"
ce run --rm --entrypoint find "$IMAGE" /app -type f | sort

echo ""
echo "==> Encrypted artifact (what confidential pods use at startup)"
ce run --rm --entrypoint ls -lh "$IMAGE" /app/encrypted

echo ""
echo "==> Plaintext control copy (only used when DEMO_MODE=plaintext)"
ce run --rm --entrypoint ls -lh "$IMAGE" /app/plaintext

echo ""
echo "Confidential pods never read /app/plaintext; they decrypt /app/encrypted/model.pt.enc after KBS."
