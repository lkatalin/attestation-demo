#!/usr/bin/env bash
# Measure attestation-related behavior for confidential vs baseline pods (for KBS policy tuning).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../defaults.sh
source "$SCRIPT_DIR/../defaults.sh"

NS="${DEMO_NAMESPACE}"
TRUSTEE_NS="${TRUSTEE_NS}"
KBS_RESOURCE_PATH="${KBS_RESOURCE_PATH:-default/confidential-inferencing-dek/dek}"

oc whoami >/dev/null || { echo "oc login required" >&2; exit 1; }

section() { echo ""; echo "=== $* ==="; }

section "Deployments (runtime class)"
for dep in inference-confidential inference-baseline-encrypted inference-plaintext; do
  rc="$(oc get deployment "$dep" -n "$NS" -o jsonpath='{.spec.template.spec.runtimeClassName}' 2>/dev/null || echo '?')"
  printf "  %-32s runtimeClassName=%s\n" "$dep" "${rc:-<default>}"
done

section "Pods"
oc get pods -n "$NS" -l 'demo-role in (confidential,baseline-encrypted-fail,plaintext-control)' \
  -o custom-columns=NAME:.metadata.name,ROLE:.metadata.labels.demo-role,RUNTIME:.spec.runtimeClassName,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,PHASE:.status.phase \
  2>/dev/null || true

section "Guest signals (latest pod logs, if running)"
for label in confidential baseline-encrypted-fail; do
  pod="$(oc get pod -n "$NS" -l "demo-role=$label" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || continue
  echo "--- demo-role=$label pod=$pod ---"
  oc logs -n "$NS" "$pod" -c inference --tail=30 2>&1 \
    | grep -E 'CDH socket|Sample Attester|DEK retrieved|PolicyDeny|unauthorized|Decrypting|Starting inference' \
    || echo "  (no matching log lines — pod may be down or still starting)"
done

section "Trustee: tee= on verify (last 50 attest lines)"
oc logs -n "$TRUSTEE_NS" deployment/trustee-deployment --tail=2000 2>&1 \
  | grep 'Verifier/endorsement check passed' \
  | tail -50 \
  | sed -E 's/.*tee=([^ ]+).*/\1/' \
  | sort | uniq -c | sort -rn \
  || echo "  (no attest lines)"

section "Trustee: image-policy GET (last 20)"
oc logs -n "$TRUSTEE_NS" deployment/trustee-deployment --tail=2000 2>&1 \
  | grep "resource/default/trustee-image-policy/policy" \
  | tail -20 \
  || echo "  (no image-policy lines)"

section "Trustee: DEK resource GET (last 30)"
oc logs -n "$TRUSTEE_NS" deployment/trustee-deployment --tail=2000 2>&1 \
  | grep "resource/default/confidential-inferencing-dek/dek" \
  | tail -30 \
  || echo "  (no DEK lines)"

section "Current KBS resource policy (first 20 lines)"
oc get configmap trusteeconfig-resource-policy -n "$TRUSTEE_NS" -o jsonpath='{.data.policy\.rego}' 2>/dev/null \
  | head -20 || echo "  (missing configmap)"

section "Expected behavior matrix"
cat <<'EOF'
  Arm              | Runtime      | Verify log (tee=) | Rego claim key      | image-policy | DEK GET   | HTTP
  -----------------|--------------|-------------------|---------------------|--------------|-----------|------
  confidential     | kata-remote  | AzSnpVtpm         | az-snp-vtpm         | 200          | 200       | Route OK
  baseline-encrypt | <default>    | Sample (ideal)    | sample only         | n/a          | 401 deny  | no Route
  plaintext        | <default>    | (no KBS)          | n/a                 | n/a          | n/a       | Route OK

  Note: tee= in Trustee logs is the Rust Tee name; KBS resource Rego must use annotated-evidence["az-snp-vtpm"].

If confidential shows tee=Sample on DEK: rebuild image with scripts/build-kbs-client.sh
If tee=AzSnpVtpm but image-policy/DEK GET 401: check policy uses az-snp-vtpm (not AzSnpVtpm)
If baseline shows DEK 200 / Running: re-apply policy (make relax-resource-policy-snp) and delete pod
EOF

section "Optional: refresh measurements after pod restart"
echo "  oc delete pod -n $NS -l 'demo-role in (confidential,baseline-encrypted-fail)'"
echo "  sleep 120 && bash $SCRIPT_DIR/measure-attestation-behavior.sh"
