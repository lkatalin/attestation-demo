#!/usr/bin/env bash
# Image supply-chain contract: digest pin, cosign, non-root USER, no secrets in image.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
load_repo_defaults

IMAGE_REF="${IMAGE:-}"
STRICT=0
REQUIRE_DIGEST=0
CHECK_SIG_TAG=0

usage() {
  cat <<EOF
Usage: $0 [options]

  --image REF           Image reference (default: \$IMAGE)
  --require-digest      Fail if tag is :latest or unpinned digest missing from deployment
  --check-sig-tag       skopeo list-tags for legacy cosign .sig (needs network)
  --strict
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE_REF="$2"; shift 2 ;;
    --require-digest) REQUIRE_DIGEST=1; shift ;;
    --check-sig-tag) CHECK_SIG_TAG=1; shift ;;
    --strict) STRICT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$IMAGE_REF" ]] || IMAGE_REF="$IMAGE"
reset_counters
echo "==> Image supply-chain contract"
echo "Image: $IMAGE_REF"
echo ""

dep="$REPO_ROOT/deploy/deployment-confidential.yaml"
df="$REPO_ROOT/container/Dockerfile"
cosign_pub="$REPO_ROOT/artifacts/cosign.pub"

if [[ "$IMAGE_REF" == *:latest ]]; then
  if [[ "$REQUIRE_DIGEST" -eq 1 ]]; then
    log_fail "image uses :latest — production should pin @sha256 digest"
  else
    log_warn "image uses :latest — pin digest in production deployments"
  fi
else
  log_ok "image tag is not :latest"
fi

if [[ -f "$dep" ]]; then
  if grep -q '@sha256:' "$dep"; then
    log_ok "deployment pins image digest"
  elif [[ "$REQUIRE_DIGEST" -eq 1 ]]; then
    log_fail "deployment does not pin @sha256 digest"
  else
    log_warn "deployment uses tag substitution — pin digest for production"
  fi
fi

if [[ -f "$df" ]]; then
  if grep -qE '^USER[[:space:]]+[1-9]' "$df"; then
    log_ok "Dockerfile declares non-root USER"
  else
    log_fail "Dockerfile missing non-root USER"
  fi
  if grep -qiE 'COPY.*(dek\.bin|\.env|cosign\.key)' "$df"; then
    log_fail "Dockerfile may COPY secrets — DEK and keys belong in KBS only"
  else
    log_ok "Dockerfile does not COPY obvious secret files"
  fi
fi

if [[ -f "$cosign_pub" ]]; then
  log_ok "cosign public key present ($cosign_pub)"
  if command -v cosign >/dev/null 2>&1; then
    if cosign verify --key "$cosign_pub" "$IMAGE_REF" >/dev/null 2>&1; then
      log_ok "cosign verify succeeded for $IMAGE_REF"
    else
      log_warn "cosign verify failed — image unsigned or wrong key (run make fix-image-sign after push)"
    fi
  else
    log_warn "cosign CLI not installed — skipping signature verify"
  fi
else
  log_warn "missing artifacts/cosign.pub — run make setup-cosign"
fi

if command -v skopeo >/dev/null 2>&1; then
  digest="$(skopeo inspect "docker://$IMAGE_REF" 2>/dev/null | jq -r .Digest || true)"
  if [[ -n "$digest" && "$digest" != null ]]; then
    log_ok "registry digest: $digest"
  else
    log_warn "skopeo could not inspect $IMAGE_REF (network/auth?)"
  fi
  if [[ "$CHECK_SIG_TAG" -eq 1 && -n "$digest" ]]; then
    repo="${IMAGE_REF%%:*}"
    sig_tag="sha256-${digest#sha256:}.sig"
    tags="$(skopeo list-tags "docker://$repo" 2>/dev/null | jq -r '.Tags[]?' || true)"
    if grep -qF "$sig_tag" <<<"$tags"; then
      log_ok "legacy cosign .sig tag present (CDH-compatible)"
    else
      log_fail "missing legacy .sig tag for digest — CDH may reject image (make fix-image-sign)"
    fi
  fi
else
  log_warn "skopeo not installed — skipping registry inspect"
fi

if command -v podman >/dev/null 2>&1 || command -v docker >/dev/null 2>&1; then
  engine=podman
  command -v podman >/dev/null 2>&1 || engine=docker
  if $engine image exists "$IMAGE_REF" 2>/dev/null; then
    user="$($engine inspect "$IMAGE_REF" --format '{{.Config.User}}' 2>/dev/null || true)"
    [[ -n "$user" && "$user" != "0" ]] && log_ok "local image Config.User=$user" \
      || log_warn "local image User empty or root"
  fi
fi

summary_exit "$STRICT"
