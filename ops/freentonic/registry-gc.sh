#!/usr/bin/env bash
# Reclaim disk from the host-local Docker registry (kamal-local-registry).
# Every `kamal deploy` / freentonic build pushes a fresh `:<sha>` + `:latest`
# to it, and the registry:2 image isn't delete-enabled, so old blobs
# accumulate unbounded (2.5 GB after ~a month in the 2026-07 incident).
#
# `docker rmi` on the LXC does NOT touch the registry — it's a separate
# store. This recreates the registry's (anonymous) volume from scratch and
# repushes only the tags worth keeping, so the reclaim is the difference
# between "all shas ever pushed" and "just these tags".
#
# SAFE: the running freentonic accessory runs from the *local* docker image,
# not the registry, so recreating the registry never interrupts a live sync.
# `kamal accessory reboot` uses the local image too; `kamal deploy` rebuilds
# and repushes anyway. The images to keep MUST exist locally (verified below)
# so they can be repushed.
#
# Usage: ./registry-gc.sh [TAG ...]
#   TAGs default to: latest 8b8414e   (current image + the Chromium-148 rollback)
#
# Env: KAMAL_HOST (required), KAMAL_SSH_USER (root).
set -euo pipefail

HOST="${KAMAL_HOST:?set KAMAL_HOST to the deploy host}"
SSH_USER="${KAMAL_SSH_USER:-root}"
KEEP_TAGS=("$@")
[ ${#KEEP_TAGS[@]} -eq 0 ] && KEEP_TAGS=(latest 8b8414e)

ssh "$SSH_USER@$HOST" KEEP="${KEEP_TAGS[*]}" 'bash -s' <<'REMOTE'
set -euo pipefail
echo "=== BEFORE ==="; df -h / | tail -1
echo "keeping tags: $KEEP"

# Every tag to keep must exist locally so we can repush it after the wipe.
for t in $KEEP; do
  docker image inspect "localhost:5000/freentonic:$t" >/dev/null 2>&1 \
    || { echo "ABORT: local image localhost:5000/freentonic:$t is missing — cannot repush it"; exit 1; }
done

REGVOL=$(docker inspect kamal-local-registry --format '{{range .Mounts}}{{.Name}}{{end}}' 2>/dev/null || true)
echo "registry volume: ${REGVOL:-<none>}"

echo "=== recreate registry (drops old blobs) ==="
docker rm -f kamal-local-registry >/dev/null
[ -n "$REGVOL" ] && docker volume rm "$REGVOL" >/dev/null 2>&1 || true
docker run -d --restart=always --name kamal-local-registry \
  -p 127.0.0.1:5000:5000 registry:2 >/dev/null
sleep 2

echo "=== repush kept tags ==="
for t in $KEEP; do
  docker push "localhost:5000/freentonic:$t" 2>&1 | tail -1
done

echo "=== AFTER ==="; df -h / | tail -1
echo "registry now serves:"
docker exec kamal-local-registry sh -lc 'wget -qO- http://127.0.0.1:5000/v2/freentonic/tags/list 2>/dev/null || echo "(tag check skipped)"'
REMOTE
