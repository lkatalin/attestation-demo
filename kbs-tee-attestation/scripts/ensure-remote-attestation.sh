#!/usr/bin/env bash
# Ensure Trustee/KBS is configured to accept remote RCAR attestation (cross-cluster guests).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=defaults.sh
source "$SCRIPT_DIR/defaults.sh"

NS="${TRUSTEE_NS}"

oc whoami >/dev/null || { echo "oc login required (KBS cluster)" >&2; exit 1; }

echo "==> TrusteeConfig: attestation token verification (required for attestation-gated secrets)"
TOKEN_SECRET="$(oc get trusteeconfig "$TRUSTEE_CONFIG" -n "$NS" -o jsonpath='{.spec.attestationTokenVerificationSpec.tlsSecretName}' 2>/dev/null || true)"
if [[ -z "$TOKEN_SECRET" ]]; then
  echo "    Patching TrusteeConfig — enabling attestationTokenVerificationSpec"
  oc patch trusteeconfig "$TRUSTEE_CONFIG" -n "$NS" --type merge -p '{
    "spec": {
      "attestationTokenVerificationSpec": {
        "tlsSecretName": "trustee-token-cert"
      }
    }
  }'
else
  echo "    attestationTokenVerificationSpec.tlsSecretName=$TOKEN_SECRET (ok)"
fi

echo "==> KBS HTTPS route (remote guests must reach this host)"
if ! oc get route "$ROUTE_NAME" -n "$NS" &>/dev/null; then
  echo "    Creating passthrough route $ROUTE_NAME"
  oc create route passthrough "$ROUTE_NAME" \
    --service=kbs-service \
    --port=kbs-port \
    -n "$NS"
else
  echo "    Route $ROUTE_NAME exists (ok)"
fi

echo "==> KBS attestation service (built-in CoCo AS must be present)"
if ! oc get configmap trusteeconfig-kbs-config -n "$NS" -o jsonpath='{.data.kbs-config\.toml}' 2>/dev/null \
  | grep -q '^\[attestation_service\]'; then
  echo "ERROR: trusteeconfig-kbs-config missing [attestation_service] — re-run coco-infra configure-trustee" >&2
  exit 1
fi
echo "    [attestation_service] present in kbs-config.toml (ok)"

echo "==> KbsConfig resource + attestation policy wiring"
for field in kbsResourcePolicyConfigMapName kbsAttestationPolicyConfigMapName; do
  val="$(oc get kbsconfig "$KBS_CONFIG" -n "$NS" -o jsonpath="{.spec.$field}")"
  if [[ -z "$val" ]]; then
    echo "WARNING: KbsConfig spec.$field is empty — Trustee operator may not have finished reconciling" >&2
  else
    echo "    spec.$field=$val (ok)"
  fi
done

echo ""
echo "Remote attestation: guests on another cluster POST to https://<kbs-route>/kbs/v0/..."
echo "  (RCAR: /auth, /attest). No extra 'allow remote' API flag — network reachability + policies above."
