#!/usr/bin/env bash
# Cross-cluster handoff packs for confidential inferencing.
#
# Two directions:
#   export-bundle / import-bundle   model owner → customer (KBS URL, initdata, CA)
#   export-claims / import-claims   customer → model owner (CVM fingerprints for policy)
#
# Usage:
#   ./customer-handoff.sh export-bundle --bundle ../kbs-tee-attestation/output
#   ./customer-handoff.sh import-bundle customer-kbs-bundle.tar.gz
#   ./customer-handoff.sh export-claims --from claims.json --label acme-prod
#   ./customer-handoff.sh import-claims customer-claims-acme-prod.tar.gz
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

CMD=""
BUNDLE=""
PACK=""
LABEL=""
FROM=""
FROM_JWT=""
OUT=""
CLUSTER_INFO=0
STRICT=0
IMAGE_REF="${IMAGE:-}"

usage() {
  cat <<EOF
Usage: $0 <command> [options]

Commands (model owner → customer):
  export-bundle     Validate KBS output/ and create tarball for inference team
  import-bundle     Customer validates bundle before remote-apply-initdata

Commands (customer → model owner):
  export-claims     After golden CVM boot — safe fingerprint pack for policy pinning
  import-claims     Model owner validates pack and prints next policy steps

Common options:
  --bundle PATH     KBS handoff dir (default: ../kbs-tee-attestation/output)
  --out PATH        Output .tar.gz (default derived from command + label)
  --strict          Warnings fail the run
  -h, --help

export-claims:
  --from PATH       KBS evaluation input JSON or claims with submods
  --from-jwt PATH   Attestation JWT (payload decoded; JWT not included in pack)
  --label NAME      Customer / cluster label (required)
  --cluster-info    If oc login: attach non-secret peer-pod context (region, initdata size)

import-claims / import-bundle:
  PACK              .tar.gz or unpacked directory

Safe to share in export-claims (customer → model owner):
  measurement, pcr11 hex, OPA input fixture (submods), optional cluster metadata

Do NOT include in export-claims:
  DEK, cosign private key, customer workload data, live session JWTs (use --from not --from-jwt file in pack)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    export-bundle|import-bundle|export-claims|import-claims)
      CMD="$1"
      shift
      ;;
    --bundle) BUNDLE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --from-jwt) FROM_JWT="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --cluster-info) CLUSTER_INFO=1; shift ;;
    --strict) STRICT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      [[ -z "$PACK" ]] && PACK="$1" || { echo "Unexpected argument: $1" >&2; exit 2; }
      shift
      ;;
  esac
done

[[ -n "$CMD" ]] || { usage >&2; exit 2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 2
  }
}

write_readme_model_owner() {
  local dest="$1"
  cat >"$dest/HANDOFF_README.txt" <<'EOF'
Model owner → customer KBS handoff pack
=======================================

Files:
  kbs.url                 Base URL for KBS (same as embedded in initdata.toml)
  kbs-ca.pem              TLS CA for KBS route
  initdata.toml           Apply to peer-pods INITDATA on inference cluster
  kbs-resource-path.txt   DEK path for KBS_RESOURCE_PATH / CDH credentials
  image-ref.txt           Signed workload image reference (if provided)

Customer steps (inference cluster):
  1. Unpack this archive on a trusted host.
  2. cd policy-dry-run && ./customer-handoff.sh import-bundle <this-pack>
  3. Set config/inference-remote.env from these paths.
  4. make remote-apply-initdata fix-peer-pods remote-deploy

After one successful confidential boot, send the model owner a claims pack:
  ./customer-handoff.sh export-claims --from <claims.json> --label <your-org>
EOF
}

write_readme_customer_claims() {
  local dest="$1" label="$2"
  cat >"$dest/HANDOFF_README.txt" <<EOF
Customer → model owner attestation handoff
==========================================

Label: $label

This pack contains only infrastructure fingerprints (SNP measurement + TPM PCR11)
from a golden confidential VM boot. It does NOT contain:
  - DEK or model weights
  - Customer inference data or secrets
  - Cosign private keys

Model owner steps:
  1. cd policy-dry-run && ./customer-handoff.sh import-claims <this-pack>
  2. Generate pinned Rego: scripts/kbs/generate-production-policy.sh --pins cvm-pins.json
  3. Dry-run: make dry-run-measurements
  4. Apply on KBS: make apply-production-resource-policy (from repo root, oc on KBS cluster)

Re-capture when peer-pod VM image or initdata changes.
EOF
}

