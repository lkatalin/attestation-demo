#!/usr/bin/env bash
export KBS_MODE=local
exec "$(cd "$(dirname "$0")" && pwd)/kbs/configure-kbs.sh" "$@"
