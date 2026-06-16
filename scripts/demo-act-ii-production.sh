#!/usr/bin/env bash
# Act II — after production policy is applied on KBS:
#   1. Restart the golden confidential pod (forces fresh attest + DEK fetch under pinned Rego)
#   2. Wait for Ready
#   3. Show DEK success in pod + Trustee logs
#   4. Prompt confidential / plaintext / baseline
#
# Prerequisite:
#   make apply-production-resource-policy   (or full generate + dry-run + apply from narration)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=defaults.sh
source "$SCRIPT_DIR/defaults.sh"

NS="${DEMO_NAMESPACE}"
TRUSTEE_NS="${TRUSTEE_NS:-trustee-operator-system}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-900}"
PINS_FILE="${PINS_FILE:-$SCRIPT_DIR/../policy-dry-run/captured/cvm-pins-golden.json}"

section() { echo ""; echo "======== $* ========"; }

fail_act_ii() {
  echo "" >&2
  echo "Act II failed: $1" >&2
  echo "" >&2
  echo "Common fixes:" >&2
  echo "  • PolicyDeny + tee=AzSnpVtpm → pinned measurement/pcr11 stale (often after make demo-act-iii or sync-trustee-attestation):" >&2
  echo "      make capture-golden-claims" >&2
  echo "      make promote-production-policy" >&2
  echo "      FORCE_POD_DELETE=1 make demo-act-ii" >&2
  echo "  • Pod Terminating / CreateContainerError → stuck CVM:" >&2
  echo "      FORCE_POD_DELETE=1 bash scripts/kbs/restart-confidential-workloads.sh" >&2
  echo "  • PolicyLoadError on DEK GET → broken Rego syntax; re-run make promote-production-policy" >&2
  exit 1
}

oc whoami >/dev/null || { echo "oc login required" >&2; exit 1; }

section "Act II — restart golden pod (re-attest under production pins)"
POLICY_FILE="${POLICY_FILE:-$SCRIPT_DIR/../policy/kbs-resource-policy-snp-production.rego}"
DEMO_POLICY="$SCRIPT_DIR/../policy/kbs-resource-policy-snp-demo.rego"
if [[ -f "$POLICY_FILE" ]]; then
  echo "Production policy on disk ($(basename "$POLICY_FILE")):"
  cat "$POLICY_FILE"
  echo ""
  if [[ -f "$DEMO_POLICY" ]]; then
    echo "Diff vs staging (demo) rule:"
    diff -u "$DEMO_POLICY" "$POLICY_FILE" | head -60 || true
    echo ""
  fi
fi
echo "Live policy on KBS (first 45 lines):"
oc get configmap trusteeconfig-resource-policy -n "$TRUSTEE_NS" \
  -o jsonpath='{.data.policy\.rego}' 2>/dev/null | head -45 || true
echo ""
echo "Pinned policy is on KBS; warm memory is not enough for the demo."
echo "Deleting the confidential pod forces CDH → attest → DEK GET against pinned Rego."
echo ""

if [[ -f "$PINS_FILE" ]]; then
  echo "Golden pins file: $PINS_FILE"
  jq -r '"  measurement=\(.measurement[0:20])… pcr11=\(.pcr11[0:16])…"' "$PINS_FILE" 2>/dev/null || true
  echo ""
fi

if oc get pods -n "$NS" -l demo-role=confidential --field-selector=status.phase=Terminating -o name 2>/dev/null | grep -q .; then
  echo "WARN: confidential pod(s) stuck Terminating — using FORCE_POD_DELETE=1"
  FORCE_POD_DELETE=1 bash "$SCRIPT_DIR/kbs/restart-confidential-workloads.sh"
else
  bash "$SCRIPT_DIR/kbs/restart-confidential-workloads.sh"
fi

section "Wait for confidential Ready (peer-pod CVM often 15–30+ min)"
if ! oc rollout status "deployment/inference-confidential" -n "$NS" --timeout="${ROLLOUT_TIMEOUT}s"; then
  fail_act_ii "rollout did not become Ready within ${ROLLOUT_TIMEOUT}s"
fi

GOLDEN_POD=""
while read -r name ready; do
  [[ "$ready" == "true" ]] && GOLDEN_POD="$name" && break
done < <(oc get pods -n "$NS" -l demo-role=confidential \
  -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready --no-headers 2>/dev/null)
if [[ -z "$GOLDEN_POD" ]]; then
  GOLDEN_POD="$(oc get pods -n "$NS" -l demo-role=confidential \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  phase="$(oc get pod -n "$NS" "$GOLDEN_POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  ready="$(oc get pod -n "$NS" "$GOLDEN_POD" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)"
  reason="$(oc get pod -n "$NS" "$GOLDEN_POD" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
  echo "Pod $GOLDEN_POD phase=$phase ready=$ready reason=${reason:-—}"
  if [[ "$reason" == "CreateContainerError" ]] || [[ "$ready" != "true" ]]; then
    oc logs -n "$TRUSTEE_NS" deployment/trustee-deployment --tail=40 \
      | grep -E 'tee=|confidential-inferencing-dek|PolicyDeny|PolicyLoadError' | tail -15 || true
    fail_act_ii "confidential pod not Ready (often PolicyDeny — pins do not match current initdata/CVM)"
  fi
fi
[[ -n "$GOLDEN_POD" ]] || fail_act_ii "no confidential pod found"
echo "Golden pod: $GOLDEN_POD"

section "Pod logs — expect CDH REST + DEK fetched (not PolicyDeny / Sample)"
oc logs -n "$NS" "$GOLDEN_POD" -c inference --tail=40 \
  | grep -E 'CDH REST|DEK fetched|Decrypting|PolicyDeny|Sample|Waiting for CDH' \
  || oc logs -n "$NS" "$GOLDEN_POD" -c inference --tail=20

section "Trustee — expect tee=AzSnpVtpm + DEK GET 200 (not PolicyDeny)"
oc logs -n "$TRUSTEE_NS" deployment/trustee-deployment --tail=120 \
  | grep -E 'tee=|confidential-inferencing-dek|PolicyDeny' | tail -25 \
  || echo "(no matching Trustee lines yet — check after pod boot completes)"

section "Prompt all three arms (Act II)"
DEMO_ACT=ii PROMPT="${PROMPT:-encrypted model weights stay ciphertext until}" \
  bash "$SCRIPT_DIR/demo-prompt.sh"

cat <<EOF

Act II complete — golden pod re-attested under pinned policy and still serves.

Next (Act III — mismatch replica only; golden already proven):
  make demo-act-iii

EOF
