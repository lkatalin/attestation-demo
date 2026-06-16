#!/usr/bin/env bash
# Apply entrypoint + deployment changes for CDH DEK path; restart confidential pod.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../defaults.sh
source "$(dirname "$0")/../defaults.sh"

oc whoami >/dev/null || { echo "oc login required" >&2; exit 1; }

KBS_MODE="${KBS_MODE:-local}"
bash "$ROOT/scripts/kbs/configure-kbs.sh"
# shellcheck source=/dev/null
source "$ROOT/deploy/kbs.env"
export IMAGE KBS_URL KBS_RESOURCE_PATH

echo "==> Regenerate entrypoint ConfigMap from container/entrypoint.sh"
bash "$ROOT/scripts/generate-entrypoint-configmap.sh"

echo "==> Apply entrypoint ConfigMap"
oc apply -f "$ROOT/deploy/configmap-entrypoint.yaml"

echo "==> Apply confidential deployment (CDH via guest socket; no hostPath)"
envsubst '${IMAGE} ${KBS_URL} ${KBS_RESOURCE_PATH}' \
  <"$ROOT/deploy/deployment-confidential.yaml" | oc apply -f -

echo "==> Restart confidential workload (new peer pod picks up initdata + mounts)"
bash "$ROOT/scripts/kbs/restart-confidential-workloads.sh"
