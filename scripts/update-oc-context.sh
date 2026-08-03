#!/bin/bash
set -e

# Update oc context names to match ARO cluster names.
# Matches URL subdomain from 'az aro list' to oc context and renames.
#
# Usage:
#   bash update-oc-context.sh
#
# Example:
#   Before: api-edm2xw4n-eastus-aroapp-io:6443
#   After:  lily-infra

echo "=== Cleaning up dead contexts ==="
oc config get-contexts -o name | while read ctx; do
    if timeout 3 oc --context=$ctx whoami &>/dev/null; then
      echo "✓ $ctx - ACTIVE (keeping)"
    else
      echo "✗ $ctx - DEAD (deleting context and cluster)"
      cluster=$(oc config view --context=$ctx -o jsonpath='{.context.cluster}' 2>/dev/null)
      oc config delete-context $ctx
      if [ -n "$cluster" ]; then
        oc config delete-cluster $cluster 2>/dev/null
      fi
    fi
  done
echo ""

echo "=== Updating oc context names from ARO cluster names ==="

# Get ARO clusters with JSON output for reliable parsing
CLUSTERS=$(az aro list --query "[].{name:name, url:consoleProfile.url}" -o json)

if [[ -z "$CLUSTERS" || "$CLUSTERS" == "[]" ]]; then
  echo "No ARO clusters found"
  exit 0
fi

# Get current oc contexts
if ! oc config get-contexts &>/dev/null; then
  echo "ERROR: No oc contexts found. Log in to your clusters first with 'oc login'"
  exit 1
fi

# Process each cluster
echo "$CLUSTERS" | jq -c '.[]' | while read -r cluster; do
  CLUSTER_NAME=$(echo "$cluster" | jq -r '.name')
  CONSOLE_URL=$(echo "$cluster" | jq -r '.url')

  # Extract subdomain identifier from console URL
  # Example: https://console-openshift-console.apps.edm2xw4n.eastus2.aroapp.io/
  # Extract: edm2xw4n
  SUBDOMAIN=$(echo "$CONSOLE_URL" | sed -E 's|https://console-openshift-console\.apps\.([^.]+)\..*|\1|')

  if [[ -z "$SUBDOMAIN" ]]; then
    echo "  Skipping $CLUSTER_NAME: couldn't extract subdomain from $CONSOLE_URL"
    continue
  fi

  # Find matching oc context (API server context contains the same subdomain)
  # Example: api-edm2xw4n-eastus-aroapp-io:6443
  MATCHING_CONTEXT=$(oc config get-contexts -o name | grep -F "$SUBDOMAIN" || true)

  if [[ -z "$MATCHING_CONTEXT" ]]; then
    echo "  Skipping $CLUSTER_NAME: no matching oc context for subdomain '$SUBDOMAIN'"
    continue
  fi

  # Check if context already has the desired name
  if [[ "$MATCHING_CONTEXT" == "$CLUSTER_NAME" ]]; then
    echo "  ✓ $CLUSTER_NAME: already correctly named"
    continue
  fi

  # Rename the context
  echo "  Renaming: $MATCHING_CONTEXT → $CLUSTER_NAME"
  oc config rename-context "$MATCHING_CONTEXT" "$CLUSTER_NAME"
done

echo ""
echo "=== Updated contexts ==="
oc config get-contexts -o name
