# Changelog

All notable user- and operator-visible changes to simplefreen.
Format adapted from [Keep a Changelog](https://keepachangelog.com/);
versioning will follow [SemVer](https://semver.org/) once 1.0 ships.

For architectural decisions and forward-looking work, see
[`docs/roadmap.md`](docs/roadmap.md).


## [Unreleased]

This batch lands the dev-loop polish + browse mode + workflows refresher
work. Cross-repo: the Browse-mode admin button requires the
`--interactive` flag added in the paired freentonic PR (#9).

### Changed (deploy config is now host-agnostic)

- **Deploy targets come from the environment.** `config/deploy.yml` and
  `sure/config/deploy.yml` read `KAMAL_HOST`, `SIMPLEFREEN_HOST` and
  `SURE_HOST` via ERB, and every script under `bin/`, `ops/` and
  `.kamal/hooks/` now **requires** `KAMAL_HOST` (no built-in default
  host). Export them from a gitignored `.envrc`. The `ops/reimport`
  Phase A full-canonical script likewise requires `SOURCES`.

### Security

- **Admin CSRF gate no longer trusts CORS origins.** A cookie-authenticated
  admin mutation must now carry an `Origin`/`Referer` matching
  `SIMPLEFREEN_PUBLIC_URL` only. Previously any origin listed in
  `SIMPLEFREEN_CORS_ALLOWED_ORIGINS` (meant for `/simplefin/*` reads) also
  passed, so an XSS on such an app could drive the admin API with the
  operator's session. No effect when the CORS list is empty (the default).

### Fixed (reliability + security review 2026-07-04)

- **Scheduler worker no longer dies on an unexpected exception.** A
  store/run-log/IO error escaping a job (e.g. ENOSPC) used to kill the
  worker thread, after which every sync silently queued forever with
  `/healthz` still green. The per-job body is now wrapped: it logs,
  best-effort-marks the profile `error`, and keeps running.
- **Sync success is no longer inferred from a stale cache file.** The
  exit-zero success gate now verifies THIS run's push actually landed
  (`state.last_run_id == run_id`) instead of `cache_store.exists?`, which
  any prior run's 14-day cache satisfied — so a restart mid-invoke that
  dropped the push token can't be logged as "sync ok" while history never
  advanced.
- **`last_synced_at` now means "last successful sync."** Failures record
  `last_attempt_at` instead, so staleness is honest; the auto-sync ticker
  paces retries on `last_attempt_at`.
- **Push-token TTL follows the configured sync timeout** (`timeout + 60s`)
  rather than a fixed 1860 s, so a long backfill's end-of-run push no
  longer 401s.
- **History-merge failures are surfaced**, not silent: the profile keeps
  serving the per-run envelope but records `history_merge_failed_at` /
  `last_merge_error`, counted in `/admin/api/metrics`.
- **New health signals:** `/admin/api/metrics` reports `profiles_stale`,
  `history_merge_failures`, and `scheduler_worker_alive`; `/healthz` body
  carries `scheduler_worker_alive` and reflects it in `ok` (status stays
  200 so proxy health-gating is unaffected).
- **Admin auth hardening:** session cookie is now `Secure`; cookie-authed
  mutations require a same-origin `Origin`/`Referer` (CSRF defense against
  same-site sibling subdomains); the login endpoint locks out after
  repeated failures.

### Added

- **Async `/invoke` client + incremental live-log tailing.** `FreentonicClient#invoke`
  now speaks freentonic's async invoke protocol (paired PR #25 / item
  #13): it `POST`s, expects `202 {run_id,"queued"}`, and polls
  `GET /runs/{run_id}` to a terminal state — staying blocking so the
  single-worker scheduler is unchanged. A `200` on the `POST` is still
  accepted as the legacy synchronous result, so this client works against
  both server versions. New `QueueFullError` (503) / `CancelledError`
  (queued-cancel) errors; transient poll blips tolerated with a monotonic
  deadline backstop. The active-job log panel now tails **incrementally**:
  after a one-shot prime it fetches only bytes appended since the last
  poll via `GET …/runs/:id/log?offset=<byte>` (backed by a new
  `FreentonicClient#tail_run_log` forward-Range primitive) instead of
  re-pulling the whole 256 KB tail every 2 s. A trailing partial UTF-8
  sequence is held back so a multibyte character is never split across
  polls.
- **Watchdog — push alerts on silent failures (ntfy).** A background
  watchdog now pushes a phone notification when a profile enters
  `needs_reauth`/`error`, goes stale (configured to auto-sync but its
  last *success* is older than `max(2× interval, 24h)`), or the
  scheduler worker thread dies — plus a low-priority "recovered" note
  when a problem clears. Delivery is a single stdlib `Net::HTTP` POST to
  ntfy.sh (or a self-hosted ntfy); zero new gems. Enabled by setting
  `SIMPLEFREEN_NTFY_URL` (optionally `SIMPLEFREEN_NTFY_TOKEN`); unset ⇒
  the thread never starts. Alerts are edge-triggered with a daily
  re-reminder, deduplicated across restarts via
  `$SIMPLEFREEN_DIR/watchdog.json`. Tunable with
  `SIMPLEFREEN_WATCHDOG_INTERVAL_SECONDS` /
  `SIMPLEFREEN_WATCHDOG_RENOTIFY_SECONDS`. This closes the review's O-2 /
  P1 gap ("a silently failing nightly sync would not be noticed"). See
  `docs/operator-guide.md` §8b.
- **`/healthz` now reports `stale_profiles`.** The unauthenticated
  liveness body carries a count of configured-to-sync profiles whose
  last success is overdue, so a body-aware uptime monitor can alarm on a
  quietly-wedged sync without scraping the bearer-gated metrics endpoint.
  Staleness is informational — it does not flip `ok` to `false` (the
  serving path still works). The staleness definition is shared with
  `/admin/api/metrics` and the watchdog (new `ProfileHealth` module) so
  the three surfaces can never disagree.
- **Auto-sync schedule editor on profile detail.** The
  `#/profiles/:key` page now has a dedicated Schedule panel: pick from
  preset cadences (manual, 15 min, 30 min, hourly, 3 h, 6 h, 12 h,
  daily) or enter a custom interval, click Save, and the profile's
  `sync_interval_seconds` is updated via PATCH. A hint line shows
  approximately when the next auto-sync is due.
- **"Sync all" button + queue visibility.** A new `↻ Sync all` button
  on the Manage view enqueues every source profile that has
  credentials and an access URL via `POST /admin/api/sync-all`. The
  scheduler runs them one at a time as before — banks dislike
  concurrent automation — so the button just stuffs the existing
  queue. The Dashboard's active-job banner now also lists pending
  queued profiles so the operator can see what's coming.
- **Durable transaction history + incremental syncs.** New
  `HistoryStore` accumulates every transaction ever observed per
  profile under `<root>/history/<key>/history.json`, deduped by
  SimpleFIN `id` with posted-beats-pending precedence so a late
  backfill can't regress a posted txn. `PushReceiver` merges each
  run into history and the SimpleFIN endpoint now serves the merged
  envelope, so a short scrape window no longer drops older
  transactions from what Actual / Sure / other clients see.
  `HistoryStore#rebuild_from_runs!` reconstructs from the immutable
  per-run canonicals on disk if `history.json` is ever lost.
- **Dynamic per-profile lookback driven by history.** The scheduler's
  new `resolve_lookback` computes `(today − last_tx_date) + overlap`
  per sync when `lookback_mode == "incremental"`, clamped to
  `[lookback_overlap_days, max_lookback_days]`. Cold-start (no
  history yet) falls through to `max_lookback_days` so the first run
  seeds a deep base before subsequent runs go incremental. Two new
  profile fields (`lookback_mode`, `lookback_overlap_days`); the
  resolver treats a missing/empty mode as `incremental`, so profiles
  predating this field upgrade transparently. Operator override via
  the "Sync now" prompt still wins over everything. New default for
  freshly-created profiles is `incremental`; operators can pin a
  profile to `fixed` (today's behavior) via API/PATCH.
- **Incremental-aware "Sync now" prompt.** The admin UI prompt now
  branches on `lookback_mode`: incremental profiles get an empty
  input box with a hint that blank means "auto-computed from history
  + Nd overlap"; fixed profiles keep the legacy seed-with-default
  behavior. Blank input omits `lookback` from the request body so
  the scheduler's resolver decides.
- **Browse mode** — `Browse` button on each profile + `Stop browsing`
  in the active-job banner. Opens Chrome at the bank's URL via VNC and
  lets the operator interact manually (no scrape, no credential
  filling). Used to warm a fresh Chrome fingerprint after `Clear
  session`, or to solve a bank-pushed 2FA / "verify it's you" prompt
  that flagged the session. New endpoints:
  `POST /admin/api/profiles/<key>/browse`,
  `POST /admin/api/runs/<run_id>/cancel`. New `FreentonicClient#cancel`
  method. New run-log outcome `browsed` (does not change the profile's
  sync state — flips back to `idle` regardless of how Chrome exited).
- **Workflows refresher** — `↻ Refresh workflows` button + version
  selector (branch / tag / commit SHA). Pulls a tarball from
  `github.com/GermanDZ/freentonic-providers` via the GitHub tarball
  API and lays providers down under the workflows root. Parses the
  resolved short SHA from the GitHub-named top-level dir, persists
  it to `.refresh-meta.json`, and surfaces it as a monospace badge
  in the panel header. New endpoint
  `POST /admin/api/workflows/refresh`; `GET /admin/api/workflows`
  now returns `{ workflows, meta }`. Source repo overridable via
  `SIMPLEFREEN_WORKFLOWS_SOURCE_REPO` env (`"owner/name"`).
- **noVNC same-origin via Caddy `/novnc/`** — Caddy reverse-proxies
  noVNC's HTML + websockify through the same TLS surface as the
  admin UI. The inline VNC iframe in the active-job banner now
  works under HTTPS without mixed-content blocking. `build_vnc_url`
  emits a same-origin path with `path=novnc/websockify`; the iframe
  uses the full `vnc.html` viewer (toolbar, scaling toggle,
  fullscreen, clipboard) instead of `vnc_lite.html`.
- **Per-run artifact gallery** in the admin UI — screenshots
  freentonic captures during a scrape are classified server-side
  and surfaced inline in the runs panel (thumbnails grid auto-open
  for failed runs, since the moment-of-failure screenshot is the
  most useful debug artifact). Other artifacts (logs, exports,
  reports) listed in a sibling collapsible. Backed by
  `GET /admin/api/profiles/<key>/runs/<run_id>/artifacts`
  (list + classify by extension) and `GET .../artifacts/<index>`
  (serve with `realpath` escape check + immutable cache headers).
- **Manual freentonic-health refresh button** + state badge in the
  admin UI header. POSTs `/admin/api/freentonic/health/probe` →
  `FreentonicHealth#probe_once`, closing the dead window after a
  `docker compose restart freentonic` to ~zero instead of waiting
  for the cadence tick.
- **Native-host dev loop** — `bin/dev-native` launcher +
  `examples/docker-compose.native.yml` overlay. simplefreen runs on
  the host (port 7777, reload Ruby/JS/CSS without a docker rebuild)
  while freentonic + Caddy stay containerized; Caddy proxies via
  `host.docker.internal:7777`. Bootstraps `dev/` on first run,
  mints `dev/.env`, and migrates legacy root-level dev files into
  it. Includes `--recreate` (force-recreate the container side
  before launching), `--down`, color-coded preflight checks, and a
  pinned `COMPOSE_PROJECT_NAME=simplefreen` so commands run from
  any cwd land on the same containers.
- **`dev/` directory convention** — gitignored as a unit
  (`/dev/` in `.gitignore`); single top-level dir keeps the repo
  root clean (compose copies, `.env`, secrets, on-disk state all
  live under it).
- New env vars surfaced for ops:
  - `SIMPLEFREEN_FREENTONIC_HEALTH_INTERVAL_SECONDS` — health-probe
    cadence (defaults to 5 min in code, 20 s in the dev compose).
  - `SIMPLEFREEN_RUNS_ARTIFACTS_DIR` — per-run output dir
    (defaults to `/workspace/runs`).
  - `SIMPLEFREEN_BACKEND` — Caddy reverse-proxy target (the
    native overlay sets it to `host.docker.internal:7777`).
  - `SIMPLEFREEN_WORKFLOWS_SOURCE_REPO` — fork/private-mirror
    override for the workflows refresher.
- New error class `Simplefreen::OperatorError` for operator-fixable
  failures whose message is already human-readable; the scheduler
  surfaces it verbatim into `last_error` instead of wrapping it as
  `"invoke setup failed: ClassName: ..."`.

### Changed

- **Always-windowed Chrome, always-on VNC for every sync.** Banks
  fingerprint the headless Chromium build and outright block it
  (notably ING). The scheduler hard-codes `chrome.headless = false`
  in `build_invoke_body`, mints a per-run VNC password
  unconditionally, and surfaces it in `active_job` regardless of
  trigger. The two-button UI (`Sync now` vs `Sync (headed/VNC)`)
  collapses into a single `Sync now`; `Re-authenticate (VNC)` stays
  as a primary-styled label when state is `needs_reauth`, with
  identical backend behavior.
- noVNC click-through URL forced to `http://` regardless of
  `SIMPLEFREEN_PUBLIC_URL`'s scheme (the host-published port is
  plain HTTP from the freentonic container; inheriting `https://`
  produced an unconnectable link in dev where the SimpleFIN surface
  is HTTPS). Now moot since the iframe goes through Caddy
  same-origin, but the link still uses the standalone host port for
  scripts that want it.
- noVNC host port moved from `6080` to `17080` to dodge collisions
  with HP printer discovery and other VNC tools. Container-side
  port stays `6080`; only the host publish changed.
- Workflow dropdown filters to `<provider_slug>/workflow.yml` only
  (was: every `*.yml` under the workflows root, which surfaced
  `config.yml` and other non-workflow files). UI displays the slug
  (`ing`) instead of the full path; the stored value is unchanged.
- Workflow YAMLs are now mounted into the simplefreen container
  too (read-write at `/workflows`, so the refresher can write).
  Previously only freentonic had them, so the admin dropdown was
  always empty.
- `examples/docker-compose.yml`: simplefreen no longer publishes a
  host port directly; the Caddy sidecar is the only public surface.
  `SIMPLEFREEN_PUBLIC_URL` default switched from
  `http://simplefreen:7878` to `https://simplefreen.localhost`.
- `docs/operator-guide.md`: dev-mode warning callout, §4 walk-
  through, and "Production deployment" section updated to reflect
  that dev now serves HTTPS by default. Stale "patched sync-server"
  references removed throughout.
- `docs/development.md`: troubleshooting table grew the
  bank-detection-flagged-the-session row (Browse + clean-IP fix
  path) and the workflow-dropdown-empty row (refresh button hint).
- `docs/roadmap.md`: Recently shipped section captures the local-
  HTTPS dev stack, artifact gallery, freentonic-health refresh,
  noVNC routing, native-host dev loop, always-windowed Chrome, and
  browse mode. Replaces the stale "plain HTTP dev mode" locked-
  decision wording.

### Fixed

- **Graceful shutdown actually exits.** `bin/simplefreen` deferred
  shutdown work to a thread spawned from the signal handler
  (closing the listen socket from inside a signal handler segfaults
  the Ruby VM on macOS arm64), `Server#shutdown` now does
  `socket.shutdown(Socket::SHUT_RDWR)` before `close` (macOS needs
  this to wake `accept(2)`), and any in-flight invoke is cancelled
  via `freentonic_client.cancel(active_run_id)` before the
  scheduler thread is joined. Final `exit 0` belt-and-suspenders.
  Second SIGTERM/SIGINT triggers `exit!(130)` immediately as an
  escape hatch.
- **Friendly "no credentials" message** instead of leaking the raw
  freentonic 422 (`credentials.inline must be a non-empty object`).
  Admin precheck in `handle_sync` / `handle_browse` returns 422
  with a "no credentials configured for <key> — click Credentials
  and fill in the bank login fields" message; the scheduler keeps
  a defensive check for the race where credentials get deleted
  between enqueue and worker pickup.
- Active-job banner no longer rebuilds itself on every 2-second
  status poll. Previously the entire `<section>` was replaced each
  tick, which wiped the live-log `<pre>` and any embedded iframe.
  Now short-circuits when `run_id` is unchanged (mirrors the diff
  pattern in `renderProfileRow`).
- `bin/dev-native` migration function no longer silently exits
  the script under `set -e` when nothing was migrated (the
  `[[ false ]] && echo` idiom returns 1; rewritten as an explicit
  `if/then/fi`).

## [0.1.0] — Unreleased

Initial release. Two-service SimpleFIN bridge for Actual Budget,
extracted from freentonic's bolted-on simplefin subsystem into a
standalone, deployable service. On-disk state layout is identical to
the bundled bridge so an existing deployment migrates with a single
bind-mount repoint.

### Added
- SimpleFIN wire protocol surface: setup-token claim exchange and
  `/simplefin/<key>/accounts` (`cad177d`).
- Per-profile state machine (`idle → queued → running → ready |
  needs_reauth | error`) and in-memory scheduler with single worker
  thread (`cad177d`).
- One-shot push-token handshake: SHA-256 hashed mint table, TTL-
  bounded, single-use, scoped per `run_id`. Threaded through
  freentonic's `/invoke` body so the stock `http` exporter can call
  back to `/push/<run_id>` (`cad177d`).
- Background `/healthz` probe of freentonic; scheduler gates on the
  `:active` / `:degraded` state and short-circuits queued jobs to
  `error` during degradation (`cad177d`).
- AES-256-GCM credential storage with per-profile PBKDF2 subkeys.
  Master key from `SIMPLEFREEN_SECRETS_KEY` (`cad177d`).
- Admin UI + REST API gated by `SIMPLEFREEN_ADMIN_PASSWORD` for
  profile management, credential entry, and re-auth orchestration
  (`cad177d`).
- Atomic on-disk state via `AtomicFile.write_json` (tmp → flock →
  fsync → rename); strict filename charset validation against path
  traversal (`cad177d`).
- VNC-based re-authentication flow for `needs_reauth` profiles
  (`cad177d`).
- `INSTITUTION_METADATA` lookup table (`ing` / `revolut` / `fintonic`
  / `unicaja`) so Actual's org UI stays polished now that canonical
  carries only the institution slug (`31d11d0`).

### Changed
- `Reshape` now consumes the freentonic v0.1 canonical envelope
  directly: top-level `accounts[]` + `transactions[]`, decimal-string
  money, `acc_` / `txn_` deterministic IDs. Drops `cents_to_decimal`,
  `stable_tx_id`, and the legacy field-fallback chains. `PushReceiver`
  returns 422 for payloads missing `schema_version` (`31d11d0`).
- Documented dev-mode plain HTTP as non-spec-compliant; added
  production TLS recipe (Caddy reverse-proxy config, admin-UI IP
  allowlist, secret hygiene, pre-live verification checklist) to
  `docs/operator-guide.md` (`f81df1f`).

### Fixed
- SimpleFIN v1 spec compliance: `403` on Basic-auth failure (was
  `401`); pending transactions emit `posted: 0` with the provider's
  date preserved under `transacted_at`; `available-balance` omitted
  when equal to `balance`; `payee` moved under `extra` so spec-
  literal clients don't see an unknown top-level key (`a6d5bc9`).

### Documented
- Locked the architectural boundary: freentonic stays canonical-only;
  simplefreen owns the SimpleFIN translation. Reasoning captured in
  both `architecture.md` and the migration doc to prevent re-
  litigation (`e1ee44f`).
