#!/usr/bin/env bash
# Deploy the full three-arm demo (preferred).
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/deploy-demo.sh" "$@"
