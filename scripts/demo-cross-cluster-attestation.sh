#!/bin/bash
set -e

# Demonstrate cross-cluster attestation with model and infra clusters.
# Assumes both clusters are running with Trustee and OSC configured.
#
# Usage:
#   bash scripts/demo-cross-cluster-attestation.sh <quay-username>
#
# Example:
#   bash scripts/demo-cross-cluster-attestation.sh myusername

if [[ $# -lt 1 ]]; then
  echo "ERROR: Missing required quay.io username"
  echo "Usage: $0 <quay-username>"
  echo "Example: $0 myusername"
  exit 1
fi

USERNAME="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$ROOT"

echo "=================================================="
echo "Cross-Cluster Attestation Demo"
echo "  Quay username: $USERNAME"
echo "  Image: quay.io/$USERNAME/confidential-inferencing-demo:latest"
echo "=================================================="

# Find model and infra contexts
MODEL_CONTEXT=$(oc config get-contexts -o name | grep -i model || true)
INFRA_CONTEXT=$(oc config get-contexts -o name | grep -i infra || true)

if [[ -z "$MODEL_CONTEXT" ]]; then
  echo "ERROR: No oc context found with 'model' in the name"
  echo "Available contexts:"
  oc config get-contexts -o name
  exit 1
fi

if [[ -z "$INFRA_CONTEXT" ]]; then
  echo "ERROR: No oc context found with 'infra' in the name"
  echo "Available contexts:"
  oc config get-contexts -o name
  exit 1
fi

echo ""
echo "Using contexts:"
echo "  Model cluster: $MODEL_CONTEXT"
echo "  Infra cluster: $INFRA_CONTEXT"

# Step 1: Configure model cluster
echo ""
echo "=================================================="
echo "Step 1: Configure Model Cluster"
echo "=================================================="
oc config use-context "$MODEL_CONTEXT"

export IMAGE="quay.io/$USERNAME/confidential-inferencing-demo:latest"
echo "  IMAGE=$IMAGE"

# Step 2: Generate DEK if needed
if [[ ! -f artifacts/dek.bin ]]; then
  echo ""
  echo "  DEK not found, running 'make laptop-prep'..."
  make laptop-prep
else
  echo ""
  echo "  ✓ DEK already exists at artifacts/dek.bin"
fi

# Step 3: Export KBS endpoint
echo ""
echo "  Running 'make operator-export-kbs-endpoint'..."
make operator-export-kbs-endpoint

# Step 4: Register DEK
echo ""
echo "  Running 'make operator-register-dek'..."
DEK_FILE=artifacts/dek.bin make operator-register-dek

# Step 5: Register policy
echo ""
echo "  Running 'make operator-register-policy'..."
COSIGN_PUB=artifacts/cosign.pub make operator-register-policy

# Step 6: Relax resource policy
echo ""
echo "  Running 'make relax-resource-policy-snp'..."
make relax-resource-policy-snp

# Step 7: Configure infra cluster
echo ""
echo "=================================================="
echo "Step 2: Configure Infra Cluster"
echo "=================================================="
oc config use-context "$INFRA_CONTEXT"

export INITDATA_PATH=artifacts/operator-bundle/initdata.toml
export KBS_URL=$(cat artifacts/operator-bundle/kbs.url)
export KBS_CA_FILE=artifacts/operator-bundle/kbs-ca.pem

echo "  INITDATA_PATH=$INITDATA_PATH"
echo "  KBS_URL=$KBS_URL"
echo "  KBS_CA_FILE=$KBS_CA_FILE"

# Step 8: Apply initdata
echo ""
echo "  Running 'make remote-apply-initdata'..."
INITDATA_PATH="$INITDATA_PATH" make remote-apply-initdata

# Step 9: Fix peer-pods
echo ""
echo "  Running 'make fix-peer-pods'..."
make fix-peer-pods

# Step 10: Clean up stale workloads from previous runs
echo ""
echo "  Cleaning up existing demo deployments..."
for dep in inference-confidential inference-plaintext inference-baseline-encrypted; do
  oc delete deployment "$dep" -n confidential-inferencing --ignore-not-found 2>/dev/null
done
oc delete pods -n confidential-inferencing --all --ignore-not-found 2>/dev/null

# Step 11: Deploy workload
echo ""
echo "  Running 'make remote-deploy'..."
IMAGE="$IMAGE" KBS_URL="$KBS_URL" KBS_CA_FILE="$KBS_CA_FILE" make remote-deploy

echo ""
echo "=================================================="
echo "Deployment complete!"
echo "=================================================="
echo ""
echo "Check pod status with:"
echo "  oc get pods -n confidential-inferencing"
echo ""
echo "Watch pod logs with:"
echo "  oc logs -n confidential-inferencing -l demo-role=confidential -f"
