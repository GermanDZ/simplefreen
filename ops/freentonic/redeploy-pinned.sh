#!/usr/bin/env bash
# Rebuild the freentonic image from a clean checkout of freentonic `main`
# (pinned Chromium + async server) and roll the accessory onto it — but ONLY
# if the freshly built image passes a Chrome smoke test first. Builds from a
# throwaway clone, so a dev checkout at ../freentonic is never used or touched.
#
# Env: FREENTONIC_REF (default main), FREENTONIC_REPO
#      (default https://github.com/GermanDZ/freentonic.git),
#      KAMAL_HOST, KAMAL_SSH_USER.
set -euo pipefail

# This script lives at <repo>/ops/freentonic/ — derive the repo root.
SIMPLEFREEN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOST="${KAMAL_HOST:?set KAMAL_HOST to the deploy host}"
SSH_USER="${KAMAL_SSH_USER:-root}"
REF="${FREENTONIC_REF:-main}"
REPO="${FREENTONIC_REPO:-https://github.com/GermanDZ/freentonic.git}"
SRC=/tmp/freentonic-redeploy-src

echo "### 1/4  clone freentonic @ $REF (throwaway build source) ###"
rm -rf "$SRC"
git clone --depth 1 -b "$REF" "$REPO" "$SRC"
echo "source commit: $(git -C "$SRC" rev-parse --short HEAD)"
grep -q "chromium-pin" "$SRC/Dockerfile" \
  && echo "OK: Dockerfile has the chromium* group pin" \
  || { echo "ABORT: this checkout lacks the Chromium version pin"; exit 1; }

echo; echo "### 2/4  build image on the LXC (pushes localhost:5000/freentonic:latest) ###"
cd "$SIMPLEFREEN_DIR"
FREENTONIC_SRC="$SRC" bin/build-freentonic-image

echo; echo "### 3/4  smoke-test the freshly built :latest (Chromium must launch) ###"
OUT=$(ssh "$SSH_USER@$HOST" 'docker run --rm --entrypoint sh localhost:5000/freentonic:latest -c "
  BIN=\$(command -v chromium)
  \$BIN --version
  \$BIN --headless=new --no-sandbox --disable-dev-shm-usage --disable-gpu \
    --dump-dom about:blank >/tmp/x 2>&1
  echo exit=\$? html=\$(grep -c \"<html\" /tmp/x 2>/dev/null || echo 0)
"' 2>&1 || true)
echo "$OUT"
echo "$OUT" | grep -q "exit=0" || { echo "ABORT: Chrome did not exit cleanly (SIGTRAP?) — accessory NOT rebooted"; exit 1; }
echo "$OUT" | grep -q "html=1" || { echo "ABORT: Chrome did not render about:blank — accessory NOT rebooted"; exit 1; }
echo ">>> smoke test PASSED"

echo; echo "### 4/4  roll the accessory onto the new image ###"
kamal accessory reboot freentonic

echo; echo "### verify live healthz (retries; async server => body has in_flight) ###"
ssh "$SSH_USER@$HOST" 'web=$(docker ps --format "{{.Names}}" | grep simplefreen-web | head -1);
for i in $(seq 1 12); do
  out=$(docker exec "$web" ruby -e "require \"net/http\"; begin; print Net::HTTP.get(URI(\"http://simplefreen-freentonic:7878/healthz\")); rescue => e; print \"booting (#{e.class})\"; end" 2>/dev/null);
  echo "$out";
  echo "$out" | grep -q in_flight && break;
  sleep 3;
done'
echo; echo "Done. Trigger a sync from the admin UI."
