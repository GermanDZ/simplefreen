#!/usr/bin/env bash
# Diagnose a "Chrome did not respond on debug port" / failing-scrape on the
# freentonic accessory. Read-only: gathers evidence, changes nothing.
#
# Usage: ./diagnose-chrome.sh [RUN_ID]
#   RUN_ID defaults to the most recent run under /workspace/runs.
#
# Env: KAMAL_HOST (required), KAMAL_SSH_USER (root),
#      FREENTONIC_CONTAINER (simplefreen-freentonic).
set -euo pipefail

HOST="${KAMAL_HOST:?set KAMAL_HOST to the deploy host}"
SSH_USER="${KAMAL_SSH_USER:-root}"
CTR="${FREENTONIC_CONTAINER:-simplefreen-freentonic}"
RUN_ID="${1:-}"

ssh "$SSH_USER@$HOST" RUN_ID="$RUN_ID" CTR="$CTR" 'bash -s' <<'REMOTE'
set -euo pipefail
echo "##### freentonic Chrome-launch diagnostics ($CTR) #####"

RUN_ID="$(docker exec "$CTR" sh -lc "
  if [ -n \"$RUN_ID\" ]; then echo \"$RUN_ID\"; else ls -1t /workspace/runs | head -1; fi
")"
echo "run_id: $RUN_ID"

echo; echo "===== run log (full) ====="
docker exec "$CTR" sh -lc "cat /workspace/runs/'$RUN_ID'/log 2>/dev/null || echo '(no log file)'"

echo; echo "===== live processes (xvfb / chrome / x11vnc) ====="
docker exec "$CTR" sh -lc "ps aux | grep -iE 'xvfb|chrom|x11vnc' | grep -v grep || echo '(none running)'"

echo; echo "===== DISPLAY + Xvfb socket ====="
docker exec "$CTR" sh -lc 'echo DISPLAY=${DISPLAY:-<unset>}; ls -la /tmp/.X11-unix/ 2>/dev/null || echo "(no /tmp/.X11-unix)"'

echo; echo "===== /dev/shm ====="
docker exec "$CTR" sh -lc 'df -h /dev/shm'

echo; echo "===== Chrome profile Singleton* locks (freentonic clears these itself pre-launch) ====="
docker exec "$CTR" sh -lc '
  root=/home/freentonic/.cache/freentonic/chrome
  find "$root" -maxdepth 2 -iname "Singleton*" -print 2>/dev/null || echo "  (none)"
'

echo; echo "===== chrome version probe ====="
docker exec "$CTR" sh -lc '
  bin="$(command -v chromium || command -v google-chrome || true)"
  echo "chrome bin: ${bin:-<not found>}"; [ -n "$bin" ] && "$bin" --version 2>&1 | head -1 || true
'

echo; echo "===== container startup logs (tail) ====="
docker logs --tail 80 "$CTR" 2>&1 | tail -80
echo; echo "##### end #####"
REMOTE
