#!/usr/bin/env bash
# LEGACY: capture from inference-confidential via host port-forward (unreliable on OSC peer pods).
#
# Prefer: make capture-golden-claims  (attest-probe pod, curls /aa/token inside CVM netns)
#
# Prerequisites on peer pods: make enable-peer-pods-guest-rest-api
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
# shellcheck source=../scripts/defaults.sh
source "$REPO_ROOT/scripts/defaults.sh"

OUT_DIR="$ROOT/captured"
LABEL="${LABEL:-golden}"
POD=""
CONTAINER="${CONTAINER:-inference}"
AA_URL="${AA_TOKEN_URL:-/aa/token?token_type=kbs}"
GUEST_REST_PORT="${GUEST_REST_PORT:-8006}"
LOCAL_REST_PORT="${LOCAL_REST_PORT:-18006}"
RUN_CAPTURE=1
VIA=""
TRUSTEE_RUST_LOG="${TRUSTEE_RUST_LOG:-kbs=debug,attestation_service=debug,attestation_service::token=trace,actix_web=info}"
RESTART_INFERENCE="${RESTART_INFERENCE:-0}"
WAIT_READY="${WAIT_READY:-1}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-900}"
ANY_READY="${ANY_READY:-0}"

usage() {
  cat <<EOF
Usage: $0 [options]

  Capture attestation claims (legacy — prefer: make capture-golden-claims).

Options:
  --label NAME           Output basename (default: golden)
  --pod NAME             Pod (default: wait for Ready on latest deployment revision)
  --namespace NS
  --out-dir PATH         (default: policy-dry-run/captured/)
  --via METHOD           auto | aa | trustee | logs (default: auto)
  --wait                 Wait for Ready pod (default; CVM 15–30+ min)
  --no-wait              Fail if no Ready pod
  --wait-timeout SEC     Max wait (default: 900)
  --restart-inference    Delete confidential pod to force fresh attest (slow)
  --jwt-only             Skip capture-claims.sh
  -h, --help

Production capture on OSC peer pods:
  make enable-peer-pods-guest-rest-api
  make capture-golden-claims
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) LABEL="$2"; shift 2 ;;
    --pod) POD="$2"; shift 2 ;;
    --namespace) DEMO_NAMESPACE="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --via) VIA="$2"; shift 2 ;;
    --wait) WAIT_READY=1; shift ;;
    --no-wait) WAIT_READY=0; shift ;;
    --wait-timeout) WAIT_TIMEOUT_SEC="$2"; shift 2 ;;
    --any-ready) ANY_READY=1; shift ;;
    --restart-inference) RESTART_INFERENCE=1; shift ;;
    --jwt-only) RUN_CAPTURE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 2
  }
}

need_cmd oc
need_cmd jq
need_cmd curl
need_cmd python3
oc whoami >/dev/null || { echo "oc login required" >&2; exit 1; }

latest_confidential_rs() {
  oc get rs -n "$DEMO_NAMESPACE" -l app=inference-confidential \
    -o jsonpath='{range .items[*]}{.metadata.annotations.deployment\.kubernetes\.io/revision}{"\t"}{.metadata.name}{"\n"}{end}' \
    2>/dev/null | sort -n | tail -1 | cut -f2
}

ready_confidential_pod() {
  local rs pod
  if [[ "$ANY_READY" == "1" || -n "$POD" ]]; then
    oc get pods -n "$DEMO_NAMESPACE" -l app=inference-confidential \
      -o jsonpath='{range .items[?(@.status.containerStatuses[0].ready==true)]}{.metadata.name}{"\n"}{end}' \
      2>/dev/null | head -1
    return 0
  fi
  rs="$(latest_confidential_rs)"
  if [[ -n "$rs" ]]; then
    pod="$(oc get pods -n "$DEMO_NAMESPACE" -l app=inference-confidential \
      -o jsonpath="{range .items[?(@.metadata.ownerReferences[0].name=='$rs' && @.status.containerStatuses[0].ready==true)]}{.metadata.name}{\"\\n\"}{end}" \
      2>/dev/null | head -1)"
    [[ -n "$pod" ]] && { echo "$pod"; return 0; }
  fi
  echo ""
}

