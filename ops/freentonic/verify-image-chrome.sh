#!/usr/bin/env bash
# Verify that a freentonic image's Chromium actually launches, in a
# throwaway --rm container. Use to smoke-test a freshly built image before
# rolling the accessory onto it, or to vet a rollback candidate.
#
# Usage: ./verify-image-chrome.sh [IMAGE]
#   IMAGE defaults to localhost:5000/freentonic:latest
#
# Good output: "Chromium <ver> ..." then "exit=0 html_seen=1".
# A broken (e.g. SIGTRAP) build shows "exit=133 html_seen=0".
set -euo pipefail

HOST="${KAMAL_HOST:?set KAMAL_HOST to the deploy host}"
SSH_USER="${KAMAL_SSH_USER:-root}"
IMG="${1:-localhost:5000/freentonic:latest}"

ssh "$SSH_USER@$HOST" IMG="$IMG" 'bash -s' <<'REMOTE'
set -euo pipefail
echo "candidate image: $IMG"
docker run --rm --entrypoint sh "$IMG" -c '
  BIN=$(command -v chromium || command -v google-chrome || command -v chrome)
  echo "version: $($BIN --version 2>&1)"
  $BIN --headless=new --no-sandbox --disable-dev-shm-usage --disable-gpu \
    --dump-dom about:blank >/tmp/x 2>&1
  echo "exit=$? html_seen=$(grep -c "<html" /tmp/x 2>/dev/null || echo 0)"
  echo "----- last 8 lines -----"; tail -n 8 /tmp/x
'
REMOTE