validate_bundle_dir() {
  local dir="$1"
  local missing=0
  for f in kbs.url kbs-ca.pem initdata.toml kbs-resource-path.txt; do
    [[ -f "$dir/$f" ]] || { log_fail "missing $dir/$f"; missing=1; }
  done
  [[ "$missing" -eq 0 ]]
}

cmd_export_bundle() {
  need_cmd tar
  [[ -z "$BUNDLE" ]] && BUNDLE="$REPO_ROOT/kbs-tee-attestation/output"

  reset_counters
  echo "==> Export model-owner bundle for customer"
  echo "    source: $BUNDLE"
  echo ""

  if ! validate_bundle_dir "$BUNDLE"; then
    summary_exit 1
    exit 1
  fi
  if bash "$ROOT/check-handoff.sh" "$BUNDLE"; then
    log_ok "handoff bundle checks passed"
  else
    log_fail "handoff bundle checks failed — fix before sending to customer"
    summary_exit 1
    exit 1
  fi

  local staging
  staging="$(mktemp -d)"
  trap 'rm -rf "$staging"' RETURN

  local name="model-owner-kbs-bundle"
  local pack_dir="$staging/$name"
  mkdir -p "$pack_dir"

  cp "$BUNDLE/kbs.url" "$BUNDLE/kbs-ca.pem" "$BUNDLE/initdata.toml" \
    "$BUNDLE/kbs-resource-path.txt" "$pack_dir/"
  [[ -n "$IMAGE_REF" ]] && printf '%s\n' "$IMAGE_REF" >"$pack_dir/image-ref.txt"
  write_readme_model_owner "$pack_dir"

  jq -n \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg kbs_url "$(tr -d '\n' <"$pack_dir/kbs.url")" \
    --arg resource "$(tr -d '\n' <"$pack_dir/kbs-resource-path.txt")" \
    --arg image "${IMAGE_REF:-}" \
    '{
      type: "model-owner-kbs-bundle",
      created_utc: $created,
      kbs_url: $kbs_url,
      dek_resource_path: $resource,
      image_ref: (if $image == "" then null else $image end),
      safe_to_email: ["kbs.url", "kbs-ca.pem", "initdata.toml", "kbs-resource-path.txt"]
    }' >"$pack_dir/handoff-manifest.json"

  [[ -n "$OUT" ]] || OUT="$ROOT/customer-handoff/${name}.tar.gz"
  mkdir -p "$(dirname "$OUT")"
  tar -czf "$OUT" -C "$staging" "$name"

  echo ""
  log_ok "created $OUT"
  echo "Send to customer with signed workload image pull instructions."
  summary_exit "$STRICT"
}

unpack_pack() {
  local src="$1"
  local dest="$2"
  if [[ -d "$src" ]]; then
    cp -a "$src/." "$dest/"
    return 0
  fi
  need_cmd tar
  tar -xzf "$src" -C "$dest"
}

