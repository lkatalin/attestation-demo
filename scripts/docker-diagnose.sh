#!/usr/bin/env bash
# Show why "no space left on device" can happen while macOS still has free disk.
set -euo pipefail

echo "==> macOS disk (host)"
df -h /System/Volumes/Data 2>/dev/null || df -h /

echo ""
echo "==> Docker disk usage (inside Docker Desktop VM)"
if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon not running. Start Docker Desktop first."
  exit 1
fi

docker system df

echo ""
echo "==> Largest volumes (often Kind / old stacks)"
docker system df -v 2>/dev/null | sed -n '/Local Volumes space usage:/,/Build cache/p' | head -20

echo ""
echo "If TOTAL is near Docker Desktop's virtual disk limit, builds fail with"
echo "'no space left on device' even when the Mac has plenty of free space."
echo ""
echo "Fix: scripts/docker-prune-demo.sh  OR  Docker Desktop → Settings → Resources → increase disk"
