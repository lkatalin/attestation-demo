#!/usr/bin/env bash
# Alias for enable-peer-pods-guest-rest-api.sh (the required OSC peer-pod fix).
exec "$(dirname "$0")/enable-peer-pods-guest-rest-api.sh" "$@"
