#!/usr/bin/env bash
# Fix peer-pods: DC*as_v5 SKUs and kataWorker on a zone that offers them (e.g. eastus-2).
set -euo pipefail

PEER_NS=openshift-sandboxed-containers-operator
CM=peer-pods-cm
# AMD SEV-SNP confidential VMs (required for peer-pods ConfidentialVM / VMGuestStateOnly).
INSTANCE_SIZE="${AZURE_INSTANCE_SIZE:-Standard_DC4as_v5}"
INSTANCE_SIZES="${AZURE_INSTANCE_SIZES:-Standard_DC2as_v5,Standard_DC4as_v5,Standard_DC8as_v5,Standard_DC2es_v5,Standard_DC4es_v5,Standard_DC8es_v5}"
AZURE_REGION="${AZURE_REGION:-$(oc get configmap "$CM" -n "$PEER_NS" -o jsonpath='{.data.AZURE_REGION}' 2>/dev/null)}"
AZURE_REGION="${AZURE_REGION:-eastus}"
# Prefer zone 2, then zone 1 (DC4as_v5 is in eastus zones 1,2)
TARGET_ZONE="${KATA_WORKER_ZONE:-${AZURE_REGION}-2}"

echo "==> Patch $CM (VM size for peer pods)"
oc patch configmap "$CM" -n "$PEER_NS" --type merge -p "$(jq -nc \
  --arg size "$INSTANCE_SIZE" \
  --arg sizes "$INSTANCE_SIZES" \
  '{data: {AZURE_INSTANCE_SIZE: $size, AZURE_INSTANCE_SIZES: $sizes}}')"

echo "==> Move workerType=kataWorker to a node in $TARGET_ZONE"
KATA_NODE="$(oc get nodes -l "topology.kubernetes.io/zone=$TARGET_ZONE,node-role.kubernetes.io/worker=" -o jsonpath='{.items[0].metadata.name}')"
if [[ -z "$KATA_NODE" ]]; then
  TARGET_ZONE="${AZURE_REGION}-1"
  KATA_NODE="$(oc get nodes -l "topology.kubernetes.io/zone=$TARGET_ZONE,node-role.kubernetes.io/worker=" -o jsonpath='{.items[0].metadata.name}')"
fi
[[ -n "$KATA_NODE" ]] || { echo "No worker in ${AZURE_REGION}-2 or ${AZURE_REGION}-1" >&2; exit 1; }

for n in $(oc get nodes -l workerType=kataWorker -o jsonpath='{.items[*].metadata.name}'); do
  oc label node "$n" workerType- 2>/dev/null || true
done
oc label node "$KATA_NODE" workerType=kataWorker --overwrite
echo "kataWorker -> $KATA_NODE ($TARGET_ZONE)"

echo "==> Restart confidential inference pod (if deployed)"
if oc get deployment inference-confidential -n confidential-inferencing &>/dev/null; then
  oc rollout restart deployment/inference-confidential -n confidential-inferencing
  echo "Watch: oc get pods -n confidential-inferencing -w"
fi

echo ""
echo "Done. Peer-pod VMs should use $INSTANCE_SIZE in zones 2 or 3."
echo "First CVM create may take 15-30 minutes."
