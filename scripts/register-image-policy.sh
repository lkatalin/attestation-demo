#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")" && pwd)/kbs/register-policy.sh" "$@"
