#!/usr/bin/env bash
# Pick docker or podman and ensure the daemon/vm is reachable.
set -euo pipefail

container_engine() {
  if [[ -n "${CONTAINER_ENGINE:-}" ]]; then
    echo "$CONTAINER_ENGINE"
    return 0
  fi
  if docker info >/dev/null 2>&1; then
    echo docker
    return 0
  fi
  if podman info >/dev/null 2>&1; then
    echo podman
    return 0
  fi
  return 1
}

require_container_engine() {
  local eng
  if eng="$(container_engine)"; then
    export CONTAINER_ENGINE="$eng"
    echo "Using container engine: $CONTAINER_ENGINE"
    return 0
  fi

  cat >&2 <<'EOF'
No working container engine found.

macOS — pick one:

  Docker Desktop
    open -a Docker
    # wait until "Docker Desktop is running", then: docker info

  Podman
    podman machine start
    podman info

If Docker Desktop hangs ("context deadline exceeded"):
  1. Quit Docker Desktop fully (menu → Quit)
  2. open -a Docker
  3. If still broken: Docker Desktop → Troubleshoot → Restart / Reset

Reinstall only if the above fails:
  https://docs.docker.com/desktop/setup/install/mac-install/

Override engine: CONTAINER_ENGINE=podman make build
EOF
  return 1
}

ce() {
  require_container_engine
  "$CONTAINER_ENGINE" "$@"
}
