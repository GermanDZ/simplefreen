# freentonic ops scripts

Operational tooling for the **freentonic** invoke-server accessory (the
Chrome-in-a-container that simplefreen drives to scrape banks). These grew
out of the 2026-07-05 incident where a deploy rebuilt the image and an
**unpinned Chromium floated from 148 → 150**, which SIGTRAPs (exit 133) on
launch — Chrome never opened its debug port, so every sync failed with
`Chrome did not respond on debug port after 45s` → `exit 1 (user_error)`.

All scripts talk to the LXC over SSH and honor these env vars (with the
usual defaults):

| var | default |
|---|---|
| `KAMAL_HOST` | *(required)* |
| `KAMAL_SSH_USER` | `root` |
| `FREENTONIC_CONTAINER` | `simplefreen-freentonic` |

## The image is built from source on every deploy

`.kamal/hooks/pre-deploy` runs `bin/build-freentonic-image`, which builds the
freentonic image on the LXC and pushes `localhost:5000/freentonic:latest` to
the host-local registry. Source priority: `$FREENTONIC_SRC` → sibling
`../freentonic` → `git clone $FREENTONIC_REPO@$FREENTONIC_REF`.

> ⚠️ The sibling `../freentonic` often sits on a **dev branch**. `kamal deploy`
> will happily build from it. To deploy a specific freentonic state, build
> from a clean clone (`redeploy-pinned.sh` does exactly this) rather than
> whatever your working checkout happens to be on.

## Scripts

| script | what it does | mutates? |
|---|---|---|
| `diagnose-chrome.sh [RUN_ID]` | Dump a run's full log, live xvfb/chrome/x11vnc processes, `/dev/shm`, profile locks, chrome version, and container startup logs. First stop when a scrape fails. | read-only |
| `probe-chrome-launch.sh` | Reproduce freentonic's CDP Chrome launch **with stderr captured** (freentonic pipes it to `/dev/null`). Tells "Chrome itself is broken" (`exit=133`) from "only the debug port is broken". | read-only |
| `verify-image-chrome.sh [IMAGE]` | Smoke-test any freentonic image's Chromium in a throwaway container (`--dump-dom about:blank`). Vet a build/rollback candidate. | read-only |
| `cleanup-lxc-disk.sh` | Reclaim disk: prune build cache + dangling layers, remove old freentonic tags (keeps `:latest` + a rollback tag; skips in-use images). | host images |
| `registry-gc.sh [TAG ...]` | Reclaim the host-local **registry** (`kamal-local-registry`), which `docker rmi` can't touch — recreates its volume and repushes only the kept tags (default `latest 8b8414e`). Safe: the live accessory runs from the local image, not the registry. | registry volume |
| `redeploy-pinned.sh` | The happy path: clone freentonic `main` → build → **smoke-test the built image** → `kamal accessory reboot` → verify healthz. Refuses to reboot on a bad build. | prod deploy |
| `rollback-image.sh [GOOD_IMAGE]` | Emergency: retag `:latest` to a known-good image + push, so a `kamal accessory reboot` restores service before you fix the build. | prod image tag |

## Runbook: "sync is failing"

1. **`diagnose-chrome.sh`** — read the run log tail.
   - `Chrome did not respond on debug port after 45s` → Chrome-launch problem, go to 2.
   - `refusing to send a bearer token over cleartext` → freentonic exporter too
     strict for the internal push (fixed upstream 2026-07; needs a rebuild).
   - reaches `Exporting via http... → POST … 200` then `exit 0` → healthy.
2. **`probe-chrome-launch.sh`** — if `exit=133`, Chromium is broken in the
   image (the float regression). Confirm the pin, then rebuild.
3. **Recover now:** `rollback-image.sh` → `kamal accessory reboot freentonic`
   (roll to the last known-good image, e.g. Chromium 148).
4. **Fix properly:** ensure freentonic `main` pins Chromium, then
   **`redeploy-pinned.sh`** (clean-clone build, smoke-gated). If the build
   dies with `no space left on device`, run **`cleanup-lxc-disk.sh`** and retry.

## Disk reclaim

The LXC root is small (20 GB), and each deploy adds a ~1.25 GB image plus
build cache. Two independent stores fill up, reclaimed by two scripts:

- **Docker image store** → `cleanup-lxc-disk.sh` (build cache, dangling
  layers, old tags).
- **Host-local registry** (`kamal-local-registry`) → `registry-gc.sh`.
  `docker rmi` does *not* touch the registry, so old pushed `:<sha>` blobs
  accumulate there separately (2.5 GB after a month in the 2026-07 incident).

The `simplefreen_runs` volume is tiny (a few MB) — not worth trimming. The
`simplefreen_freentonic_chrome` volume (~1 GB) is per-bank login state — do
**not** delete it, or every provider needs a fresh login/reauth.

## Note on `kamal accessory reboot`

A freshly rebooted accessory needs a few seconds to bring up Xvfb → x11vnc →
the invoke-server on `:7878`; a healthz probe fired immediately races that and
gets `Connection refused`. `redeploy-pinned.sh` retries. The container also
comes up with a fresh hostname and empty `/tmp`, but freentonic's CDP launcher
clears stale `Singleton*` profile locks before launching Chrome, so that
doesn't need manual intervention.
