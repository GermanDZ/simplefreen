# Architecture

Simplefreen is the persistent side of a two-service SimpleFIN bridge
for Actual Budget. The bank-scraping side is a separate
[freentonic](https://github.com/GermanDZ/freentonic) container.
They communicate over HTTP with two bearer tokens.

## Responsibility boundary

- **freentonic is a pure scraper.** It knows about banks, browsers,
  and the canonical data model — nothing else. It always emits the
  canonical envelope. It has no SimpleFIN knowledge and never will.
- **simplefreen owns SimpleFIN.** It receives the canonical envelope
  on `/push/<run_id>`, converts it to a SimpleFIN envelope here
  (`lib/simplefreen/reshape.rb`), caches the result, and serves it
  via `/simplefin/<key>/accounts`.

This boundary is deliberate. See
[freentonic-canonical-migration.md §"Non-goal"](freentonic-canonical-migration.md#non-goal-pushing-simplefin-knowledge-into-freentonic)
for the reasoning — short version: freentonic stays generic so other
consumers (YNAB-shaped bridge, CSV job, etc.) can fan out from the
canonical model without freentonic accumulating per-consumer formatters.

## Request flow

```
┌────────────────────┐   SimpleFIN protocol   ┌───────────────────────┐
│   Actual Budget    │ ────────────────────▶ │     simplefreen       │
│   (sync-server)    │                        │                       │
└────────────────────┘                        │ ┌────────────────┐    │
                                              │ │ profile store  │    │
                                              │ │ cache store    │    │
                                              │ │ state machine  │    │
                                              │ │ scheduler      │    │
                                              │ │ admin UI + API │    │
                                              │ │ reshape        │    │
                                              │ │ push receiver  │    │
                                              │ │ push-token mint│    │
                                              │ └────────────────┘    │
                                              └───────┬───────▲───────┘
                                          (1) POST /invoke    │
                                          Bearer: FRTC_TOKEN  │
                                          body: creds +       │
                                                export:{      │ (2) POST /push/<run_id>
                                                  mode: http, │ Bearer: <one-shot token>
                                                  url: /push/x│ body: normalized payload
                                                  token: <x>} │
                                                      │       │
                                                      ▼       │
                                              ┌───────────────────────┐
                                              │      Freentonic       │
                                              │  (pure scraper)       │
                                              │  /invoke + exporters  │
                                              └───────────────────────┘
```

## Two bearer tokens

- **`FREENTONIC_INVOKE_TOKEN`** — configured on both sides. Simplefreen
  holds the value and sends it on every outbound `/invoke`. Freentonic
  verifies in its existing invoke-server middleware.
- **One-shot push token, per run.** Minted by simplefreen inside
  `Scheduler#process_job`. Passed to freentonic via the `/invoke`
  body's `export.token`. Freentonic threads it into
  `FREENTONIC_HTTP_TOKEN` on the child process (same env the stock
  HTTP exporter reads today — no changes to freentonic needed). The
  `http` exporter then uses it as `Authorization: Bearer` on the
  callback to `/push/<run_id>`. Simplefreen's `PushReceiver` verifies
  against the in-memory mint-table and consumes on success.

The mint-table (`PushTokens`) stores SHA-256 hashes, not plaintext.
Entries are removed on first successful consume or TTL expiry (default
= workflow timeout + 60 s). Replay is impossible.

## State machine per profile

```
  idle ─── GET /accounts ─▶ queued ── picked up by worker ─▶ running ─── exit 0 + cached ─▶ ready
                              ▲                                      │
                              │                                      ├── exit 3 ────────▶ needs_reauth
                              │                                      ├── exit !=0,!=3 ──▶ error
                              │                                      └── freentonic
                              │                                          unreachable ───▶ error
                              └── manual "Sync now" / admin "Re-auth" /
                                  auto-sync ticker re-enqueues
```

The cache is **persistent across serves** — real SimpleFIN returns
the same payload on repeated calls until a fresh scrape replaces it.
`GET /simplefin/<key>/accounts` reads the cache without unlinking;
a successful push overwrites it atomically via `AtomicFile.write_json`.

## State dir layout

```
/data/
├── profiles/<key>.json             # encrypted creds + access-URL hash
├── state/<key>.json                # latest sync outcome
├── cache/<key>/latest.json         # most recent SimpleFIN envelope
├── claims/<claim_id>.json          # one-shot setup-token records
└── runs/<key>/<run_id>.json        # per-sync metadata history
```

All writes go through `AtomicFile.write_json` (tmp → flock → fsync →
rename). Every component of every path is validated against
`Paths::FILENAME_PATTERN = /\A[A-Za-z0-9_.\-]{1,128}\z/` before being
joined.

## Health gating

`FreentonicHealth` runs a background thread that hits
`FREENTONIC_URL/healthz` every 5 min. When the call errors the state
flips to `:degraded`; the scheduler consults this before dequeuing a
job. During degradation, enqueued syncs are bounced straight to the
`error` state with a descriptive message — they don't stall in the
queue forever. Next successful health probe restores normal service.

## Recovery on restart

`Feature#recover_on_boot!` (called by `bin/simplefreen`) scans
`state/*.json` and resets any `queued` or `running` entry to `idle`.
The in-memory scheduler queue and mint-table are both ephemeral —
lost at restart. In practice Actual's next `/accounts` poll
re-enqueues anything useful.