rollout_sandbox_blocker() {
  local pod msg
  pod="$(oc get pods -n "$DEMO_NAMESPACE" -l app=inference-confidential \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)"
  [[ -n "$pod" ]] || return 1

  msg="$(oc get events -n "$DEMO_NAMESPACE" --field-selector "involvedObject.name=$pod" \
    -o jsonpath='{range .items[*]}{.reason}{"\t"}{.message}{"\n"}{end}' 2>/dev/null \
    | grep -E 'FailedCreatePodSandBox|kernel_params' | tail -1 || true)"
  [[ -n "$msg" ]] || return 1
  echo "$msg"
  return 0
}

report_rollout_blocker() {
  local blocker any_ready
  blocker="$(rollout_sandbox_blocker || true)"
  [[ -n "$blocker" ]] || return 1

  any_ready="$(oc get pods -n "$DEMO_NAMESPACE" -l app=inference-confidential \
    -o jsonpath='{range .items[?(@.status.containerStatuses[0].ready==true)]}{.metadata.name}{"\n"}{end}' \
    2>/dev/null | head -1)"

  echo "" >&2
  echo "New confidential pod cannot start (sandbox blocked):" >&2
  echo "  $blocker" >&2
  echo "" >&2
  echo "This cluster does not allow io.katacontainers.config.hypervisor.kernel_params." >&2
  echo "Capture is waiting for the NEW revision pod — it will never become Ready." >&2
  if [[ -n "$any_ready" ]]; then
    echo "An OLD revision pod is Ready ($any_ready) but lacks /aa/token." >&2
  fi
  echo "" >&2
  echo "Fix:" >&2
  echo "  make enable-peer-pods-guest-rest-api" >&2
  echo "  make disable-guest-attestation-rest-api   # remove broken deployment annotation" >&2
  echo "  make capture-golden-claims                # attest-probe (recommended)" >&2
  return 0
}

wait_for_ready_pod() {
  [[ -n "$POD" ]] && return 0

  POD="$(ready_confidential_pod)"
  [[ -n "$POD" ]] && return 0

  if [[ "$WAIT_READY" != "1" ]]; then
    echo "No Ready inference-confidential pod in $DEMO_NAMESPACE" >&2
    echo "  Peer-pod CVM boot can take 15–30+ min after pod delete." >&2
    echo "  Wait: oc rollout status deployment/inference-confidential -n $DEMO_NAMESPACE --timeout=900s" >&2
    echo "  Or:   make capture-golden-claims   # waits by default" >&2
    exit 1
  fi

  local target_rs any_ready
  target_rs="$(latest_confidential_rs)"
  any_ready="$(oc get pods -n "$DEMO_NAMESPACE" -l app=inference-confidential \
    -o jsonpath='{range .items[?(@.status.containerStatuses[0].ready==true)]}{.metadata.name}{"\n"}{end}' \
    2>/dev/null | head -1)"
  echo "==> Waiting for Ready inference-confidential pod (timeout ${WAIT_TIMEOUT_SEC}s)"
  echo "    Peer-pod CVM first boot often takes 15–30+ minutes."
  [[ -n "$target_rs" ]] && echo "    Target replica set: $target_rs (latest deployment revision)"
  if [[ -n "$any_ready" ]]; then
    echo "    Note: $any_ready is Ready on an older revision — ignored until latest revision is Ready."
    echo "          Use ANY_READY=1 to capture from the older pod (Trustee logs; no /aa/token)."
  fi
  local start=$SECONDS
  while (( SECONDS - start < WAIT_TIMEOUT_SEC )); do
    if report_rollout_blocker; then
      exit 1
    fi
    POD="$(ready_confidential_pod)"
    if [[ -n "$POD" ]]; then
      echo "    Ready: $POD"
      return 0
    fi
    local latest phase ready rs
    rs="$(latest_confidential_rs)"
    latest="$(oc get pods -n "$DEMO_NAMESPACE" -l app=inference-confidential \
      --sort-by=.metadata.creationTimestamp \
      -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)"
    if [[ -n "$latest" ]]; then
      phase="$(oc get pod -n "$DEMO_NAMESPACE" "$latest" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      ready="$(oc get pod -n "$DEMO_NAMESPACE" "$latest" \
        -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)"
      echo "    … ${latest} phase=${phase:-?} ready=${ready:-false} ($(( SECONDS - start ))s elapsed)"
    else
      echo "    … no pod yet ($(( SECONDS - start ))s elapsed)"
    fi
    if [[ -n "$rs" && -n "$target_rs" && "$rs" != "$target_rs" ]]; then
      target_rs="$rs"
      echo "    Target replica set: $target_rs"
    fi
    sleep 20
  done

  echo "Timed out waiting for Ready pod (${WAIT_TIMEOUT_SEC}s)" >&2
  echo "  oc get pods -n $DEMO_NAMESPACE -l app=inference-confidential -w" >&2
  exit 1
}