cmd_import_bundle() {
  [[ -n "$PACK" ]] || { echo "Provide PACK (.tar.gz or directory)" >&2; exit 2; }

  reset_counters
  echo "==> Import model-owner bundle (customer validation)"
  echo "    pack: $PACK"
  echo ""

  local staging
  staging="$(mktemp -d)"
  trap 'rm -rf "$staging"' RETURN
  unpack_pack "$PACK" "$staging"

  local pack_dir="$staging"
  if [[ "$(find "$staging" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq 1 ]]; then
    pack_dir="$(find "$staging" -mindepth 1 -maxdepth 1 -type d | head -1)"
  fi

  validate_bundle_dir "$pack_dir"
  if bash "$ROOT/check-handoff.sh" "$pack_dir"; then
    log_ok "bundle valid for remote-apply-initdata"
  else
    log_fail "bundle failed handoff checks"
  fi

  if [[ -f "$pack_dir/handoff-manifest.json" ]]; then
    log_info "manifest:"
    jq -r '
      "  type=\(.type) kbs_url=\(.kbs_url) dek=\(.dek_resource_path)"
      + (if .image_ref then " image=\(.image_ref)" else "" end)
    ' "$pack_dir/handoff-manifest.json"
  fi

  echo ""
  echo "Suggested inference-remote.env:"
  echo "  export KBS_URL=$(tr -d '\n' <"$pack_dir/kbs.url")"
  echo "  export KBS_CA_FILE=$pack_dir/kbs-ca.pem"
  echo "  export INITDATA_PATH=$pack_dir/initdata.toml"
  echo "  export KBS_RESOURCE_PATH=$(tr -d '\n' <"$pack_dir/kbs-resource-path.txt")"
  echo ""
  echo "Next (inference cluster, oc login):"
  echo "  set -a && source config/inference-remote.env && set +a"
  echo "  make remote-apply-initdata fix-peer-pods remote-deploy"

  summary_exit "$STRICT"
}

collect_cluster_context() {
  local out="$1"
  if [[ "$CLUSTER_INFO" -eq 0 ]]; then
    return 0
  fi
  if ! oc_available; then
    log_warn "--cluster-info requested but oc not logged in — skipping"
    return 0
  fi

  local region="" initdata_bytes="" osc_ns="openshift-sandboxed-containers-operator"
  region="$(oc get cm peer-pods-cm -n "$osc_ns" -o jsonpath='{.data.AZURE_REGION}' 2>/dev/null || true)"
  initdata_bytes="$(oc get cm peer-pods-cm -n "$osc_ns" -o jsonpath='{.data.INITDATA}' 2>/dev/null | wc -c | tr -d ' ')"

  jq -n \
    --arg collected "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg region "${region:-}" \
    --arg initdata_b64_bytes "${initdata_bytes:-0}" \
    --arg cluster "$(oc whoami --show-server 2>/dev/null || true)" \
    '{
      collected_utc: $collected,
      openshift_api: $cluster,
      peer_pods_azure_region: (if $region == "" then null else $region end),
      peer_pods_initdata_b64_chars: ($initdata_b64_bytes | tonumber),
      note: "Non-secret operational metadata only"
    }' >"$out"
  log_ok "cluster-context.json (non-secret metadata)"
}

cmd_export_claims() {
  need_cmd jq
  need_cmd tar
  [[ -n "$LABEL" ]] || { echo "--label required for export-claims" >&2; exit 2; }
  [[ -n "$FROM" || -n "$FROM_JWT" ]] || { echo "--from or --from-jwt required" >&2; exit 2; }

  reset_counters
  echo "==> Export customer claims pack for model owner"
  echo "    label: $LABEL"
  echo ""

  local capture_dir
  capture_dir="$(mktemp -d)"
  trap 'rm -rf "$capture_dir"' RETURN

  local cap_args=(--label "$LABEL" --out-dir "$capture_dir")
  [[ -n "$FROM" ]] && cap_args+=(--from "$FROM")
  [[ -n "$FROM_JWT" ]] && cap_args+=(--from-jwt "$FROM_JWT")
  bash "$ROOT/capture-claims.sh" "${cap_args[@]}"

  local pins="$capture_dir/cvm-pins-${LABEL}.json"
  local fixture="$capture_dir/input-${LABEL}.json"
  [[ -f "$pins" ]] || { log_fail "no az-snp-vtpm measurement in claims — golden SNP boot required"; summary_exit 1; exit 1; }

  local staging
  staging="$(mktemp -d)"
  local name="customer-claims-${LABEL}"
  local pack_dir="$staging/$name"
  mkdir -p "$pack_dir"

  cp "$pins" "$pack_dir/cvm-pins.json"
  cp "$fixture" "$pack_dir/input-fixture.json"
  [[ -f "$capture_dir/measurements-${LABEL}.json" ]] && \
    cp "$capture_dir/measurements-${LABEL}.json" "$pack_dir/measurements-summary.json"
  [[ -f "$capture_dir/rego-measurements-${LABEL}.rego" ]] && \
    cp "$capture_dir/rego-measurements-${LABEL}.rego" "$pack_dir/suggested-pins.rego"

  collect_cluster_context "$pack_dir/cluster-context.json" || true
  write_readme_customer_claims "$pack_dir" "$LABEL"

  jq -n \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg label "$LABEL" \
    --slurpfile pins "$pack_dir/cvm-pins.json" \
    '{
      type: "customer-claims-pack",
      created_utc: $created,
      label: $label,
      measurement: $pins[0].measurement,
      pcr11: $pins[0].pcr11,
      safe_to_share: ["measurement", "pcr11", "input-fixture.json", "cluster-context.json"],
      never_include: ["dek.bin", "cosign.key", "live_jwt", "customer_prompts"]
    }' >"$pack_dir/handoff-manifest.json"

  [[ -n "$OUT" ]] || OUT="$ROOT/customer-handoff/${name}.tar.gz"
  mkdir -p "$(dirname "$OUT")"
  tar -czf "$OUT" -C "$staging" "$name"

  echo ""
  log_ok "created $OUT"
  jq -r '"  measurement: \(.measurement)\n  pcr11:       \(.pcr11)"' "$pack_dir/cvm-pins.json"
  echo ""
  echo "Send this archive to the model owner over your usual secure channel."
  summary_exit "$STRICT"
}

