#!/usr/bin/env bash
# Enable guest attestation REST (/aa/token) for kata-remote peer pods on OSC.
#
# Peer pods use /etc/kata-containers/remote/configuration.toml with a restricted
# enable_annotations list (no kernel_params). This one-time patch:
#   1. Allows the kernel_params pod annotation (optional per-workload override)
#   2. Sets global kernel_params = agent.guest_components_rest_api=all for all new CVMs
#
# Re-run after OpenShift Sandboxed Containers upgrades (OSC may regenerate the file).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../defaults.sh
source "$SCRIPT_DIR/../defaults.sh"

KERNEL_PARAM="${GUEST_REST_KERNEL_PARAM:-agent.guest_components_rest_api=all}"
REMOTE_CFG=/etc/kata-containers/remote/configuration.toml
PATCH_PY="$SCRIPT_DIR/patch-kata-guest-rest.py"

oc whoami >/dev/null || { echo "oc login required" >&2; exit 1; }
[[ -f "$PATCH_PY" ]] || { echo "Missing $PATCH_PY" >&2; exit 1; }

mapfile -t KATA_NODES < <(oc get nodes -l node-role.kubernetes.io/kata-oc= -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[[ ${#KATA_NODES[@]} -gt 0 ]] || {
  echo "No kata-oc nodes found (label node-role.kubernetes.io/kata-oc=)" >&2
  exit 1
}

PATCH_B64="$(base64 <"$PATCH_PY" | tr -d '\n')"

patch_node() {
  local node="$1"
  echo "==> Patch $REMOTE_CFG on $node"
  local out
  out="$(oc debug "node/$node" --quiet -- chroot /host /bin/bash -c \
    "set -euo pipefail; CFG='${REMOTE_CFG}'; KP='${KERNEL_PARAM}'; [[ -f \"\$CFG\" ]] || exit 1; echo '${PATCH_B64}' | base64 -d > /tmp/patch-kata-guest-rest.py; KP=\"\$KP\" CFG=\"\$CFG\" python3 /tmp/patch-kata-guest-rest.py; rm -f /tmp/patch-kata-guest-rest.py; grep -E 'enable_annotations|^kernel_params' \"\$CFG\" | head -3")"
  echo "$out"
  grep -q 'guest_components_rest_api' <<<"$out" \
    || { echo "FAIL: patch did not set kernel_params on $node" >&2; return 1; }
}

for node in "${KATA_NODES[@]}"; do
  patch_node "$node"
done

echo ""
echo "New peer-pod CVMs will expose /aa/token on 127.0.0.1:8006 inside the pod netns."
echo ""
echo "Run this before the first confidential VM boot (demo prologue). Idempotent."
echo ""
echo "If workloads already booted without this patch, recreate them so new CVMs pick it up:"
echo "  oc delete pod -n $DEMO_NAMESPACE -l app=inference-confidential"
echo "  oc delete pod -n $DEMO_NAMESPACE -l app=attest-probe --ignore-not-found"
echo ""
echo "Capture golden measurement + pcr11 (after at least one good CVM path):"
echo "  make capture-golden-claims"
echo ""
echo "Re-run after major OSC upgrades if capture returns HTTP 404."