wait_for_ready_pod

[[ -n "$POD" ]] || {
  echo "No Ready inference-confidential pod in $DEMO_NAMESPACE" >&2
  exit 1
}

PF_PID=""
cleanup() {
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null && wait "$PF_PID" 2>/dev/null || true
  PF_PID=""
}
trap cleanup EXIT

start_port_forward() {
  cleanup
  local tries=0
  while [[ "$tries" -lt 5 ]]; do
    oc port-forward -n "$DEMO_NAMESPACE" "pod/$POD" "${LOCAL_REST_PORT}:${GUEST_REST_PORT}" &
    PF_PID=$!
    sleep 3
    if kill -0 "$PF_PID" 2>/dev/null; then
      return 0
    fi
    cleanup
    tries=$((tries + 1))
    LOCAL_REST_PORT=$((LOCAL_REST_PORT + 1))
  done
  echo "Failed to establish port-forward to pod/$POD:${GUEST_REST_PORT}" >&2
  return 1
}

pod_http() {
  local path="$1"
  local extra_args=("${@:2}")
  start_port_forward || return 1
  curl -sS --connect-timeout 5 --max-time 60 \
    "${extra_args[@]}" \
    "http://127.0.0.1:${LOCAL_REST_PORT}${path}" 2>&1
}

JWT=""
METHOD_USED=""
CLAIMS_FILE=""

write_jwt_and_claims() {
  local jwt_or_doc="$1"
  mkdir -p "$OUT_DIR"
  CLAIMS_FILE="$OUT_DIR/golden-claims.json"

  if [[ "$jwt_or_doc" == "{"* ]]; then
    echo "$jwt_or_doc" | jq . >"$CLAIMS_FILE"
    echo "  wrote $CLAIMS_FILE (constructed claims JSON)"
    return 0
  fi

  local jwt_file="$OUT_DIR/golden.jwt"
  printf '%s\n' "$jwt_or_doc" >"$jwt_file"
  python3 - "$jwt_or_doc" "$CLAIMS_FILE" <<'PY'
import base64, json, sys

def b64url_decode(data: str) -> bytes:
    pad = "=" * (-len(data) % 4)
    return base64.urlsafe_b64decode(data + pad)

jwt = sys.argv[1].strip()
parts = jwt.split(".")
payload = json.loads(b64url_decode(parts[1]))
json.dump(payload, open(sys.argv[2], "w", encoding="utf-8"), indent=2)
PY
  echo "  wrote $jwt_file"
  echo "  wrote $CLAIMS_FILE"
}

