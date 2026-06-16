#!/usr/bin/env bash
# Act III — stale Rego pin deny (upgrade drill).
#
# Azure peer pods: initdata edits (CM or pod annotation) do not change SNP measurement/PCR11
# in the attestation token — same pod VM image → same fingerprint. Act III therefore applies
# production Rego pinned to a deliberately WRONG measurement while the warm golden pod keeps
# serving. A fresh replica (scale +1) attests for real but hits PolicyDeny on DEK GET.
#
# Prerequisite: Act II finished — golden pod re-booted under correct pins and is Ready.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=defaults.sh
source "$SCRIPT_DIR/defaults.sh"

NS="${DEMO_NAMESPACE}"
TRUSTEE_NS="${TRUSTEE_NS:-trustee-operator-system}"
MISMATCH_WAIT_SEC="${MISMATCH_WAIT_SEC:-900}"
PINS="${PINS:-$ROOT/policy-dry-run/captured/cvm-pins-golden.json}"
STALE_REGO="$ROOT/policy/kbs-resource-policy-snp-act-iii-stale.rego"
POLICY_BACKUP="${ARTIFACTS}/act-iii-production.rego.backup"
CURL=(curl -fsS --connect-timeout 5 --max-time 20)

section() { echo ""; echo "======== $* ========"; }

oc whoami >/dev/null || { echo "oc login required" >&2; exit 1; }
[[ -f "$PINS" ]] || { echo "Missing $PINS — run make capture-golden-claims first" >&2; exit 1; }

GOLDEN_POD="$(oc get pods -n "$NS" -l demo-role=confidential \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$GOLDEN_POD" ]] || {
  echo "No golden confidential pod — run Act II first (make demo-act-ii)" >&2
  exit 1
}

section "Act III — stale measurement pin (golden pod stays warm)"
echo "Golden pod (do not restart): $GOLDEN_POD"
echo ""
echo "On Azure peer pods, initdata changes do not alter SNP measurement in the JWT."
echo "This drill applies Rego with yesterday's pin; a new replica still does real SNP attest"
echo "but KBS denies DEK release. Golden keeps serving on the key it already earned in Act II."
echo ""

mkdir -p "${ARTIFACTS}"
cp "$ROOT/policy/kbs-resource-policy-snp-production.rego" "$POLICY_BACKUP"

bash "$ROOT/scripts/kbs/generate-act-iii-stale-policy.sh" --pins "$PINS" --out "$STALE_REGO"

section "Apply stale Rego to KBS (Trustee restart)"
SKIP_PRODUCTION_FIXTURE=1 POLICY_FILE="$STALE_REGO" \
  bash "$ROOT/scripts/kbs/apply-production-resource-policy.sh"

ORIGINAL_REPLICAS="$(oc get deployment inference-confidential -n "$NS" -o jsonpath='{.spec.replicas}')"
TARGET_REPLICAS=$((ORIGINAL_REPLICAS + 1))
echo "$ORIGINAL_REPLICAS" >"${ARTIFACTS}/act-iii-original-replicas"

section "Scale golden deployment +1 ($ORIGINAL_REPLICAS → $TARGET_REPLICAS) — fresh attest under stale pin"
oc scale deployment inference-confidential -n "$NS" --replicas="$TARGET_REPLICAS"

section "Wait for new pod — expect DEK deny (timeout ${MISMATCH_WAIT_SEC}s)"
start=$SECONDS
NEW_POD=""
while (( SECONDS - start < MISMATCH_WAIT_SEC )); do
  mapfile -t PODS < <(oc get pods -n "$NS" -l demo-role=confidential \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  if ((${#PODS[@]} >= TARGET_REPLICAS)); then
    NEW_POD="${PODS[-1]}"
    [[ "$NEW_POD" != "$GOLDEN_POD" ]] && break
  fi
  echo "    … ${#PODS[@]}/${TARGET_REPLICAS} pod(s) ($(( SECONDS - start ))s)"
  sleep 20
done

[[ -n "$NEW_POD" && "$NEW_POD" != "$GOLDEN_POD" ]] || {
  echo "FAIL: expected a new confidential pod" >&2
  oc get pods -n "$NS" -l demo-role=confidential
  exit 1
}

echo "Golden: $GOLDEN_POD"
echo "New replica (stale pin): $NEW_POD"

section "Pods — golden Ready; new replica should not decrypt"
oc get pods -n "$NS" -l demo-role=confidential \
  -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,STATUS:.status.phase

section "New replica logs — expect PolicyDeny / no Decrypting"
NEW_LOGS="$(oc logs -n "$NS" "$NEW_POD" -c inference --tail=50 2>/dev/null || true)"
if [[ -z "$NEW_LOGS" ]]; then
  echo "(still booting — oc logs -n $NS $NEW_POD -c inference)"
else
  echo "$NEW_LOGS" | grep -E 'PolicyDeny|DEK|CDH REST|Decrypting|Sample|Waiting for CDH' \
    || echo "$NEW_LOGS" | tail -25
  if echo "$NEW_LOGS" | grep -q 'Decrypting model.pt.enc'; then
    echo ""
    echo "FAIL: new replica decrypted under stale Rego — check KBS resource policy apply" >&2
    exit 1
  fi
fi

section "Trustee — expect PolicyDeny on new replica DEK GET"
oc logs -n "$TRUSTEE_NS" deployment/trustee-deployment --since=20m 2>/dev/null \
  | grep -E 'confidential-inferencing-dek|PolicyDeny' | tail -20 \
  || true

section "Show stale vs golden measurement in live Rego"
make -C "$ROOT" show-live-resource-policy 2>/dev/null | grep -E 'measurement|pcr11' || true
echo "Golden pins:"
jq -r '.measurement, .pcr11' "$PINS" | sed 's/^/  /'

section "Golden route still serves (warm DEK — no re-attest required)"
CONF_URL="https://$(oc get route inference-confidential -n "$NS" -o jsonpath='{.spec.host}')"
"${CURL[@]}" "${CONF_URL}/demo/info" | jq '{demo_runtime, model_loaded, decrypt: .decrypt_manifest.algorithm}'

cat <<EOF

Act III complete.

Cleanup (restore Act II pins + scale back):
  make demo-act-iii-cleanup

EOF
