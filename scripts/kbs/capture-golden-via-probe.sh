#!/usr/bin/env bash
# Capture golden CVM pins via attest-probe (kata-remote).
#
# Required workflow on OpenShift Sandboxed Containers peer pods:
#   1. make enable-peer-pods-guest-rest-api   (once per cluster / after OSC upgrade)
#   2. make capture-golden-claims           (this script)
#
# Curls http://127.0.0.1:8006/aa/token from inside the CVM pod netns — not host port-forward.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../defaults.sh
source "$SCRIPT_DIR/../defaults.sh"

PROBE_NAME="${PROBE_NAME:-attest-probe}"
PROBE_MANIFEST="$SCRIPT_DIR/attest-probe-pod.yaml"
LABEL="${LABEL:-golden}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-900}"
OUT_DIR="$ROOT/policy-dry-run/captured"
SKIP_PREFLIGHT="${SKIP_PREFLIGHT:-0}"

usage() {
  cat <<EOF
Usage: $0 [options]

  Capture production CVM pins (measurement + pcr11) from a real KBS attestation JWT.

Prerequisites (once per cluster):
  make enable-peer-pods-guest-rest-api

Options:
  --label NAME           Output basename (default: golden)
  --timeout SEC          Wait for probe CVM + token (default: 900)
  --keep-probe           Leave attest-probe pod running after capture
  --skip-preflight       Skip kata-oc config check
  -h, --help
EOF
}

KEEP_PROBE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) LABEL="$2"; shift 2 ;;
    --timeout) WAIT_TIMEOUT_SEC="$2"; shift 2 ;;
    --keep-probe) KEEP_PROBE=1; shift ;;
    --skip-preflight) SKIP_PREFLIGHT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

oc whoami >/dev/null || { echo "oc login required" >&2; exit 1; }

preflight_guest_rest() {
  [[ "$SKIP_PREFLIGHT" == "1" ]] && return 0
  local node kp
  node="$(oc get nodes -l node-role.kubernetes.io/kata-oc= -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$node" ]] || {
    echo "WARN: no kata-oc node — skip preflight (not a peer-pod cluster?)" >&2
    return 0
  }
  echo "==> Preflight: guest REST enabled on kata-oc ($node)"
  kp="$(oc debug "node/$node" --quiet -- chroot /host \
    grep -E '^kernel_params = ' /etc/kata-containers/remote/configuration.toml 2>/dev/null \
    | head -1 || true)"
  if [[ -z "$kp" ]] || ! grep -q 'guest_components_rest_api' <<<"$kp"; then
    echo "" >&2
    echo "FAIL: /etc/kata-containers/remote/configuration.toml missing guest REST kernel_params." >&2
    echo "      OSC peer pods block per-pod annotations; patch kata-oc workers first:" >&2
    echo "" >&2
    echo "  make enable-peer-pods-guest-rest-api" >&2
    echo "" >&2
    exit 1
  fi
  echo "    $kp"
}

preflight_guest_rest

echo "==> Delete previous probe (if any)"
oc delete pod "$PROBE_NAME" -n "$DEMO_NAMESPACE" --ignore-not-found --wait=true --timeout=120s 2>/dev/null || \
  oc delete pod "$PROBE_NAME" -n "$DEMO_NAMESPACE" --ignore-not-found --force --grace-period=0 2>/dev/null || true
sleep 2

echo "==> Start attest-probe (signed image: $IMAGE)"
echo "    CVM first boot often takes 15–30+ minutes."
probe_manifest="$(mktemp)"
sed "s|\${IMAGE}|${IMAGE}|g" "$PROBE_MANIFEST" >"$probe_manifest"
oc apply -f "$probe_manifest"
rm -f "$probe_manifest"

echo "==> Wait for JWT in probe logs (timeout ${WAIT_TIMEOUT_SEC}s)"
start=$SECONDS
jwt=""
while (( SECONDS - start < WAIT_TIMEOUT_SEC )); do
  phase="$(oc get pod -n "$DEMO_NAMESPACE" "$PROBE_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  logs="$(oc logs -n "$DEMO_NAMESPACE" "$PROBE_NAME" -c probe 2>/dev/null || true)"
  if grep -q 'CAPTURE_JWT_BEGIN' <<<"$logs"; then
    jwt="$(echo "$logs" | sed -n '/CAPTURE_JWT_BEGIN/,/CAPTURE_JWT_END/p' | sed '1d;$d' | tr -d '\r')"
    [[ -n "$jwt" ]] && break
  fi
  if [[ "$phase" == "Failed" || "$phase" == "Succeeded" ]]; then
    echo "$logs" | tail -30
    if grep -q 'AA token HTTP 404' <<<"$logs"; then
      echo "" >&2
      echo "FAIL: /aa/token disabled — re-run: make enable-peer-pods-guest-rest-api" >&2
      echo "      Then delete attest-probe and re-run capture." >&2
    elif grep -q 'Image policy rejected' <<<"$logs" || grep -q 'PolicyDeny' <<<"$logs"; then
      echo "" >&2
      echo "FAIL: probe image pull denied — IMAGE must match signed inference image." >&2
      echo "      IMAGE=${IMAGE}" >&2
    fi
    break
  fi
  echo "    … probe phase=${phase:-Pending} ($(( SECONDS - start ))s)"
  sleep 20
done

if [[ -z "$jwt" ]]; then
  echo "FAIL: no JWT in probe logs within ${WAIT_TIMEOUT_SEC}s" >&2
  echo "  oc logs -n $DEMO_NAMESPACE $PROBE_NAME -c probe" >&2
  echo "  oc describe pod -n $DEMO_NAMESPACE $PROBE_NAME" >&2
  exit 1
fi

echo "==> Got JWT from attest-probe ($(echo "$jwt" | wc -c | tr -d ' ') bytes)"

mkdir -p "$OUT_DIR"
jwt_file="$OUT_DIR/golden-probe.jwt"
claims_file="$OUT_DIR/golden-claims.json"
printf '%s\n' "$jwt" >"$jwt_file"

python3 - "$jwt" "$claims_file" <<'PY'
import base64, json, sys

def b64url_decode(data: str) -> bytes:
    pad = "=" * (-len(data) % 4)
    return base64.urlsafe_b64decode(data + pad)

jwt = sys.argv[1].strip()
payload = json.loads(b64url_decode(jwt.split(".")[1]))
json.dump(payload, open(sys.argv[2], "w", encoding="utf-8"), indent=2)
PY

echo "  wrote $jwt_file"
echo "  wrote $claims_file"

bash "$ROOT/policy-dry-run/capture-claims.sh" --from "$claims_file" --label "$LABEL" --out-dir "$OUT_DIR"

if [[ "$KEEP_PROBE" != "1" ]]; then
  oc delete pod "$PROBE_NAME" -n "$DEMO_NAMESPACE" --ignore-not-found --wait=false
fi

echo ""
echo "Next:"
echo "  bash scripts/kbs/generate-production-policy.sh --pins $OUT_DIR/cvm-pins-${LABEL}.json"
echo "  make apply-production-resource-policy"