extract_jwt_from_logs() {
  python3 - <<'PY'
import base64, json, re, sys

def b64url_decode(data: str) -> bytes:
    pad = "=" * (-len(data) % 4)
    return base64.urlsafe_b64decode(data + pad)

def valid_snp_jwt(jwt: str) -> bool:
    parts = jwt.split(".")
    if len(parts) < 2:
        return False
    try:
        payload = json.loads(b64url_decode(parts[1]))
    except Exception:
        return False
    ev = (
        payload.get("submods", {})
        .get("cpu0", {})
        .get("ear.veraison.annotated-evidence", {})
        .get("az-snp-vtpm", {})
    )
    return bool(ev.get("measurement"))

log = sys.stdin.read()

for m in re.finditer(r'"token"\s*:\s*"(eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)"', log):
    if valid_snp_jwt(m.group(1)):
        print(m.group(1))
        sys.exit(0)

for m in re.finditer(r'(eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)', log):
    if valid_snp_jwt(m.group(1)):
        print(m.group(1))
        sys.exit(0)

sys.exit(1)
PY
}

extract_pins_from_logs() {
  python3 - <<'PY'
import json, re, sys

log = sys.stdin.read()
chunks = re.split(r'tee=AzSnpVtpm', log)
tail = chunks[-1] if chunks else log

def find_meas(text: str):
    for p in (
        r'"measurement"\s*:\s*"([0-9a-fA-F]{64})"',
        r'measurement[=:\s"]+([0-9a-fA-F]{64})',
    ):
        m = re.findall(p, text)
        if m:
            return m[-1].lower()
    return None

def find_pcr(text: str):
    for p in (
        r'"pcr11"\s*:\s*"([0-9a-fA-F]+)"',
        r'pcr11[=:\s"]+([0-9a-fA-F]{8,128})',
    ):
        m = re.findall(p, text)
        if m:
            return m[-1].lower()
    return None

meas = find_meas(tail) or find_meas(log)
pcr = find_pcr(tail) or find_pcr(log)
if not meas:
    sys.exit(1)

doc = {
    "submods": {
        "cpu0": {
            "ear.status": "affirming",
            "ear.veraison.annotated-evidence": {
                "az-snp-vtpm": {
                    "measurement": meas,
                    "tpm": {"pcr11": pcr or ""},
                }
            },
        }
    }
}
print(json.dumps(doc))
PY
}

try_pod_logs() {
  echo "==> Method: pod logs (oc logs — no exec)"
  local logs doc
  logs="$(oc logs -n "$DEMO_NAMESPACE" "$POD" -c "$CONTAINER" --tail=5000 2>/dev/null || true)"
  logs+=$'\n'
  logs+="$(fetch_trustee_logs "24h")"
  doc="$(echo "$logs" | extract_pins_from_logs || true)"
  [[ -n "$doc" ]] || return 1
  local pcr
  pcr="$(echo "$doc" | jq -r '.submods.cpu0["ear.veraison.annotated-evidence"]["az-snp-vtpm"].tpm.pcr11 // empty')"
  [[ -n "$pcr" ]] || return 1
  JWT="$doc"
  METHOD_USED="pod+trustee-logs-grep"
  return 0
}

fetch_trustee_logs() {
  local since="${1:-2h}"
  oc logs -n "$TRUSTEE_NS" deployment/trustee-deployment --since="$since" 2>/dev/null \
    || oc logs -n "$TRUSTEE_NS" deployment/trustee-deployment --tail=50000 2>/dev/null \
    || true
}

trustee_debug_on() {
  local trust_dep=trustee-deployment
  TRUSTEE_PREV_RUST_LOG="$(oc get deploy "$trust_dep" -n "$TRUSTEE_NS" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="RUST_LOG")].value}' 2>/dev/null || true)"
  echo "    Trustee debug logging (temporary): $TRUSTEE_RUST_LOG"
  oc set env "deployment/$trust_dep" -n "$TRUSTEE_NS" "RUST_LOG=$TRUSTEE_RUST_LOG" >/dev/null
  oc rollout status "deployment/$trust_dep" -n "$TRUSTEE_NS" --timeout=180s
}

