#!/usr/bin/env bash
# Validate runtime DEK fetch path (CDH REST vs socket vs kbs-client) and related deployment guards.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
load_repo_defaults

STRICT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict) STRICT=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--strict]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

reset_counters
echo "==> Runtime DEK fetch path (workload container)"
echo "Repo: $REPO_ROOT"
echo ""

ep="$REPO_ROOT/container/entrypoint.sh"
df="$REPO_ROOT/container/Dockerfile"
dep="$REPO_ROOT/deploy/deployment-confidential.yaml"
cm="$REPO_ROOT/deploy/configmap-entrypoint.yaml"

if [[ -f "$ep" ]]; then
  if grep -q 'fetch_dek_via_cdh_rest' "$ep"; then
    log_ok "entrypoint tries CDH REST (127.0.0.1:8006) before socket / kbs-client"
  else
    log_fail "entrypoint missing fetch_dek_via_cdh_rest — workload containers cannot rely on cdh.sock"
  fi
  if grep -q 'fetch_dek_via_cdh_tool' "$ep"; then
    log_ok "unix-socket fallback present (ttrpc-cdh-tool)"
  fi
  if grep -q 'debug_cdh_visibility' "$ep"; then
    log_ok "failure path logs CDH visibility hints"
  fi
  if grep -q 'fetch_dek_via_kbs_client' "$ep"; then
    log_info "kbs-client fallback retained (baseline / non-CVM only)"
  fi
else
  log_fail "missing container/entrypoint.sh"
fi

if [[ -f "$cm" ]] && [[ -f "$ep" ]]; then
  if ! grep -q 'fetch_dek_via_cdh_rest' "$cm"; then
    log_warn "deploy/configmap-entrypoint.yaml out of date — run scripts/generate-entrypoint-configmap.sh"
  else
    log_ok "ConfigMap entrypoint includes CDH REST path"
  fi
fi

if [[ -f "$df" ]]; then
  if grep -qE '^USER[[:space:]]+[0-9]+' "$df"; then
    log_ok "Dockerfile USER set ($(grep -E '^USER' "$df" | tail -1))"
  else
    log_fail "Dockerfile missing USER — kata-remote SCC rejects root-default images"
  fi
  if grep -q '\bcurl\b' "$df"; then
    log_ok "Dockerfile includes curl for CDH REST"
  else
    log_warn "Dockerfile missing curl"
  fi
  if grep -qE 'COPY.*dek\.bin|ENV.*DEK' "$df"; then
    log_fail "Dockerfile may embed DEK material — keys must live in KBS only"
  else
    log_ok "Dockerfile does not COPY dek.bin"
  fi
else
  log_warn "missing container/Dockerfile"
fi

if [[ -f "$dep" ]]; then
  if grep -q 'hostPath' "$dep" && grep -q 'confidential-containers' "$dep"; then
    log_fail "deployment hostPath on /run/confidential-containers — masks guest CDH paths"
  else
    log_ok "no hostPath on guest CDH paths"
  fi
  if grep -q 'runtimeClassName: kata-remote' "$dep"; then
    log_ok "confidential deployment uses kata-remote"
  else
    log_fail "confidential deployment missing runtimeClassName: kata-remote"
  fi
  if grep -qE 'runAsUser:[[:space:]]*[0-9]+' "$dep"; then
    log_warn "deployment sets runAsUser — prefer USER in Dockerfile when only for SCC"
  fi
  wait_secs="$(grep -A1 'CDH_DEK_WAIT_SECS' "$dep" | grep 'value:' | sed -E 's/.*value: "//;s/".*//' || echo 120)"
  live_init="$(grep -A5 'livenessProbe:' "$dep" | grep 'initialDelaySeconds:' | awk '{print $2}' || echo 0)"
  ready_init="$(grep -A6 'readinessProbe:' "$dep" | grep 'initialDelaySeconds:' | awk '{print $2}' || echo 0)"
  if [[ "$live_init" -lt "$wait_secs" ]]; then
    log_warn "liveness initialDelaySeconds ($live_init) < CDH_DEK_WAIT_SECS ($wait_secs) — probe may kill pod during DEK wait"
  else
    log_ok "liveness probe allows CDH wait window (init ${live_init}s, wait ${wait_secs}s)"
  fi
else
  log_warn "missing deploy/deployment-confidential.yaml"
fi

summary_exit "$STRICT"
