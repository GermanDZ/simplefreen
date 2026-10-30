# Roadmap

The forward-looking companion to [`architecture.md`](architecture.md)
(current state) and [`CHANGELOG.md`](../CHANGELOG.md) (past releases).

Three sections:

- **Locked decisions** — settled architectural calls. Read these
  before proposing changes that would reverse them.
- **Next up** — concrete planned work, ordered.
- **Deferred / non-goals** — explicitly out of scope, with reasoning.

Each entry under "Locked decisions" and "Deferred / non-goals" carries
a **Why:** line so future readers can judge edge cases instead of
re-litigating the call.

---

## Locked decisions

### freentonic stays canonical-only; simplefreen owns SimpleFIN translation

**Why:** freentonic is a pure scraper — it knows banks, browsers, and
the canonical data model, nothing else. Pushing SimpleFIN knowledge
into freentonic would force it to grow N consumer protocols and
couple every SimpleFIN-spec tweak to a freentonic release. The
canonical model exists precisely so consumers (simplefreen today, a
hypothetical YNAB bridge tomorrow) can fan out independently.

**Pointer:** commit `e1ee44f`;
[`architecture.md` § Responsibility boundary](architecture.md#responsibility-boundary);
[`freentonic-canonical-migration.md` § Non-goal](freentonic-canonical-migration.md#non-goal-pushing-simplefin-knowledge-into-freentonic).

### Zero runtime gem dependencies

**Why:** trivial supply chain, small attack surface, mirrors
freentonic's same invariant. Trade-off is rolling our own HTTP / JSON
handling — acceptable at this surface size.

**Pointer:** [`AGENTS.md` § Invariants #1](../AGENTS.md).

### In-memory scheduler queue and push-token mint-table

**Why:** `recover_on_boot!` resets `queued`/`running` profiles to
`idle`; Actual's next `/accounts` poll re-enqueues anything useful.
Acceptable loss for a self-host bridge — a sync that was running at
crash time gets re-triggered, not silently dropped. Durable queueing
would buy reliability we don't need at this scale.

**Pointer:** [`architecture.md` § Recovery on restart](architecture.md#recovery-on-restart).

### Local-HTTPS dev with Caddy's internal CA; production needs a publicly-trusted cert

**Why:** the SimpleFIN spec mandates HTTPS on every hop, and stock
`actualbudget/actual-server` enforces it. The dev stack ships a Caddy
sidecar that mints a cert from its bundled local CA — enough for
dev once the developer trusts that CA. Production must swap the
internal cert for a publicly-trusted one (Let's Encrypt, your CA);
running with the local CA on the open internet is non-compliant.

**Pointer:** commits `f81df1f`, `538e72a`;
[`development.md`](development.md);
[`operator-guide.md` § Production deployment](operator-guide.md#production-deployment).

### Single-admin, single-tenant

**Why:** the admin surface is gated by one bearer
(`SIMPLEFREEN_ADMIN_PASSWORD`). Designed for one operator running
their own bridge. Multi-admin or multi-tenant would change the trust
model fundamentally.

### YAML parsing only via `YAML.safe_load`

**Why:** every YAML parse path uses
`YAML.safe_load(permitted_classes: [], aliases: false)`. No
deserialization gadgets, no surprise object instantiation. Workflow
YAMLs are read solely to surface the `secrets:` block in
`AdminApi#declared_secrets`.

**Pointer:** [`AGENTS.md` § Invariants #4](../AGENTS.md).

---

## Recently shipped

- **Local-HTTPS dev stack** — Caddy sidecar in `examples/docker-compose.yml`
  + `examples/Caddyfile` + walk-through in `docs/development.md`.
  Dev loop now matches the production HTTPS shape and works against
  stock `actualbudget/actual-server`.
- **Per-run screenshot gallery + artifact list** in the admin UI.
  Backed by `GET /admin/api/profiles/<key>/runs/<run_id>/artifacts`
  + `/artifacts/<index>` with realpath escape protection. New mount
  in compose: `freentonic-runs` → `/workspace/runs:ro` on
  simplefreen. Auto-opens for failed runs.
- **Manual freentonic-health refresh button** + state badge in the
  admin UI header. Backed by `POST /admin/api/freentonic/health/probe`.
- **noVNC reverse-proxied through Caddy at `/novnc/`**, same-origin
  with the admin UI. Inline VNC iframe in the active-job banner now
  works under HTTPS — no more mixed-content blocking. Operator can
  watch 2FA prompts and other interstitials live.
- **Native-host dev loop**: `bin/dev-native` launcher +
  `examples/docker-compose.native.yml` overlay. simplefreen runs on
  the host (port 7777), freentonic + Caddy stay containerized;
  Caddy proxies via `host.docker.internal:7777`. Saves the
  rebuild-image / recreate-container loop on every Ruby or JS edit.
- **Always-windowed Chrome** (never headless) — banks fingerprint
  headless Chromium and block it. The `headed` flag now only
  controls operator VNC visibility, not the underlying Chrome
  rendering.
- **Browse mode** — `Browse` admin button + cross-repo
  `--interactive` flag on freentonic. Opens Chrome at the bank URL
  via VNC and idles until the operator clicks `Stop browsing`.
  Used to warm a fresh Chrome fingerprint or to solve a bank 2FA
  prompt without the workflow's scrape steps interfering.
- **Workflows refresher with version selector** — `↻ Refresh
  workflows` admin button. Pulls a tarball from
  `github.com/GermanDZ/freentonic-providers` at any branch / tag /
  commit SHA via the GitHub tarball API. Persists
  `.refresh-meta.json` and surfaces a monospace badge in the admin
  header so the operator always knows what's installed.
- **`dev/` directory convention** — `bin/dev-native` bootstraps
  `dev/` with compose copies, secrets, and on-disk state; the whole
  dir is gitignored as a unit so the repo root stays clean. Auto-
  migrates legacy root-level dev files on first run.

## Next up

### Anti-fingerprint stealth patches for automated syncs

**What:** Port the techniques in
[puppeteer-extra-plugin-stealth](https://github.com/berstend/puppeteer-extra/tree/master/packages/puppeteer-extra-plugin-stealth)
to freentonic's CDP path. The plugin is a collection of evaluate-on-
new-document patches that mask ~30 different bot-detection signals:
`navigator.webdriver`, `navigator.languages`, `navigator.plugins`,
`navigator.permissions.query`, `navigator.userAgentData`, WebGL
vendor/renderer, Chrome runtime, console.debug, iframe contentWindow,
and more.

Land as a Ruby module in freentonic
(`lib/freentonic/stages/stealth.rb`) that builds the script and the
Connect stage injects via `Page.addScriptToEvaluateOnNewDocument`
right after `mask_webdriver`. Each patch is a small JS snippet — the
work is collecting + maintaining the corpus, not the injection
plumbing.

**Why:** Today's `mask_webdriver` only patches one signal. Banks
(ING, others) fingerprint many more. Browse mode dodged this by
removing CDP entirely, but automated syncs still go through CDP and
get flagged. After a manual VNC warm-up, the next headless sync
re-trips detection because the automation signals come back.

**Notes:** The `puppeteer-extra-plugin-stealth/evasions/` directory
in upstream is the source-of-truth list. Cherry-pick the ones that
matter for our target banks (Spanish + similar). Most are <50 LOC
each. Test against a fingerprint-detection page like
[bot.sannysoft.com](https://bot.sannysoft.com/) to verify each
patch lands.

### Audit the freentonic Chrome wrapper situation

**What:** Verify that on a clean rebuild of the freentonic image,
`/usr/lib/chromium/chromium` exists at that path on every distro/arch
combo we ship for, and that `LINUX_CHROME_PATHS` in
`lib/freentonic/chrome_cdp.rb` finds it BEFORE the Debian wrapper at
`/usr/bin/chromium`. Also: check whether other distros (Alpine, etc.)
have similar wrapper pollution.

**Why:** The Debian wrapper script injects fingerprintable Chrome
flags (`--load-extension=`, `--media-router=0`, etc.) that we don't
want. We currently bypass it by listing the unwrapped path first, but
this is implicit — a future Dockerfile change to a different distro
or chromium package could regress silently and re-introduce the bot
signals.

### Confirm whether `actual-server` verifies the SimpleFIN cert chain

**What:** Read `actualbudget/actual-server`'s `app-simplefin` request
code (specifically how it builds the `https.request` options) and
confirm whether it passes `rejectUnauthorized: false` anywhere.
Record the answer in `docs/development.md` so future devs know
whether the `NODE_EXTRA_CA_CERTS` trust step is required or
optional.

**Why:** The dev guide currently says "try without trust setup
first; if it fails, apply the env var." That's a soft punt — the
ground truth is in their source and a five-minute read settles it
for everyone.

**Notes:** No code change in this repo; just a docs update once
known.

---

## Deferred / non-goals

### Durable scheduler / persistent job queue

**Why:** see "In-memory scheduler queue" under locked decisions. The
self-host use case tolerates re-trigger on restart; durable queueing
is complexity without payoff at this scale.

### Multi-tenant / multi-admin

**Why:** see "Single-admin, single-tenant" under locked decisions.
Out of scope for a self-host bridge.

### Bundling SimpleFIN formatter into freentonic

**Why:** cross-listed for visibility; full reasoning under "freentonic
stays canonical-only" above.

### Live-freentonic integration tests in this repo

**Why:** every test in this repo stubs `Net::HTTP.new`. End-to-end
tests with a live freentonic and real Chrome belong in the
`freentonic-providers` repo's e2e suite, where the workflows being
exercised actually live.

**Pointer:** [`AGENTS.md` § Invariants #5](../AGENTS.md).
