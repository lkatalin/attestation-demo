#!/usr/bin/env bash
# Run offline production dry-run checks (CI / pre-promote gate).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
STRICT="${STRICT:-0}"
WITH_CLUSTER=0
IMAGE="${IMAGE:-}"

usage() {
  cat <<EOF
Usage: $0 [options]

  --strict              Pass --strict to all sub-checks
  --with-cluster        Include oc-dependent checks (diff-cluster-policy, rvps --cluster, slo --scrape-logs)
  --image REF           IMAGE for image-contract and diff-cluster-policy
  -h, --help

Runs (offline by default):
  dry-run.sh
  check-workload-kbs-path.sh
  check-kbs-tenancy.sh
  check-image-contract.sh
  check-remote-contract.sh
  check-rvps-initdata.sh
  dry-run-measurements.sh
  dry-run-rotation.sh
  check-platform-policy.sh
  check-attestation-slo.sh
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict) STRICT=1; shift ;;
    --with-cluster) WITH_CLUSTER=1; shift ;;
    --image) IMAGE="$2"; export IMAGE; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 2 ;;
  esac
done

strict_args=()
[[ "$STRICT" -eq 1 ]] && strict_args=(--strict)

fail=0
run() {
  local name="$1"
  shift
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  $name"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if bash "$@"; then
    return 0
  else
    fail=1
    return 0
  fi
}

export IMAGE="${IMAGE:-quay.io/lgallett/confidential-inferencing-demo:latest}"

run "Policy dry-run (Rego + cosign)" "$ROOT/dry-run.sh" "${strict_args[@]}"
run "Workload DEK path" "$ROOT/check-workload-kbs-path.sh" "${strict_args[@]}"
run "KBS tenancy" "$ROOT/check-kbs-tenancy.sh" "${strict_args[@]}"
run "Image contract" "$ROOT/check-image-contract.sh" "${strict_args[@]}"
run "Remote KBS contract" "$ROOT/check-remote-contract.sh" "${strict_args[@]}"
run "RVPS / initdata" "$ROOT/check-rvps-initdata.sh" "${strict_args[@]}"
run "Measurement-pinned Rego" "$ROOT/dry-run-measurements.sh" "${strict_args[@]}"
run "Rotation readiness" "$ROOT/dry-run-rotation.sh" "${strict_args[@]}"
run "Platform conformance" "$ROOT/check-platform-policy.sh" "${strict_args[@]}"
run "Attestation SLO contract" "$ROOT/check-attestation-slo.sh" "${strict_args[@]}"

if [[ "$WITH_CLUSTER" -eq 1 ]]; then
  run "Cluster policy drift" "$ROOT/diff-cluster-policy.sh" "${strict_args[@]}"
  run "RVPS cluster compare" "$ROOT/check-rvps-initdata.sh" --cluster "${strict_args[@]}"
  run "Trustee log scrape" "$ROOT/check-attestation-slo.sh" --scrape-logs "${strict_args[@]}"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ "$fail" -eq 0 ]]; then
  echo "Production dry-run suite: PASSED"
  exit 0
else
  echo "Production dry-run suite: FAILED (one or more checks failed)"
  exit 1
fi
