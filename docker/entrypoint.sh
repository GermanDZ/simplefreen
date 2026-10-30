#!/bin/bash
set -euo pipefail

# Fail-fast env validation. The server will bail on the same checks,
# but doing it here gives a cleaner "container exited 2" signal.
missing=()
[ -z "${SIMPLEFREEN_SECRETS_KEY:-}" ]    && missing+=("SIMPLEFREEN_SECRETS_KEY")
[ -z "${SIMPLEFREEN_ADMIN_PASSWORD:-}" ] && missing+=("SIMPLEFREEN_ADMIN_PASSWORD")
[ -z "${SIMPLEFREEN_PUBLIC_URL:-}" ]     && missing+=("SIMPLEFREEN_PUBLIC_URL")
[ -z "${FREENTONIC_URL:-}" ]             && missing+=("FREENTONIC_URL")
[ -z "${FREENTONIC_INVOKE_TOKEN:-}" ]    && missing+=("FREENTONIC_INVOKE_TOKEN")
if [ "${#missing[@]}" -gt 0 ]; then
  echo "[simplefreen] missing required env vars: ${missing[*]}" >&2
  exit 2
fi

# State dir — mkdir -p is safe whether it's a fresh volume or an
# existing bind mount.
SIMPLEFREEN_ROOT="${SIMPLEFREEN_ROOT:-/data}"
mkdir -p "${SIMPLEFREEN_ROOT}"
# Best-effort perms tightening. On a bind-mounted host dir owned by
# a different uid, chmod will fail with EPERM; not fatal because
# every file we *write* is 0600 via AtomicFile.
chmod 0700 "${SIMPLEFREEN_ROOT}" 2>/dev/null || true

echo "[simplefreen] starting (root=${SIMPLEFREEN_ROOT} freentonic=${FREENTONIC_URL})"
exec "$@"