cmd_import_claims() {
  need_cmd jq
  [[ -n "$PACK" ]] || { echo "Provide PACK (.tar.gz or directory)" >&2; exit 2; }

  reset_counters
  echo "==> Import customer claims pack (model owner)"
  echo "    pack: $PACK"
  echo ""

  local staging
  staging="$(mktemp -d)"
  trap 'rm -rf "$staging"' RETURN
  unpack_pack "$PACK" "$staging"

  local pack_dir="$staging"
  if [[ "$(find "$staging" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq 1 ]]; then
    pack_dir="$(find "$staging" -mindepth 1 -maxdepth 1 -type d | head -1)"
  fi

  [[ -f "$pack_dir/cvm-pins.json" ]] || { log_fail "missing cvm-pins.json"; summary_exit 1; exit 1; }
  [[ -f "$pack_dir/input-fixture.json" ]] || { log_fail "missing input-fixture.json"; summary_exit 1; exit 1; }

  local meas pcr11 label
  meas="$(jq -r '.measurement // empty' "$pack_dir/cvm-pins.json")"
  pcr11="$(jq -r '.pcr11 // empty' "$pack_dir/cvm-pins.json")"
  label="$(jq -r '.label // "imported"' "$pack_dir/cvm-pins.json")"
  [[ -n "$meas" && "$meas" != "null" ]] || log_fail "cvm-pins.json missing measurement"
  [[ -n "$pcr11" && "$pcr11" != "null" ]] || log_warn "cvm-pins.json missing pcr11 (measurement-only pin still possible)"

  log_ok "pins: label=$label measurement=${meas:0:16}… pcr11=${pcr11:0:16}…"

  local import_dir="$ROOT/customer-handoff/imported-${label}"
  mkdir -p "$import_dir"
  cp "$pack_dir/cvm-pins.json" "$import_dir/"
  cp "$pack_dir/input-fixture.json" "$import_dir/input-${label}.json"
  log_ok "copied fixtures to $import_dir"

  echo ""
  echo "==> Dry-run measurement policy against customer fixture"
  if [[ -f "$REPO_ROOT/policy/kbs-resource-policy-snp-production.rego" ]]; then
    bash "$ROOT/dry-run-measurements.sh" \
      --rego "$REPO_ROOT/policy/kbs-resource-policy-snp-production.rego" \
      --fixture "$import_dir/input-${label}.json" \
      || log_warn "production policy dry-run failed — generate fresh policy from pins"
  else
    log_info "no policy/kbs-resource-policy-snp-production.rego yet — generate first"
    bash "$ROOT/dry-run.sh" \
      --rego "$ROOT/examples/kbs-resource-policy-snp-measurements.rego" \
      --fixture "$import_dir/input-${label}.json" \
      || log_warn "example measurement policy dry-run failed — edit MEASUREMENT_HEX / PCR11_HEX in example"
  fi

  echo ""
  echo "Next steps (repo root, oc login to KBS cluster):"
  echo "  make generate-production-policy PINS=$import_dir/cvm-pins.json"
  echo "  cd policy-dry-run && make dry-run-measurements"
  echo "  make apply-production-resource-policy"
  echo ""
  echo "Demo shortcut (any SNP guest, no per-customer pin):"
  echo "  make relax-resource-policy-snp"

  summary_exit "$STRICT"
}

case "$CMD" in
  export-bundle) cmd_export_bundle ;;
  import-bundle) cmd_import_bundle ;;
  export-claims) cmd_export_claims ;;
  import-claims) cmd_import_claims ;;
  *)
    echo "Unknown command: $CMD" >&2
    usage >&2
    exit 2
    ;;
esac
