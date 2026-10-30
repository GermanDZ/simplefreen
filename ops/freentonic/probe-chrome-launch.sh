#!/usr/bin/env bash
# Reproduce freentonic's CDP Chrome launch inside the running container, with
# stderr CAPTURED (freentonic sends the child's stderr to /dev/null, hiding
# crash reasons). Isolates "Chrome itself is broken" from "only the debug
# port is broken". Throwaway profile/port — touches no real bank profile.
#
# A clean exit here is `exit=0`. A Chromium that SIGTRAPs on launch (the
# 2026-07 unpinned-150 regression) shows `exit=133`.
#
# Env: KAMAL_HOST, KAMAL_SSH_USER, FREENTONIC_CONTAINER (see diagnose-chrome.sh).
set -euo pipefail

HOST="${KAMAL_HOST:?set KAMAL_HOST to the deploy host}"
SSH_USER="${KAMAL_SSH_USER:-root}"
CTR="${FREENTONIC_CONTAINER:-simplefreen-freentonic}"

# Pipe a plain inner script into the container's shell — no nested quoting.
ssh "$SSH_USER@$HOST" "docker exec -i $CTR sh -s" <<'INNER'
set -u
export DISPLAY=:99
BIN=$(command -v chromium || command -v google-chrome || command -v chrome)
echo "chrome: $($BIN --version 2>&1)"
echo "dbus socket: $(ls /run/dbus/system_bus_socket 2>&1)  (absence is benign)"

echo
echo "=== can Chrome render at all? (headless --dump-dom about:blank) ==="
$BIN --headless=new --no-sandbox --disable-dev-shm-usage --disable-gpu \
  --dump-dom about:blank >/tmp/probe1.out 2>&1
echo "exit=$?  html_seen=$(grep -c '<html' /tmp/probe1.out 2>/dev/null || echo 0)"
echo "----- output (first 30 lines) -----"; head -n 30 /tmp/probe1.out

echo
echo "=== does the remote-debugging port open? (freentonic's CDP flag set) ==="
rm -rf /tmp/probeprof
$BIN --remote-debugging-port=9333 --user-data-dir=/tmp/probeprof \
  --no-first-run --no-default-browser-check \
  --disable-features=IsolateOrigins,site-per-process --disable-infobars \
  --lang=es-ES --window-size=1280,800 \
  --disable-blink-features=AutomationControlled --test-type \
  --no-sandbox --disable-dev-shm-usage --disable-gpu >/tmp/probe2.out 2>&1 &
P=$!
i=0; OK=""
while [ $i -lt 12 ]; do
  V=$(ruby -e 'require "net/http"; begin; print Net::HTTP.get(URI("http://localhost:9333/json/version")); rescue; end' 2>/dev/null)
  [ -n "$V" ] && { OK="$V"; break; }
  i=$((i+1)); sleep 1
done
kill -0 $P 2>/dev/null && ALIVE=ALIVE || ALIVE=EXITED
echo "port: $([ -n "$OK" ] && echo OPEN || echo NOT-OPEN)  chrome: $ALIVE"
[ -n "$OK" ] && echo "json/version: $OK"
echo "----- output (first 30 lines) -----"; head -n 30 /tmp/probe2.out
kill $P 2>/dev/null; pkill -f "user-data-dir=/tmp/probeprof" 2>/dev/null
rm -rf /tmp/probeprof /tmp/probe1.out /tmp/probe2.out
echo; echo "##### done #####"
INNER
