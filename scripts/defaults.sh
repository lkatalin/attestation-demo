# Shared defaults (source from other scripts).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export IMAGE="${IMAGE:-quay.io/lgallett/confidential-inferencing-demo:latest}"
export ARTIFACTS="${ARTIFACTS:-$ROOT/artifacts}"
export OPERATOR_BUNDLE="${OPERATOR_BUNDLE:-$ARTIFACTS/operator-bundle}"
export TRUSTEE_NS="${TRUSTEE_NS:-trustee-operator-system}"
export DEK_SECRET_NAME="${DEK_SECRET_NAME:-confidential-inferencing-dek}"
export KBS_RESOURCE_PATH="${KBS_RESOURCE_PATH:-default/${DEK_SECRET_NAME}/dek}"
export KBS_CONFIG="${KBS_CONFIG:-trusteeconfig-kbs-config}"
export POLICY_SECRET="${POLICY_SECRET:-trustee-image-policy}"
export SIG_SECRET="${SIG_SECRET:-confidential-inferencing-signature}"
export DEMO_NAMESPACE="${DEMO_NAMESPACE:-confidential-inferencing}"