trustee_debug_restore() {
  local trust_dep=trustee-deployment
  if [[ -n "${TRUSTEE_PREV_RUST_LOG:-}" ]]; then
    oc set env "deployment/$trust_dep" -n "$TRUSTEE_NS" "RUST_LOG=$TRUSTEE_PREV_RUST_LOG" >/dev/null
  else
    oc set env "deployment/$trust_dep" -n "$TRUSTEE_NS" RUST_LOG- >/dev/null
  fi
  oc rollout status "deployment/$trust_dep" -n "$TRUSTEE_NS" --timeout=180s >/dev/null 2>&1 || true
}

trigger_fresh_attest() {
  local resource_path="${KBS_RESOURCE_PATH:-default/confidential-inferencing-dek/dek}"
  echo "    Trigger CDH resource fetch via port-forward (may re-attest)"
  pod_http "/cdh/resource/${resource_path}" -o /dev/null -w 'CDH HTTP:%{http_code}\n' || true

  if [[ "$RESTART_INFERENCE" == "1" ]]; then
    echo "    Deleting pod $POD to force fresh CVM boot (slow)"
    oc delete pod -n "$DEMO_NAMESPACE" "$POD" --wait=false
    echo "    Wait for Ready, then re-run capture"
    exit 0
  fi
}

try_aa_token() {
  echo "==> Method: AA REST via port-forward (:${GUEST_REST_PORT}${AA_URL})"
  local raw http_code body
  raw="$(pod_http "$AA_URL" -w '\n__HTTP__:%{http_code}' 2>&1 || true)"
  http_code="$(echo "$raw" | sed -n 's/^__HTTP__://p' | tail -1)"
  body="$(echo "$raw" | sed '/^__HTTP__:/d')"

  if [[ "$http_code" == "200" ]]; then
    JWT="$(echo "$body" | jq -r '.token // empty' 2>/dev/null || true)"
    if [[ -n "$JWT" && "$JWT" != "null" ]]; then
      METHOD_USED="aa-rest"
      return 0
    fi
  fi

  echo "    AA REST HTTP ${http_code:-failed}"
  if [[ "$http_code" == "404" ]]; then
    echo "    /aa/token disabled — need agent.guest_components_rest_api=all on a new CVM"
    echo "    make enable-guest-attestation-rest-api && oc delete pod …"
  fi
  [[ -n "$body" ]] && echo "    Body: $(echo "$body" | tr '\n' ' ' | head -c 180)"
  return 1
}

try_trustee_logs() {
  echo "==> Method: Trustee logs (JWT or measurement/pcr11 grep)"
  trustee_debug_on
  trigger_fresh_attest

  local logs jwt doc i
  for i in 1 2 3; do
    logs="$(fetch_trustee_logs "30m")"
    jwt="$(echo "$logs" | extract_jwt_from_logs || true)"
    if [[ -n "$jwt" ]]; then
      JWT="$jwt"
      METHOD_USED="trustee-jwt"
      trustee_debug_restore
      return 0
    fi
    doc="$(echo "$logs" | extract_pins_from_logs || true)"
    if [[ -n "$doc" ]]; then
      JWT="$doc"
      METHOD_USED="trustee-pins-grep"
      trustee_debug_restore
      return 0
    fi
    [[ "$i" -lt 3 ]] && sleep 5
  done

  trustee_debug_restore
  echo "    No JWT or measurement/pcr11 found in Trustee logs (last 30m)."
  return 1
}

