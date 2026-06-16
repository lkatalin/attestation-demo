#!/usr/bin/env bash
# Offline checks on KBS handoff bundle (output/ or operator-bundle/) before inference deploy.
#
# Usage:
#   ./check-handoff.sh /path/to/kbs-tee-attestation/output
#   ./check-handoff.sh --kbs-url https://... --ca kbs-ca.pem --initdata initdata.toml
set -euo pipefail

BUNDLE=""
KBS_URL=""
KBS_CA=""
INITDATA=""
RESOURCE_PATH=""
DEPLOY_ENV=""

FAIL=0
WARN=0

usage() {
  sed -n '2,7p' "$0" | sed 's/^# \?//'
  cat <<EOF

Options:
  BUNDLE_DIR              Directory with kbs.url, kbs-ca.pem, initdata.toml, kbs-resource-path.txt
  --kbs-url URL
  --ca PATH               kbs-ca.pem
  --initdata PATH         initdata.toml
  --resource-path PATH    e.g. default/confidential-inferencing-dek/dek
  --deploy-env PATH       deploy/kbs.env from inference side (optional cross-check)
  -h, --help
EOF
}

log_ok()   { printf '  OK   %s\n' "$1"; }
log_fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }
log_warn() { printf '  WARN %s\n' "$1"; WARN=1; }

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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kbs-url) KBS_URL="$2"; shift 2 ;;
    --ca) KBS_CA="$2"; shift 2 ;;
    --initdata) INITDATA="$2"; shift 2 ;;
    --resource-path) RESOURCE_PATH="$2"; shift 2 ;;
    --deploy-env) DEPLOY_ENV="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
    *)
      [[ -z "$BUNDLE" ]] || { echo "Unexpected argument: $1" >&2; exit 2; }
      BUNDLE="$1"
      shift
      ;;
  esac
done

if [[ -n "$BUNDLE" ]]; then
  [[ -f "$BUNDLE/kbs.url" ]] && KBS_URL="$(tr -d '\n' <"$BUNDLE/kbs.url")"
  [[ -f "$BUNDLE/kbs-ca.pem" ]] && KBS_CA="$BUNDLE/kbs-ca.pem"
  [[ -f "$BUNDLE/initdata.toml" ]] && INITDATA="$BUNDLE/initdata.toml"
  [[ -f "$BUNDLE/kbs-resource-path.txt" ]] && RESOURCE_PATH="$(tr -d '\n' <"$BUNDLE/kbs-resource-path.txt")"
fi

command -v python3 >/dev/null || { echo "python3 required" >&2; exit 2; }

echo "==> KBS handoff bundle checks"
echo ""

echo "==> Required files"
if [[ -n "$KBS_URL" ]]; then
  log_ok "kbs.url: $KBS_URL"
else
  log_fail "missing kbs.url"
fi
if [[ -f "$KBS_CA" ]]; then
  log_ok "kbs-ca.pem: $KBS_CA"
else
  log_fail "missing kbs-ca.pem"
fi
if [[ -f "$INITDATA" ]]; then
  log_ok "initdata.toml: $INITDATA"
else
  log_fail "missing initdata.toml"
fi

if [[ -n "$RESOURCE_PATH" ]]; then
  if [[ "$RESOURCE_PATH" =~ ^[^/]+/[^/]+/[^/]+$ ]]; then
    log_ok "resource path format ($RESOURCE_PATH)"
  else
    log_warn "resource path should be tenant/resource/key ($RESOURCE_PATH)"
  fi
else
  log_warn "no resource path (kbs-resource-path.txt)"
fi

