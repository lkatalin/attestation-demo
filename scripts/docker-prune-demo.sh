#!/usr/bin/env bash
# Reclaim Docker VM disk before building (interactive).
set -euo pipefail

docker info >/dev/null 2>&1 || { echo "Start Docker Desktop first." >&2; exit 1; }

echo "Before:"
docker system df

echo ""
echo "This will remove:"
echo "  - build cache"
echo "  - unused images"
echo "  - unused volumes (WARNING: deletes stopped Kind/compose volumes)"
echo ""
read -r -p "Continue? [y/N] " ans
[[ "${ans,,}" == "y" ]] || exit 0

docker builder prune -af
docker image prune -af
docker volume prune -f

echo ""
echo "After:"
docker system df
echo ""
echo "If still tight: Docker Desktop → Settings → Resources → Virtual disk limit → 96GB+"
echo "Then: bash scripts/build-and-push.sh"