try_rvps_plus_logs() {
  echo "==> Method: RVPS launch measurement + Trustee pcr11 grep"
  local rvps logs pcr doc meas
  rvps="$(oc get configmap trusteeconfig-rvps-reference-values -n "$TRUSTEE_NS" \
    -o jsonpath='{.data.reference-values\.json}' 2>/dev/null || true)"
  [[ -n "$rvps" ]] || return 1

  meas="$(echo "$rvps" | jq -r '
    .. | objects
    | select(has("measurement") and (.measurement | type) == "string")
    | .measurement
    | select(length >= 32)
  ' 2>/dev/null | head -1)"
  [[ -n "$meas" && "$meas" != "null" ]] || \
    meas="$(echo "$rvps" | jq -r '.. | strings | select(test("^[0-9a-fA-F]{64}$"))' 2>/dev/null | head -1)"
  [[ -n "$meas" ]] || return 1

  logs="$(fetch_trustee_logs "24h")"
  pcr="$(echo "$logs" | extract_pins_from_logs | jq -r '.submods.cpu0["ear.veraison.annotated-evidence"]["az-snp-vtpm"].tpm.pcr11 // empty' 2>/dev/null || true)"

  doc="$(jq -n \
    --arg m "$meas" \
    --arg p "${pcr:-}" \
    '{
      submods: {
        cpu0: {
          "ear.status": "affirming",
          "ear.veraison.annotated-evidence": {
            "az-snp-vtpm": {
              measurement: $m,
              tpm: { pcr11: $p }
            }
          }
        }
      }
    }')"

  if [[ -z "$pcr" ]]; then
    echo "    WARN: got RVPS measurement but no pcr11 in logs — production policy needs both" >&2
    return 1
  fi

  JWT="$doc"
  METHOD_USED="rvps+logs"
  return 0
}

run_auto() {
  try_aa_token && return 0
  try_trustee_logs && return 0
  try_pod_logs && return 0
  try_rvps_plus_logs && return 0
  return 1
}

case "${VIA:-auto}" in
  aa) try_aa_token || exit 1 ;;
  trustee|logs) try_trustee_logs || try_rvps_plus_logs || exit 1 ;;
  auto) run_auto || {
    echo "" >&2
    echo "All capture methods failed." >&2
    echo "" >&2
    echo "On OSC peer pods, host port-forward to guest :8006 is unreliable." >&2
    echo "Use attest-probe capture instead:" >&2
    echo "" >&2
    echo "  make enable-peer-pods-guest-rest-api" >&2
    echo "  make capture-golden-claims" >&2
    exit 1
  } ;;
  *)
    echo "Unknown --via: $VIA" >&2
    exit 2
    ;;
esac

echo "    captured via $METHOD_USED"
write_jwt_and_claims "$JWT"

if ! jq -e '.submods.cpu0["ear.veraison.annotated-evidence"]["az-snp-vtpm"].measurement' \
  "$CLAIMS_FILE" >/dev/null; then
  echo "FAIL: claims missing az-snp-vtpm measurement" >&2
  exit 1
fi

pcr_check="$(jq -r '.submods.cpu0["ear.veraison.annotated-evidence"]["az-snp-vtpm"].tpm.pcr11 // empty' "$CLAIMS_FILE")"
if [[ -z "$pcr_check" ]]; then
  echo "FAIL: claims missing pcr11 (required for production policy)" >&2
  exit 1
fi

MEAS="$(jq -r '.submods.cpu0["ear.veraison.annotated-evidence"]["az-snp-vtpm"].measurement' "$CLAIMS_FILE")"
echo "  measurement=${MEAS:0:16}…"
echo "  pcr11=${pcr_check:0:16}…"

if [[ "$RUN_CAPTURE" -eq 1 ]]; then
  echo ""
  bash "$ROOT/capture-claims.sh" --from "$CLAIMS_FILE" --label "$LABEL" --out-dir "$OUT_DIR"
fi

echo ""
echo "Next:"
echo "  bash scripts/kbs/generate-production-policy.sh --pins $OUT_DIR/cvm-pins-${LABEL}.json"
echo "  make apply-production-resource-policy"