if [[ -n "$KBS_URL" ]]; then
  norm="$(normalize_url "$KBS_URL")"
  host="$(url_host "$norm")"
  echo ""
  echo "==> KBS URL consistency"
  log_ok "kbs.url host: $host"

  if [[ -f "$INITDATA" ]]; then
    mapfile -t init_urls < <(grep -Eo 'https?://[^"'\''[:space:]]+' "$INITDATA" | sort -u || true)
    if [[ ${#init_urls[@]} -eq 0 ]]; then
      log_warn "no https URLs found in initdata.toml (may use embedded gzip files only)"
    else
      match=0
      for u in "${init_urls[@]}"; do
        ih="$(url_host "$(normalize_url "$u")")"
        if [[ "$ih" == "$host" ]]; then
          match=1
          log_ok "initdata URL host matches: $u"
        else
          log_warn "initdata URL host differs: $u (expected $host)"
        fi
      done
      [[ "$match" -eq 1 ]] || log_fail "no initdata URL host matches kbs.url ($host)"
    fi
  fi

  if [[ -f "$DEPLOY_ENV" ]]; then
    dep_url="$(grep -E '^export KBS_URL=' "$DEPLOY_ENV" | head -1 | sed -E 's/^export KBS_URL="?([^"]*)"?/\1/')"
    if [[ -n "$dep_url" ]]; then
      if [[ "$(url_host "$(normalize_url "$dep_url")")" == "$host" ]]; then
        log_ok "deploy/kbs.env KBS_URL matches"
      else
        log_fail "deploy/kbs.env KBS_URL ($dep_url) host differs from kbs.url"
      fi
    fi
  fi
fi

if [[ -f "$INITDATA" ]]; then
  echo ""
  echo "==> CDH / runtime DEK (initdata.toml)"
  if grep -q "cdh.toml" "$INITDATA"; then
    log_ok "initdata embeds cdh.toml"
  else
    log_warn "initdata missing cdh.toml block"
  fi
  if grep -q "unix:///run/confidential-containers/cdh.sock" "$INITDATA"; then
    log_ok "cdh.toml socket path present (guest daemon; workload uses REST API)"
  else
    log_warn "cdh.toml socket path not found — CDH may use defaults"
  fi
  if grep -q 'image_security_policy_uri' "$INITDATA"; then
    log_ok "cdh.toml references image_security_policy_uri (signed image pull)"
  else
    log_warn "initdata missing image_security_policy_uri — image pull may fail"
  fi
  if [[ -n "$RESOURCE_PATH" ]]; then
    if grep -qF "$RESOURCE_PATH" "$INITDATA"; then
      log_ok "initdata references DEK resource path ($RESOURCE_PATH)"
    else
      log_warn "initdata does not mention DEK path $RESOURCE_PATH (boot prefetch optional)"
    fi
    if grep -qE '\[\[credentials\]\]' "$INITDATA"; then
      log_ok "initdata has CDH [[credentials]] (boot DEK prefetch — may race vTPM; REST fetch preferred)"
    else
      log_warn "no CDH [[credentials]] in initdata — rely on runtime REST fetch in entrypoint"
    fi
  fi
  if [[ -n "$KBS_URL" && -f "$INITDATA" ]]; then
    if grep -qF "$(url_host "$(normalize_url "$KBS_URL")")" "$INITDATA"; then
      log_ok "initdata cdh.toml / aa.toml KBS host matches kbs.url"
    else
      log_fail "initdata KBS host does not match kbs.url ($(url_host "$(normalize_url "$KBS_URL")"))"
    fi
  fi
fi

if [[ -f "$KBS_CA" && -f "$INITDATA" ]]; then
  echo ""
  echo "==> TLS trust anchor"
  ca_fp="$(openssl x509 -in "$KBS_CA" -noout -fingerprint -sha256 2>/dev/null | sed 's/sha256 Fingerprint=//i' || true)"
  if [[ -n "$ca_fp" ]]; then
    log_ok "kbs-ca.pem fingerprint: $ca_fp"
    if grep -qF "${ca_fp//:/}" "$INITDATA" 2>/dev/null || grep -q "BEGIN CERTIFICATE" "$INITDATA"; then
      log_ok "initdata.toml appears to embed a certificate (manual verify recommended)"
    else
      log_warn "could not confirm initdata embeds same cert as kbs-ca.pem — decode embedded aa.toml/cdh.toml if unsure"
    fi
  else
    log_warn "could not read kbs-ca.pem as X.509"
  fi
fi

if [[ -n "$KBS_URL" ]]; then
  echo ""
  echo "==> KBS health (optional network)"
  if curl -sk --connect-timeout 5 "${KBS_URL%/}/kbs/v0/health" -o /dev/null -w '' 2>/dev/null; then
    log_ok "KBS health reachable at ${KBS_URL%/}/kbs/v0/health"
  else
    log_warn "KBS health not reachable from this host (firewall/DNS may still be OK for guests)"
  fi
fi

echo ""
echo "==> Summary"
if [[ "$FAIL" -eq 0 && "$WARN" -eq 0 ]]; then
  echo "Handoff bundle looks consistent."
elif [[ "$FAIL" -eq 0 ]]; then
  echo "Passed with $WARN warning(s)."
else
  echo "Failed with $WARN warning(s) and errors above."
fi

exit "$FAIL"
