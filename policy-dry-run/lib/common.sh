# Shared helpers for policy-dry-run scripts.
# shellcheck shell=bash

dry_run_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

DRY_RUN_ROOT="${DRY_RUN_ROOT:-$(dry_run_dir)}"
REPO_ROOT="${REPO_ROOT:-$(repo_root)}"
DRY_RUN_FAIL=0
DRY_RUN_WARN=0

log_ok()   { printf '  OK   %s\n' "$1"; }
log_fail() { printf '  FAIL %s\n' "$1"; DRY_RUN_FAIL=1; }
log_warn() { printf '  WARN %s\n' "$1"; DRY_RUN_WARN=1; }
log_info() { printf '       %s\n' "$1"; }

reset_counters() {
  DRY_RUN_FAIL=0
  DRY_RUN_WARN=0
}

summary_exit() {
  local strict="${1:-0}"
  echo ""
  echo "==> Summary"
  if [[ "$DRY_RUN_FAIL" -eq 0 && "$DRY_RUN_WARN" -eq 0 ]]; then
    echo "All checks passed."
  elif [[ "$DRY_RUN_FAIL" -eq 0 ]]; then
    echo "Passed with $DRY_RUN_WARN warning(s)."
    [[ "$strict" -eq 1 ]] && DRY_RUN_FAIL=1
  else
    echo "Failed with $DRY_RUN_FAIL failure(s) and $DRY_RUN_WARN warning(s)."
  fi
  return "$DRY_RUN_FAIL"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 2
  }
}

oc_available() {
  command -v oc >/dev/null 2>&1 && oc whoami >/dev/null 2>&1
}

normalize_url() {
  local u="$1"
  u="${u%/}"
  echo "$u"
}

url_host() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlparse
print(urlparse(sys.argv[1]).netloc)
PY
}

initdata_sha256() {
  # sha256 of raw initdata.toml bytes (matches guest initdata content hash input).
  python3 - "$1" <<'PY'
import hashlib, pathlib, sys
p = pathlib.Path(sys.argv[1])
print(hashlib.sha256(p.read_bytes()).hexdigest())
PY
}

cluster_initdata_decode() {
  local b64="$1" out="$2"
  printf '%s' "$b64" | base64 -d | gunzip >"$out"
}

cert_days_until_expiry() {
  openssl x509 -in "$1" -noout -enddate 2>/dev/null | sed 's/notAfter=//' | \
    python3 - <<'PY'
import sys
from datetime import datetime, timezone
raw = sys.stdin.read().strip()
if not raw:
    print("-1")
    raise SystemExit
for fmt in ("%b %d %H:%M:%S %Y %Z",):
    try:
        dt = datetime.strptime(raw, fmt).replace(tzinfo=timezone.utc)
        break
    except ValueError:
        dt = None
if dt is None:
    print("-1")
else:
    print(int((dt - datetime.now(timezone.utc)).total_seconds() // 86400))
PY
}

load_repo_defaults() {
  local saved_root="${ROOT:-}"
  if [[ -f "$REPO_ROOT/scripts/defaults.sh" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/scripts/defaults.sh"
  fi
  # scripts/defaults.sh sets ROOT to repo root — restore caller's script directory if set.
  [[ -n "$saved_root" ]] && ROOT="$saved_root"
  export IMAGE="${IMAGE:-quay.io/lgallett/confidential-inferencing-demo:latest}"
  export TRUSTEE_NS="${TRUSTEE_NS:-trustee-operator-system}"
  export KBS_RESOURCE_PATH="${KBS_RESOURCE_PATH:-default/confidential-inferencing-dek/dek}"
  export DEMO_NAMESPACE="${DEMO_NAMESPACE:-confidential-inferencing}"
  export PEER_NS="${PEER_NS:-openshift-sandboxed-containers-operator}"
  export POLICY_SECRET="${POLICY_SECRET:-trustee-image-policy}"
}
