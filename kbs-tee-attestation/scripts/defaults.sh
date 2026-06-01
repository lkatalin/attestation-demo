# Defaults for kbs-tee-attestation (KBS operator bundle).
BUNDLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$BUNDLE_ROOT/.." && pwd)"

export INPUTS_DIR="${INPUTS_DIR:-$BUNDLE_ROOT/inputs}"
export OUTPUT_DIR="${OUTPUT_DIR:-$BUNDLE_ROOT/output}"
export POLICY_DIR="${POLICY_DIR:-$BUNDLE_ROOT/policy}"

export IMAGE="${IMAGE:-quay.io/lgallett/confidential-inferencing-demo:latest}"
export TRUSTEE_NS="${TRUSTEE_NS:-trustee-operator-system}"
export TRUSTEE_CONFIG="${TRUSTEE_CONFIG:-trusteeconfig}"
export DEK_SECRET_NAME="${DEK_SECRET_NAME:-confidential-inferencing-dek}"
export KBS_RESOURCE_PATH="${KBS_RESOURCE_PATH:-default/${DEK_SECRET_NAME}/dek}"
export KBS_CONFIG="${KBS_CONFIG:-trusteeconfig-kbs-config}"
export POLICY_SECRET="${POLICY_SECRET:-trustee-image-policy}"
export SIG_SECRET="${SIG_SECRET:-confidential-inferencing-signature}"
export ROUTE_NAME="${ROUTE_NAME:-kbs-service}"
export RESOURCE_POLICY_CM="${RESOURCE_POLICY_CM:-trusteeconfig-resource-policy}"

export DEK_FILE="${DEK_FILE:-$INPUTS_DIR/dek.bin}"
export COSIGN_PUB="${COSIGN_PUB:-$INPUTS_DIR/cosign.pub}"
