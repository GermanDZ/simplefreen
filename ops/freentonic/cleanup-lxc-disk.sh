#!/usr/bin/env bash
# Reclaim disk on the LXC (e.g. before a freentonic rebuild that fails with
# "no space left on device"). Prunes build cache + dangling layers and
# removes OLD freentonic image tags, but KEEPS :latest and one rollback tag.
# `docker rmi` refuses to remove an image a running container uses, so the
# live accessory is never affected.
#
# Env: KAMAL_HOST, KAMAL_SSH_USER. Edit KEEP below to change preserved tags.
set -euo pipefail

HOST="${KAMAL_HOST:?set KAMAL_HOST to the deploy host}"
SSH_USER="${KAMAL_SSH_USER:-root}"

ssh "$SSH_USER@$HOST" 'bash -s' <<'REMOTE'
set -uo pipefail
KEEP='latest|8b8414e'   # tag regex to preserve (defined here so the pipe survives transit)

echo "=========== BEFORE ==========="
df -h / 2>/dev/null | tail -1
docker system df 2>/dev/null || true

echo; echo "=== prune build cache ==="
docker builder prune -af 2>&1 | tail -2

echo; echo "=== prune dangling images ==="
docker image prune -f 2>&1 | tail -2

echo; echo "=== remove old freentonic tags (keep: $KEEP; in-use tags are skipped) ==="
docker images --format '{{.Repository}}:{{.Tag}}' \
  | grep '^localhost:5000/freentonic:' \
  | grep -vE ":($KEEP)\$" \
  | while read -r ref; do
      if docker rmi "$ref" >/dev/null 2>&1; then echo "removed $ref"; else echo "kept (in use/shared) $ref"; fi
    done

echo; echo "=========== AFTER ==========="
df -h / 2>/dev/null | tail -1
docker images --format '  {{.Repository}}:{{.Tag}} {{.Size}}' | grep freentonic || true
REMOTE
