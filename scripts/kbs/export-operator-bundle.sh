#!/usr/bin/env bash
# Package artifacts for the KBS operator (DEK, cosign pub, rendered policy, instructions).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../defaults.sh
source "$SCRIPT_DIR/../defaults.sh"

BUNDLE="${OPERATOR_BUNDLE}"
DEK_SRC="${DEK_FILE:-$ARTIFACTS/dek.bin}"
PUB_SRC="${COSIGN_PUB:-$ARTIFACTS/cosign.pub}"

[[ -f "$DEK_SRC" ]] || { echo "Missing $DEK_SRC — run: make prepare" >&2; exit 1; }
[[ -f "$PUB_SRC" ]] || { echo "Missing $PUB_SRC — run: make setup-cosign" >&2; exit 1; }

mkdir -p "$BUNDLE"
cp -f "$DEK_SRC" "$BUNDLE/dek.bin"
cp -f "$PUB_SRC" "$BUNDLE/cosign.pub"

IMAGE_REPO="${IMAGE%%:*}"
sed "s|__IMAGE_REF__|${IMAGE_REPO}|" "$ROOT/policy/verification-policy.template.json" \
  >"$BUNDLE/verification-policy.json"

if [[ -n "${OPERATOR_INITDATA_PATH:-}" && -f "$OPERATOR_INITDATA_PATH" ]]; then
  cp -f "$OPERATOR_INITDATA_PATH" "$BUNDLE/initdata.toml"
fi

cat >"$BUNDLE/README.txt" <<EOF
Operator bundle for confidential-inferencing demo
================================================

On your ARO cluster (Trustee + KBS), after: oc login

  cd confidential-inferencing
  export OPERATOR_BUNDLE=$BUNDLE
  export IMAGE=$IMAGE
  make operator-cluster

Then export KBS endpoint for the model owner:

  make operator-export-kbs-endpoint

Share this directory (or a tarball) plus your initdata.toml from coco-infra Trustee setup
if the model owner's inference cluster does not have it yet.

Guest DEK path: $KBS_RESOURCE_PATH
Signed image repo: $IMAGE_REPO
EOF

echo "Wrote operator bundle: $BUNDLE"
ls -la "$BUNDLE"
