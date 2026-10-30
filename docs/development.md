# Development guide

How to set up a local dev stack for simplefreen, iterate on it, and
exercise it against a real Actual Budget instance — using the same
HTTPS shape as production.

For the architectural background see [architecture.md](architecture.md);
for the production deployment recipe see
[operator-guide.md § Production deployment](operator-guide.md#production-deployment);
for contribution invariants and completion criteria see
[../AGENTS.md](../AGENTS.md).

## What you get

```
┌──────────────────┐                          ┌──────────────────┐
│  Your browser /  │  https://simplefreen.    │      Caddy       │
│  Actual instance │  localhost:443           │  (TLS sidecar,   │
│                  │ ───────────────────────▶ │  internal CA)    │
└──────────────────┘                          └────────┬─────────┘
                                                       │
                                  reverse_proxy        │
                                  simplefreen:7878     ▼
                                              ┌──────────────────┐
                                              │   simplefreen    │
                                              │  (this project)  │
                                              └────────┬─────────┘
                                                       │ POST /invoke
                                                       │ POST /push/<id>
                                                       ▼
                                              ┌──────────────────┐
                                              │    freentonic    │
                                              │  (pure scraper)  │
                                              └──────────────────┘
```

Three containers on a shared Docker network. Caddy is the only public
surface — it terminates TLS and reverse-proxies to simplefreen.
simplefreen → freentonic and freentonic → simplefreen calls stay on
the internal network in plain HTTP (they never leave the Docker
bridge so they don't need to traverse Caddy).

## Prerequisites

- Docker 20.10+.
- Sibling clones of [`freentonic`](https://github.com/GermanDZ/freentonic)
  and (optionally) `freentonic-providers` for workflow YAMLs.
- A self-hosted Actual Budget server somewhere reachable. Can be on
  the same host (a separate compose stack) or another machine.
- Optional: Ruby 3.2 if you want to run the test suite outside Docker.

## 1. Build the images

```sh
cd ~/code/freentonic
docker build -t freentonic:latest .

cd ~/code/simplefreen
docker build -f docker/Dockerfile -t simplefreen:latest .
```

## 2. Mint secrets (one-time)

```sh
mkdir -p ~/.secrets
ruby -rsecurerandom -rbase64 \
  -e 'puts Base64.strict_encode64(SecureRandom.random_bytes(32))' \
  > ~/.secrets/simplefreen.master-key
ruby -rsecurerandom -e 'puts SecureRandom.base64(24)' \
  > ~/.secrets/simplefreen.admin-password
openssl rand -hex 32 > ~/.secrets/freentonic.invoke-token
chmod 600 ~/.secrets/*
```

## 3. Bring up the dev stack

```sh
mkdir -p ~/simplefreen-dev
cp examples/docker-compose.yml ~/simplefreen-dev/
cp examples/Caddyfile          ~/simplefreen-dev/
cd ~/simplefreen-dev

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
in the compose file — you don't need to set it in `.env` for the dev
stack.

Verify everything is up:

```sh
docker compose ps                                # all three Up
curl -k https://simplefreen.localhost/healthz    # 200 + JSON
```

`-k` skips cert verification. To validate against Caddy's actual CA
(no `-k`), see the trust step below.

## 4. Trust the local cert (one-time per machine)

Caddy mints its cert from a local CA whose root lives at
`/data/caddy/pki/authorities/local/root.crt` inside the caddy
container. Extract it and install it where it matters:

```sh
docker compose cp \
  caddy:/data/caddy/pki/authorities/local/root.crt \
  caddy-root.crt
```

### Browser / OS trust store

**macOS:**

```sh
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain caddy-root.crt
```

**Linux (Debian/Ubuntu):**

```sh
sudo cp caddy-root.crt /usr/local/share/ca-certificates/caddy-root.crt
sudo update-ca-certificates
```

Restart your browser. `https://simplefreen.localhost` should now load
without warnings, and `curl https://simplefreen.localhost/healthz`
(no `-k`) should succeed.

### Your Actual Budget instance

Stock `actualbudget/actual-server` runs Node, which honors the
`NODE_EXTRA_CA_CERTS` env var to extend its CA bundle. Bind-mount the
same `caddy-root.crt` into Actual's container and point the env var
at it:

```yaml
# In your actual-server compose:
my_actual:
  image: actualbudget/actual-server:latest
  environment:
    NODE_EXTRA_CA_CERTS: /etc/ssl/caddy-root.crt
  volumes:
    - ./caddy-root.crt:/etc/ssl/caddy-root.crt:ro
    # ... your normal data volume
```

If both stacks run on the same host, Actual reaches Caddy via
`https://simplefreen.localhost` (the host's loopback resolution).
If on different hosts, swap the hostname for one that resolves to
the Caddy box and add it to the Caddyfile site block.

> **Open question — please record what you find.** Whether stock
> `actualbudget/actual-server` actually rejects untrusted certs in its
> SimpleFIN request path is empirical. Try the claim flow without the
> trust-store mount first; if it fails with a TLS error, apply the
> `NODE_EXTRA_CA_CERTS` step and update this guide with the answer.

## 5. Provision a profile and link Actual

Open the admin UI at **https://simplefreen.localhost/admin/** and sign
in with your `SIMPLEFREEN_ADMIN_PASSWORD`. Then follow
[operator-guide.md § 5–6](operator-guide.md#5-provision-a-bank-profile)
for the full walk-through (new profile → credentials → setup token →
paste into Actual's "Link bank account with SimpleFIN").

The setup token Actual receives now embeds an `https://...` claim URL,
so the stock sync-server image works without any patching.

## 6. Iteration loop

Tail logs:

```sh
docker compose logs -f simplefreen
docker compose logs -f freentonic
docker compose logs -f caddy
```

Rebuild and restart simplefreen after a code change:

```sh
cd ~/code/simplefreen
docker build -f docker/Dockerfile -t simplefreen:latest .
cd ~/simplefreen-dev
docker compose up -d --force-recreate simplefreen
```

State (`profiles/`, `cache/`, `state/`) lives in
`$SIMPLEFREEN_DIR` and survives container recreate. To start clean:
`docker compose down && rm -rf ~/simplefreen-data` (this destroys
encrypted credentials — re-enter from the admin UI on next start).

## 7. Running tests

The test suite is network-free (every test stubs `Net::HTTP.new`).
Run on the host without bringing up Docker:

```sh
bundle install
bundle exec rake test
```

End-to-end tests against a live freentonic / real Chrome belong in
the `freentonic-providers` repo's e2e suite, not here. See
[../AGENTS.md § Invariants #5](../AGENTS.md).

## 8. Filing changes

Before opening a PR, walk through the
[../AGENTS.md § Completion criteria](../AGENTS.md) checklist:

- `bundle exec rake test` green.
- No runtime gem dependency added.
- `SECURITY.md` / `README.md` / docs updated where relevant.
- `CHANGELOG.md` updated under `[Unreleased]` for any operator-
  visible change.
- `docs/roadmap.md` updated if the change closes a "Next up" item or
  alters a locked decision.
- PR summary calls out any change to the contract with freentonic.

## Troubleshooting

| Symptom | Likely cause | Fix |
| ------- | ------------ | --- |
| Browser warns "Not Secure" / cert error | Caddy root not trusted by OS | Step 4 above. |
| Actual: "TLS handshake failed" / "self-signed cert" | Actual's container doesn't trust Caddy's CA | `NODE_EXTRA_CA_CERTS` step in §4. |
| `simplefreen.localhost` doesn't resolve | OS / browser doesn't honor RFC 6761 (rare) | Add `127.0.0.1 simplefreen.localhost` to `/etc/hosts`. |
| `docker compose up` fails to bind 443 | Another process owns 443 | Stop it, or change the Caddyfile + compose to a high port (e.g. `8443`) and use `https://simplefreen.localhost:8443` everywhere. |
| `/healthz` returns 502 from Caddy | simplefreen container not up yet, or crashed | `docker compose logs simplefreen`. |
| `freentonic` state goes `degraded` in `/healthz` JSON | freentonic container not reachable on `http://freentonic:7878` | Check freentonic logs; verify `FREENTONIC_INVOKE_TOKEN` matches both sides. The dev compose probes every 20s (`SIMPLEFREEN_FREENTONIC_HEALTH_INTERVAL_SECONDS`), so recovery after `docker compose up -d freentonic` takes seconds, not minutes. |
| Workflow dropdown is empty in the admin UI | workflow YAMLs not mounted into simplefreen, or `FREENTONIC_WORKFLOWS_DIR` points at an empty dir | Set `FREENTONIC_WORKFLOWS_DIR=/path/to/freentonic-providers` in `.env`; both simplefreen and freentonic mount the same directory (simplefreen at `/workflows:ro`, freentonic at `/home/freentonic/workflows:ro`). The dropdown lists `<slug>/workflow.yml` files only. Or click **↻ Refresh workflows** in the admin UI to pull from GitHub. |
| Bank shows "Por razones técnicas no podemos atenderte" / "We can't serve you right now" / similar generic block | Some combination of (a) IP reputation flagged after rapid testing from same address, (b) Chrome fingerprint signals (WebGL missing, UA-CH leaking Linux, automation flags), (c) cookies / device-trust on the bank side identifying the session as bot. | Triage in this order: **1.** Click **Clear session** and **Browse** — the browse-mode launch already strips most fingerprint signals. **2.** Open `bot.sannysoft.com` inside the noVNC viewer to see which fingerprint tests fail; address what's red. **3.** If fingerprint looks clean and the bank still blocks: change IP (mobile hotspot or router reset for a fresh ISP-assigned address). **4.** Wait — IP reputation flags typically expire in hours-to-days. **5.** If `finanzas-web` (or another freentonic consumer) works against the same bank concurrently, the issue is almost certainly IP/cookies, not fingerprint. |
