#!/usr/bin/env bash
# Create imagePullSecret for private registry (quay.io / docker.io).
set -euo pipefail

NS="${NAMESPACE:-confidential-inferencing}"
SECRET_NAME="${SECRET_NAME:-inference-demo-pull}"

oc whoami >/dev/null || { echo "oc login required" >&2; exit 1; }

DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker/config.json}"
[[ -f "$DOCKER_CONFIG" ]] || {
  echo "Missing $DOCKER_CONFIG — docker login to your registry first" >&2
  exit 1
}

oc create namespace "$NS" --dry-run=client -o yaml | oc apply -f -
oc create secret generic "$SECRET_NAME" \
  --from-file=.dockerconfigjson="$DOCKER_CONFIG" \
  --type=kubernetes.io/dockerconfigjson \
  -n "$NS" \
  --dry-run=client -o yaml | oc apply -f -

echo "Created $SECRET_NAME in $NS"
