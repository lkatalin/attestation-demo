#!/usr/bin/env bash
# RVPS / initdata endorsement consistency (offline + optional cluster compare).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
load_repo_defaults

INITDATA=""
RVPS_JSON=""
STRICT=0
USE_CLUSTER=0

usage() {
  cat <<EOF
Usage: $0 [options]

  --initdata PATH       initdata.toml (default: search kbs-tee-attestation/output, coco-infra)
  --rvps PATH           reference-values.json (optional local RVPS export)
  --cluster             Compare local initdata to peer-pods-cm INITDATA on logged-in cluster
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --initdata) INITDATA="$2"; shift 2 ;;
    --rvps) RVPS_JSON="$2"; shift 2 ;;
    --cluster) USE_CLUSTER=1; shift ;;
    --strict) STRICT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

find_initdata() {
  local candidates=(
    "$INITDATA"
    "$REPO_ROOT/kbs-tee-attestation/output/initdata.toml"
    "$REPO_ROOT/../coco-infra/aro/trustee/initdata.toml"
    "$REPO_ROOT/artifacts/initdata-work/initdata-with-dek-credential.toml"
  )
  for c in "${candidates[@]}"; do
    [[ -n "$c" && -f "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}

reset_counters
echo "==> RVPS / initdata endorsement consistency"
echo ""

INITDATA="$(find_initdata || true)"
if [[ -z "$INITDATA" ]]; then
  log_fail "no initdata.toml found — pass --initdata or run configure-trustee.sh"
  summary_exit "$STRICT"
  exit "$DRY_RUN_FAIL"
fi
log_ok "initdata: $INITDATA"

if grep -qE '^algorithm[[:space:]]*=' "$INITDATA" && grep -qE '^version[[:space:]]*=' "$INITDATA"; then
  algo="$(grep -E '^algorithm' "$INITDATA" | head -1 | sed 's/.*=[[:space:]]*//;s/"//g')"
  ver="$(grep -E '^version' "$INITDATA" | head -1 | sed 's/.*=[[:space:]]*//;s/"//g')"
  log_ok "initdata metadata algorithm=$algo version=$ver"
else
  log_warn "initdata missing algorithm/version header"
fi

if grep -q '"aa.toml"' "$INITDATA" && grep -q '"cdh.toml"' "$INITDATA"; then
  log_ok "initdata embeds aa.toml and cdh.toml"
else
  log_fail "initdata missing aa.toml or cdh.toml blocks"
fi

local_hash="$(initdata_sha256 "$INITDATA")"
log_ok "initdata content sha256: ${local_hash:0:16}…"

if [[ -n "$RVPS_JSON" && -f "$RVPS_JSON" ]]; then
  log_ok "local RVPS reference: $RVPS_JSON"
  if jq empty "$RVPS_JSON" 2>/dev/null; then
    log_ok "RVPS JSON valid"
    count="$(jq 'length' "$RVPS_JSON" 2>/dev/null || echo 0)"
    [[ "$count" -gt 0 ]] && log_ok "RVPS contains $count reference entries" || log_warn "RVPS JSON empty"
  else
    log_fail "invalid RVPS JSON: $RVPS_JSON"
  fi
  if [[ "$INITDATA" -nt "$RVPS_JSON" ]]; then
    log_warn "initdata newer than RVPS file — regenerate RVPS after pod VM image change"
  else
    log_ok "initdata not newer than local RVPS export"
  fi
elif oc_available; then
  rvps_cm="$TRUSTEE_NS/trusteeconfig-rvps-reference-values"
  if oc get configmap trusteeconfig-rvps-reference-values -n "$TRUSTEE_NS" >/dev/null 2>&1; then
    log_ok "cluster RVPS ConfigMap present ($rvps_cm)"
    oc get configmap trusteeconfig-rvps-reference-values -n "$TRUSTEE_NS" \
      -o jsonpath='{.data.reference-values\.json}' 2>/dev/null | jq empty 2>/dev/null \
      && log_ok "cluster RVPS JSON parseable" \
      || log_warn "cluster RVPS JSON missing or invalid"
  else
    log_warn "cluster RVPS ConfigMap not found — run coco-infra configure-trustee.sh"
  fi
else
  log_warn "no --rvps file and no cluster access — RVPS endorsement not verified"
fi

if [[ "$USE_CLUSTER" -eq 1 ]]; then
  if oc_available; then
    echo ""
    echo "==> Cluster initdata compare"
    b64="$(oc get configmap peer-pods-cm -n "$PEER_NS" -o jsonpath='{.data.INITDATA}' 2>/dev/null || true)"
    if [[ -n "$b64" ]]; then
      tmp="$(mktemp)"
      cluster_initdata_decode "$b64" "$tmp"
      cluster_hash="$(initdata_sha256 "$tmp")"
      if [[ "$local_hash" == "$cluster_hash" ]]; then
        log_ok "local initdata matches peer-pods-cm INITDATA hash"
      else
        log_fail "local initdata differs from peer-pods-cm INITDATA — re-apply initdata or refresh bundle"
        log_info "local:   $local_hash"
        log_info "cluster: $cluster_hash"
      fi
      rm -f "$tmp"
    else
      log_fail "peer-pods-cm has no INITDATA field"
    fi
  else
    log_fail "--cluster requested but oc not logged in"
  fi
fi

summary_exit "$STRICT"
