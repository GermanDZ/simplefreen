#!/usr/bin/env bash
# Emergency rollback: point the accessory's :latest at a known-good image
# in the host-local registry, then reboot. Use when a fresh build shipped a
# broken freentonic (e.g. a floated Chromium that won't launch) and you need
# service back before fixing the build.
#
# Usage: ./rollback-image.sh [GOOD_IMAGE]
#   GOOD_IMAGE defaults to localhost:5000/freentonic:8b8414e (Chromium 148).
#   Vet a candidate first with verify-image-chrome.sh.
#
# Does the retag+push here; run `kamal accessory reboot freentonic` after
# (needs your laptop's kamal config/secrets).
set -euo pipefail

HOST="${KAMAL_HOST:?set KAMAL_HOST to the deploy host}"
SSH_USER="${KAMAL_SSH_USER:-root}"
GOOD="${1:-localhost:5000/freentonic:8b8414e}"
REG="localhost:5000/freentonic:latest"

ssh "$SSH_USER@$HOST" GOOD="$GOOD" REG="$REG" 'bash -s' <<'REMOTE'
set -euo pipefail
echo "retagging $REG -> $GOOD"
docker tag "$GOOD" "$REG"
docker push "$REG"
echo "done: $REG now = $(docker inspect --format '{{.Id}}' "$GOOD" | cut -c1-19)"
REMOTE

echo
echo "Next (from your laptop, in the simplefreen repo):"
echo "  kamal accessory reboot freentonic"
