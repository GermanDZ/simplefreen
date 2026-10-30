# Operator guide — running simplefreen

End-to-end deployment guide: build the images, bring up both
containers, provision a profile, link to Actual Budget.

For the architectural background (the push-token handshake, state
machine, on-disk layout) see [architecture.md](architecture.md).

> **Dev-mode vs. production — read this before going live.** The
> walk-through below stands simplefreen up on `https://simplefreen.localhost`
> with a self-signed cert minted by Caddy's local CA. That is enough
> for stock `actualbudget/actual-server` to talk to it (with the CA
> root bind-mounted into Actual's container — see
> [development.md](development.md)) and matches the production HTTPS
> shape, but the cert is not in any public trust store and the
> hostname is `*.localhost`. Acceptable on a laptop / private LAN /
> Tailscale; unacceptable on the open internet.
>
> Before pointing a production Actual Budget server at simplefreen,
> read [Production deployment](#production-deployment) at the end of
> this guide and put the service behind a TLS-terminating reverse
> proxy with a publicly-trusted certificate (Let's Encrypt, your CA,
> etc.).
>
> For the developer-perspective walk-through (iteration loop, trust-
> store setup, troubleshooting), see [development.md](development.md).
> The walk-through below is the operator-perspective version of the
> same dev stack.

## 1. Prerequisites

- Docker 20.10+.
- Clones of both repos: `freentonic` and `simplefreen`.
- Workflow YAMLs — the `freentonic-providers` repo or your own, mounted
  into the freentonic container at `/home/freentonic/workflows`.
- A self-hosted Actual Budget server (the sync-server, not just the
  desktop app).

## 2. Generate secrets

Three secrets are minted once and stored in a secrets manager:

```sh
ruby -rsecurerandom -rbase64 \
  -e 'puts Base64.strict_encode64(SecureRandom.random_bytes(32))' \
  > ~/.secrets/simplefreen.master-key

ruby -rsecurerandom -e 'puts SecureRandom.base64(24)' \
  > ~/.secrets/simplefreen.admin-password

openssl rand -hex 32 > ~/.secrets/freentonic.invoke-token

chmod 600 ~/.secrets/*
```

**`SIMPLEFREEN_SECRETS_KEY` is catastrophic if lost** (every encrypted
bank credential is unrecoverable) or leaked (every encrypted credential
is decryptable). Keep it in a real secrets manager — 1Password, Bitwarden,
AWS Secrets Manager, `pass`, whatever your team uses.

## 3. Build the images

```sh
# Freentonic — bank scraper, unchanged.
cd ~/code/freentonic
docker build -t freentonic:latest .

# Simplefreen — this repo.
cd ~/code/simplefreen
docker build -f docker/Dockerfile -t simplefreen:latest .
```

## 4. Launch the containers

The provided `examples/docker-compose.yml` brings up freentonic,
simplefreen, and a Caddy TLS sidecar on a shared network. Copy it
plus the Caddyfile to your deployment dir:

```sh
cp examples/docker-compose.yml ~/freentonic-stack/docker-compose.yml
cp examples/Caddyfile          ~/freentonic-stack/Caddyfile
cd ~/freentonic-stack
cat > .env <<EOF
SIMPLEFREEN_SECRETS_KEY=$(cat ~/.secrets/simplefreen.master-key)
SIMPLEFREEN_ADMIN_PASSWORD=$(cat ~/.secrets/simplefreen.admin-password)
FREENTONIC_INVOKE_TOKEN=$(cat ~/.secrets/freentonic.invoke-token)
FREENTONIC_WORKFLOWS_DIR=$HOME/freentonic-workflows
FREENTONIC_RUNS_DIR=$HOME/freentonic-runs
SIMPLEFREEN_DIR=$HOME/simplefreen-data
EOF
chmod 600 .env

docker compose up -d
```

`SIMPLEFREEN_PUBLIC_URL` defaults to `https://simplefreen.localhost`
in the compose file, so it does not need to be set in `.env` for the
dev stack.

Verify health:

```sh
curl -s  http://localhost:7878/healthz                 # freentonic
curl -sk https://simplefreen.localhost/healthz         # simplefreen (via Caddy)
```

The `-k` skips cert verification. To verify against Caddy's actual
CA (no `-k`), install the CA root in your OS trust store — see
[development.md § "Trust the local cert"](development.md#4-trust-the-local-cert-one-time-per-machine).

Both should return `{"ok": true, ...}`. Simplefreen's response
includes the last freentonic probe:

```json
{"ok":true,"shutting_down":false,"freentonic":{"state":"active","last_probe_at":"2026-04-22T…"}}
```

## 5. Provision a bank profile

Open the admin UI at **https://simplefreen.localhost/admin/** and sign
in with the admin password. (Until you trust Caddy's root CA — see
[development.md § "Trust the local cert"](development.md#4-trust-the-local-cert-one-time-per-machine)
— your browser will warn about the self-signed cert.)

1. Click **+ New profile**. Pick a workflow from the dropdown, set
   a lookback, save.
2. Click **Credentials** on the new row. Fill in the fields the workflow
   declares (auto-derived from the YAML's `secrets:` block). Save —
   they're AES-256-GCM-encrypted at rest.
3. Click **Setup token**. Copy the long base64 string.

## 6. Link to Actual Budget

In Actual's browser UI:

1. Bank Sync → Add account → **Link bank account with SimpleFIN**.
2. Paste the setup token. Actual's sync-server exchanges it via the
   claim URL embedded in the token → simplefreen returns an access URL.
3. Click **Link bank account with SimpleFIN** again. Actual calls
   `/simplefin/<key>/accounts` on simplefreen. Simplefreen sees the
   profile has no cache yet, returns `{accounts: [], errors: ["First
   sync scheduled."]}` and enqueues a sync.
4. Simplefreen's scheduler calls freentonic's `/invoke`, which runs
   the workflow. Freentonic's `http` exporter POSTs the normalized
   payload to `simplefreen/push/<run_id>` with the one-shot token.
5. The push receiver writes the cache, flips state to `ready`.
6. Click **Link bank account with SimpleFIN** a third time. The
   cache is served, Actual's modal shows the accounts, you select
   them, done.

On subsequent syncs Actual's sync-server caches the access URL and
just hits `/simplefin/<key>/accounts` directly — the claim flow runs
exactly once per profile.

## 7. Re-authentication (MFA, expired sessions)

When a bank's session expires, the sync fails. If the workflow has an
`error_signals` entry with `kind: reauth`, freentonic exits with code
3 and simplefreen transitions the profile to **needs_reauth**. The
admin UI shows an orange pill and a **Re-authenticate (VNC)** button.

Clicking that button:

1. Mints a one-shot VNC password.
2. Calls freentonic's `/invoke` with `chrome.headless = false` and
   `vnc_password = <password>`.
3. The admin UI shows a banner with the VNC password + a noVNC link.
4. You connect to freentonic's noVNC (http://localhost:17080 with the
   one-shot password) and complete the login by hand.
5. Chrome device-trust is persisted in freentonic's volume so
   subsequent headless syncs work again.

Workflows without `kind: reauth` annotations land in the generic
`error` state instead — you can still trigger a headed sync from the
admin UI's ⋯ menu, just less automatic.

## 8. Scheduled auto-sync

Optional per-profile `sync_interval_seconds` (minimum 300 s / 5 min)
causes simplefreen's ticker thread to enqueue a fresh scrape that
often. Pre-warms the cache so Actual's Sync click returns data
immediately instead of the two-click "scheduled → retry" dance.

## 8b. Alerting (watchdog → ntfy)

The bridge's failure modes are quiet: a bank session can expire, a
scraper can silently start returning nothing, or the scheduler worker
can die — and every pull surface (Actual's Sync, the state files) keeps
looking fine while data stops advancing. The **watchdog** turns those
into a push notification on your phone.

Set one env var to enable it:

```
SIMPLEFREEN_NTFY_URL=https://ntfy.sh/simplefreen-alerts-<random-suffix>
# optional, for a protected topic or a self-hosted ntfy behind auth:
SIMPLEFREEN_NTFY_TOKEN=tk_...
```

Pick a long, unguessable topic suffix — anyone who knows a public
ntfy.sh topic can read its messages. Subscribe to the same topic in the
ntfy mobile app (or self-host ntfy). Leave `SIMPLEFREEN_NTFY_URL` unset
and the watchdog thread never starts — no alerts, no overhead.

What it alerts on (every ~5 min, edge-triggered):

- a profile enters `needs_reauth` (bank kicked us out) or `error`
- a profile goes **stale** — configured to auto-sync but its last
  *successful* sync is older than `max(2× sync_interval, 24h)`
- the scheduler worker thread has died (wedges all future syncs)
- a low-priority **recovered** note when any of the above clears

It's edge-triggered with a daily re-reminder: you get one alert when a
problem appears (or changes type), then silence until it clears or 24h
passes — a chronically broken profile pings once a day, not every tick.
The dedup state lives in `$SIMPLEFREEN_DIR/watchdog.json`, so a restart
or deploy doesn't re-spam you about problems you already know about.

Tuning (both optional):

```
SIMPLEFREEN_WATCHDOG_INTERVAL_SECONDS=300    # how often it checks
SIMPLEFREEN_WATCHDOG_RENOTIFY_SECONDS=86400  # re-reminder cadence for an ongoing problem
```

The same staleness signal is also exposed for pull-based monitoring:
`GET /healthz` now includes a `stale_profiles` count (unauthenticated,
does not flip `ok`), and `GET /admin/api/metrics` carries the full
`profiles_stale` / `scheduler_worker_alive` / `history_merge_failures`
breakdown.

## 9. Backup

Back up `$SIMPLEFREEN_DIR` (the bind-mounted state directory) AND
the master key. State dir without the key is unrecoverable; key
without the state dir is just wasted entropy.

Optional: also back up freentonic's `freentonic_chrome_profile` volume
so device-trust persists across disaster recovery.

## Production deployment

Everything above gets a working link between Actual and your banks on
a laptop or home server. Before you point a production deployment at
simplefreen, close these gaps.

### TLS is required by the SimpleFIN spec

The [SimpleFIN protocol spec](https://www.simplefin.org/protocol.html)
is explicit about transport security:

> Only makes requests to SSL/TLS URLs. (...) Clients must verify all
> SSL/TLS certificates when making HTTPS requests.

Three knock-on consequences:

- The **claim URL** embedded in a setup token must use `https://`. Our
  setup-token mint takes its scheme/host from `SIMPLEFREEN_PUBLIC_URL`,
  so set that to an `https://…` URL in prod.
- The **access URL** returned after a claim must use `https://`. Same
  source: it's derived from `SIMPLEFREEN_PUBLIC_URL`.
- Stock `actualbudget/actual-server` enforces HTTPS + port 443 for the
  claim exchange in `app-simplefin.js` (see its `getAccessKey`: hard-
  coded `port: 443` + `https.request`). The dev stack already serves
  HTTPS on port 443 via the Caddy sidecar, so the difference between
  dev and prod is the cert: dev uses Caddy's local CA (trust the root
  manually — see [development.md](development.md)); prod must use a
  publicly-trusted cert.

### Reverse-proxy recipe (Caddy)

The simplest production topology puts simplefreen behind a TLS-
terminating reverse proxy that handles cert issuance. Caddy is
minimal and handles ACME automatically:

```caddy
# /etc/caddy/Caddyfile
simplefreen.example.com {
  # Automatic Let's Encrypt cert. Caddy renews it unattended.
  encode zstd gzip

  # Lock down the admin UI to your management network + hardcoded IPs.
  # Skip this block if you reach the UI over a VPN / Tailscale and
  # simplefreen's port is only bound there.
  @admin path /admin* /admin/*
  handle @admin {
    @allowed remote_ip 10.0.0.0/8 100.64.0.0/10 <your-home-ip>/32
    reverse_proxy @allowed 127.0.0.1:7878
    respond 403
  }

  # The SimpleFIN protocol surface must be publicly reachable —
  # actual-server calls it from wherever Actual Budget is hosted.
  handle_path /simplefin/* {
    reverse_proxy 127.0.0.1:7878
  }

  # Health probe, OK to expose.
  handle /healthz {
    reverse_proxy 127.0.0.1:7878
  }

  # Push receiver: freentonic → simplefreen internal callback. Keep
  # this on the private network; don't expose it through the public
  # hostname at all. Omit this handle entirely from the public vhost.

  # Fall through everything else with 404.
  handle {
    respond 404
  }
}
```

And the compose file drops the host publish for the simplefreen
container (only the proxy needs it):

```yaml
simplefreen:
  # no `ports:` mapping — Caddy reaches it inside the Docker network
  environment:
    SIMPLEFREEN_LISTEN_ADDR: "0.0.0.0"
    SIMPLEFREEN_PUBLIC_URL:  "https://simplefreen.example.com"
    SIMPLEFREEN_INTERNAL_PUSH_URL: "http://simplefreen:7878"
    # … same as dev mode otherwise
```

Nginx / Traefik / an AWS ALB work equally well — the only hard
requirement is that `SIMPLEFREEN_PUBLIC_URL` resolves to a TLS
endpoint with a cert the SimpleFIN client trusts.

### Use stock `actualbudget/actual-server`

Both the dev stack and production should run the stock upstream
image. With a HTTPS endpoint on port 443 (Caddy's internal cert in
dev, a publicly-trusted cert in prod), stock sync-server's
`getAccessKey` works unchanged — no patches required.

```yaml
my_actual_budget:
  image: actualbudget/actual-server:latest
  volumes:
    - ${ACTUAL_DATA_DIR}:/data
```

### Secret hygiene

- **`SIMPLEFREEN_SECRETS_KEY`** is the one key whose compromise is
  catastrophic — every encrypted bank credential on disk becomes
  readable. Mount it as a file with mode `0400` via Docker secrets /
  a real KMS / `systemd-creds` rather than passing it as an env var
  that shows up in `docker inspect` and crash reports. Never commit
  it. Rotation recipe: start a second simplefreen with the new key,
  re-enter credentials through the admin UI while the old still
  runs, swap.
- **`SIMPLEFREEN_ADMIN_PASSWORD`** gates the admin UI + REST API.
  Full admin access lets an attacker exfiltrate access URLs,
  trigger syncs, delete profiles — but *not* read credentials (those
  stay encrypted at rest). Still, treat it like an SSH password.
  Ideally gate `/admin/*` to a VPN / allowlisted IPs at the reverse
  proxy (see Caddy config above).
- **`FREENTONIC_INVOKE_TOKEN`** shared with the freentonic container.
  Anyone with this token + network reach to freentonic can run
  arbitrary workflows against arbitrary credentials. Keep freentonic
  bound to the internal Docker network (`expose: ["7878"]`, not
  `ports:`) and never route it through the public proxy.
- **`SIMPLEFREEN_CORS_ALLOWED_ORIGINS`** should be left empty in
  production. It's the opt-in CORS allow-list, only needed for
  browser-mode Actual dev builds — stock `actual-server` calls
  simplefreen server-to-server and sends no `Origin` header, so CORS
  headers aren't evaluated.

### Verification checklist before going live

- [ ] `SIMPLEFREEN_PUBLIC_URL` is `https://…` and resolves to a real
      cert the client trusts.
- [ ] `curl https://simplefreen.example.com/healthz` returns 200 from
      outside your network.
- [ ] `curl -vk https://simplefreen.example.com/admin/` returns 200
      only from an allowlisted IP and 403 elsewhere.
- [ ] Stock `actualbudget/actual-server` image in use, with the
      production cert in its trust store (or a publicly-trusted CA).
- [ ] The freentonic container is **not** reachable over the public
      proxy — only on the internal Docker network.
- [ ] Secrets live in a secret manager (Docker secrets, `systemd-creds`,
      KMS, ops tooling) — not in a plaintext `.env` checked into git.
- [ ] `$SIMPLEFREEN_DIR` is on a disk whose host filesystem permissions
      are `0700` for the simplefreen uid.
- [ ] Backup job set up for `$SIMPLEFREEN_DIR` + master key.
- [ ] `FREENTONIC_VNC=1` can stay on for re-auth, but the noVNC host
      port (17080 in the example compose) must be bound to a VPN
      interface or allowlisted IPs — noVNC on the public internet is
      a password-protected but unencrypted-by-default surface.

## Deploy with Kamal (behind the edge proxy)

`config/deploy.yml` ships a Kamal v2 config for a single host (an LXC
or small VM works fine), fronted by an off-host edge reverse proxy
(e.g. Caddy) that terminates TLS. Host-specific values are read from the
environment — export `KAMAL_HOST` (the deploy/ssh target) and
`SIMPLEFREEN_HOST` (the public hostname) before running `kamal`, e.g.
from a gitignored `.envrc`. The helper scripts under `bin/`, `ops/` and
`.kamal/hooks/` read the same `KAMAL_HOST`.
Two app containers on the `kamal` Docker network, plus the host-wide
kamal-proxy:

```
LAN/VPN ──► edge proxy (<edge-ip>, TLS for $SIMPLEFREEN_HOST)
              │   (off-host, not part of this repo — see "Edge proxy" below)
              ├──► /novnc/ → <lxc-ip>:17080 → simplefreen-freentonic:6080 (websockify)
              └──► /…      → <lxc-ip>:80 → kamal-proxy → simplefreen-web:7878
                                                              │
                                                              └─► simplefreen-freentonic:7878 (/invoke)
```

- **simplefreen** is built by Kamal from this repo and pushed to ghcr.io.
- **freentonic** is built _from source on the LXC_ during each
  `kamal deploy` — `.kamal/hooks/pre-deploy` shallow-clones the
  freentonic repo, builds the image on the LXC, and pushes it to a
  host-local Docker registry on `127.0.0.1:5000`. Avoids pushing a
  Chrome-laden image over LAN or to public ghcr.io.
- **TLS is terminated off-host by the edge proxy**, e.g. with a
  publicly-trusted Let's Encrypt wildcard via DNS-01. kamal-proxy stays in plain-HTTP mode on `:80`; the edge
  proxies straight to it. There is no local TLS terminator and no
  internal CA for clients to trust.
- **kamal-local-registry** is a `registry:2` container bound to
  `127.0.0.1:5000` for the freentonic image. Started lazily by the
  pre-deploy hook.

### One-time LXC prep

```sh
# On the LXC:
apt update && apt install -y openssh-server git
systemctl enable --now ssh
# (Docker is installed for you by `kamal setup`.)

# Authorize your laptop's ssh key:
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo 'ssh-ed25519 AAAA... your-laptop-key' >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
```

State lives in **named Docker volumes** (`simplefreen_data`,
`simplefreen_workflows`, `simplefreen_runs`,
`simplefreen_freentonic_chrome`). Docker creates them on first deploy and
preserves them across `kamal redeploy`. Nothing to mkdir on the host.

### Volume ownership matrix

Both app containers run as uid `10001` by construction:

- simplefreen's Dockerfile creates the `simplefreen` user at uid
  `10001` (`ARG SIMPLEFREEN_UID=10001`).
- freentonic's Dockerfile takes `ARG FREENTONIC_UID` (default `10001`);
  `bin/build-freentonic-image` passes `--build-arg FREENTONIC_UID=10001`
  explicitly when building on the LXC, so the uid is stable across
  rebuilds even if upstream changes the default.

Because the writer and reader of every shared volume use the same uid,
there is no cross-uid permission gap and no per-deploy chown is needed.

| Volume                            | Owner uid | Writer       | Reader       |
| --------------------------------- | --------: | ------------ | ------------ |
| `simplefreen_data`                |   `10001` | simplefreen  | simplefreen  |
| `simplefreen_workflows`           |   `10001` | simplefreen  | freentonic   |
| `simplefreen_runs`                |   `10001` | freentonic   | simplefreen  |
| `simplefreen_freentonic_chrome`   |   `10001` | freentonic   | freentonic   |

Fresh deploys: nothing to do — Docker creates the named volumes empty
and each Dockerfile pre-creates the mount point with the right
ownership at build time (`chown -R simplefreen:simplefreen /data …` in
simplefreen, `chown -R freentonic:freentonic /workspace …` in
freentonic), so the first-attach inheritance lands at uid `10001`.

Upgrading an older deploy that booted with freentonic at the legacy
uid `997`? Do this one-time migration after pulling the new images
and before the next deploy:

```sh
ssh root@<LXC-IP> bash <<'EOF'
for v in simplefreen_runs simplefreen_freentonic_chrome; do
  docker run --rm -v "$v":/v alpine chown -R 10001:10001 /v
done
EOF
```

This is config-migration glue, not a per-deploy step — once both
containers are on matching uids, ownership stays correct.

### Hostname + DNS

`SIMPLEFREEN_PUBLIC_URL` is `https://$SIMPLEFREEN_HOST`. A convenient
pattern is a name that is publicly resolvable (so DNS-01 certs work) but
only reachable on the LAN/VPN: your LAN resolver rewrites it to the
edge proxy, which terminates TLS and proxies to kamal-proxy on the
host. Clients (browsers, the Actual Budget container) then just resolve
the name normally. The edge vhost and `SIMPLEFREEN_PUBLIC_URL` must
agree on the hostname.

### Edge proxy

The edge only terminates TLS and passes `Host` through to kamal-proxy
over plain HTTP. noVNC goes straight to freentonic's published host port
(freentonic is a Kamal accessory, so kamal-proxy can't route to it). A
Caddy example:

```caddyfile
simplefreen.example.com {
  # noVNC re-auth surface — a LIVE bank-login browser. The path matcher
  # MUST come before the catch-all reverse_proxy below.
  @novnc_ok remote_ip <lan-cidr> <vpn-cidr>
  handle_path /novnc/* {
    handle @novnc_ok {
      reverse_proxy http://<lxc-ip>:17080   # freentonic noVNC
    }
    respond 403
  }

  reverse_proxy http://<lxc-ip>:80          # everything else → kamal-proxy
}
```

- `reverse_proxy` to `http://…:80` forwards the client `Host`, which is
  what kamal-proxy routes on — no `header_up Host` override needed.
- `handle_path /novnc/*` strips the prefix, matching how simplefreen
  builds the URL (`{public_url}/novnc/vnc.html?path=novnc/websockify…`).
  WebSocket upgrades are handled automatically.
- Keep the source-IP allowlist: the noVNC password is the only other
  guard on that surface.

### First deploy

```sh
cd ~/code/simplefreen
cp .kamal/secrets.example .kamal/secrets   # fill in 5 values
kamal setup     # installs Docker + kamal-proxy, builds freentonic on the LXC,
                # boots simplefreen + freentonic
```

`kamal setup` runs the pre-deploy hook, which on top of the freentonic
build also writes `.kamal/proxy/options` on the LXC so kamal-proxy
only publishes `:80` (the edge Caddy owns TLS off-host; the default
`:80 + :443` would needlessly grab `:443`). If you're upgrading an
older deploy that already booted with the default options, run
`kamal proxy reboot` once after `kamal setup` to pick up the new options.

### Trust — nothing to do

The edge Caddy serves a publicly-trusted Let's Encrypt cert for
`*.example.com`, so no client needs a custom CA installed. (If you're
migrating from the old internal-CA setup, you can untrust and delete the
`~/simplefreen-caddy-root.pem` you previously added, and drop any
`NODE_EXTRA_CA_CERTS` you wired into the Actual Budget container.)

### Seeding from your laptop dev tree

If you've been running simplefreen locally via `bin/dev-native`, your
encrypted credentials + profile state live in `dev/data/simplefreen/`
and your Chrome cookies/device-trust live in a Docker named volume
(typically `simplefreen_freentonic_chrome_profile`). Move both onto
the server **after `kamal setup` has created the target volumes**:

```sh
# 1. Data volume: profiles, state, history, cache (~tens of MB).
kamal app stop                  # release the volume
bin/seed-volumes                # dev/data/simplefreen → simplefreen_data
SKIP_FREENTONIC_BUILD=1 kamal deploy  # `kamal app start` won't work with
                                       # uncommitted working tree; deploy is safe
```

```sh
# 2. Chrome profile (~hundreds of MB; saves a re-auth per profile).
#    Confirm which local volume has your real data first:
for v in $(docker volume ls -q | grep freentonic_chrome); do
  echo "== $v =="; docker run --rm -v $v:/v alpine du -sh /v
done

# Pick the heavy one and stream it through ssh:
docker run --rm -v <SRC_VOL>:/v alpine tar -C /v -cf - . | \
  ssh root@<LXC-IP> "docker run --rm -i \
    -v simplefreen_freentonic_chrome:/v alpine sh -c \
    'find /v -mindepth 1 -delete && tar -xf - -C /v && chown -R 10001:10001 /v'"
ssh root@<LXC-IP> docker restart simplefreen-freentonic
```

The seed script refuses to overwrite a non-empty volume unless you
pass `--force`. It scrubs macOS AppleDouble (`._*`) sidecar files
that would otherwise crash simplefreen's JSON parser on boot.

The remaining volumes (`simplefreen_workflows`, `simplefreen_runs`)
don't usually need seeding:

- `simplefreen_workflows` — click "↻ Refresh workflows" in the admin
  UI to pull the latest `freentonic-providers` tarball.
- `simplefreen_runs` — purely historical artifacts.

### Day-to-day commands

```sh
kamal deploy                              # rebuild freentonic + ship simplefreen
SKIP_FREENTONIC_BUILD=1 kamal deploy      # skip the freentonic rebuild

kamal app logs -f                  # tail simplefreen
kamal accessory logs freentonic    # tail freentonic
kamal app exec --interactive bash
```

(TLS/routing logs live on the edge proxy, off-host, not in
`kamal accessory logs`.)

#### Freentonic source selection

`bin/build-freentonic-image` (invoked by `.kamal/hooks/pre-deploy`)
picks the source in this order:

1. `FREENTONIC_SRC=/path/to/checkout` — explicit local path. Synced
   to the LXC with `rsync -a --delete`.
2. `../freentonic` relative to the simplefreen repo — sibling
   checkout. **This is the default** for the typical layout
   (`~/code/simplefreen` + `~/code/freentonic`).
3. `git clone $FREENTONIC_REPO@$FREENTONIC_REF` — fallback for fresh
   hosts without a local checkout. Defaults to
   `https://github.com/GermanDZ/freentonic.git` at `main`.

When building from a local checkout, the image is tagged
`localhost:5000/freentonic:<short-sha>` (or `<short-sha>-dirty` if
your working tree has uncommitted changes), plus `:latest`. The
accessory always pulls `:latest`. No GitHub push is needed to
redeploy — edit freentonic locally and `kamal deploy`.

```sh
# Build from a different local checkout (e.g. a worktree on a branch)
FREENTONIC_SRC=~/code/freentonic-feature-x kamal deploy

# Force the GitHub-clone path even when ../freentonic exists
FREENTONIC_SRC= FREENTONIC_REF=some-branch kamal deploy
```

Backups — `simplefreen_data` is the only volume whose loss is
catastrophic (state + encrypted creds, and the master key in
`.kamal/secrets` is needed to decrypt them). A nightly snapshot on
the LXC:

```sh
docker run --rm -v simplefreen_data:/v:ro -v /backup:/b alpine \
  tar -C /v -czf /b/simplefreen-data-$(date +%F).tar.gz .
```

### Going public later

simplefreen already sits behind a publicly-trusted edge proxy, so the
cert story is solved. Making it reachable from outside the LAN is purely
an edge concern: publish a public A record for the hostname and open
`:443` to the edge proxy (the LXC stays HTTP-only on `:80`, never
exposed). Re-read the "Production deployment" section above first —
admin-UI lockdown becomes mandatory once the host is reachable publicly.
