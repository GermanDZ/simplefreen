# Simplefreen

SimpleFIN bridge for [Actual Budget](https://actualbudget.org/) and
other SimpleFIN-compatible clients, backed by
[freentonic](https://github.com/GermanDZ/freentonic) for the actual
bank scraping.

Simplefreen handles:

- Bank profile management (admin UI + REST API).
- Encrypted-at-rest credential storage (AES-256-GCM, per-profile
  subkeys via PBKDF2).
- SimpleFIN wire protocol (setup-token claim exchange + `/accounts`
  endpoint).
- Per-profile scheduling, cache persistence, state machine.
- Re-authentication via headed VNC syncs.

It does **not** drive Chrome or scrape banks directly. For every sync,
simplefreen calls a separate freentonic server over HTTP, asks it to
run a workflow, and receives the normalized payload back through
freentonic's `http` exporter.

Zero runtime gem dependencies — pure Ruby stdlib.

## Architecture

```
┌────────────────────┐     SimpleFIN         ┌────────────────────┐
│   Actual Budget    │ ──────────────────── │     simplefreen    │
│                    │ claim + /accounts     │  (this project)    │
└────────────────────┘                       └──────┬───────┬─────┘
                                                    │       ▲
                            /invoke (POST)          │       │ /push/<run_id>
                            body: creds + export    ▼       │ body: normalized JSON
                                                 ┌──────────────────┐
                                                 │    freentonic    │
                                                 │  (pure scraper)  │
                                                 └──────────────────┘
```

See [docs/architecture.md](docs/architecture.md) for the full push-
token handshake and state machine.

## Quickstart

```sh
git clone https://github.com/GermanDZ/simplefreen
cd simplefreen
docker build -f docker/Dockerfile -t simplefreen:latest .
```

Generate the master secrets:

```sh
ruby -rsecurerandom -rbase64 \
  -e 'puts "SIMPLEFREEN_SECRETS_KEY=" + Base64.strict_encode64(SecureRandom.random_bytes(32))'
ruby -rsecurerandom -e 'puts "SIMPLEFREEN_ADMIN_PASSWORD=" + SecureRandom.base64(24)'
```

A compose file that brings up simplefreen alongside freentonic and a
Caddy TLS sidecar (so the dev stack serves
`https://simplefreen.localhost`) is in `examples/docker-compose.yml`.
For the contributor-facing walk-through (cert trust, iteration loop,
troubleshooting) see [docs/development.md](docs/development.md). The
operator-perspective walk-through is in
[docs/operator-guide.md](docs/operator-guide.md).

> **Production note.** The quickstart and the example compose file
> serve simplefreen at `https://simplefreen.localhost` with a cert
> from Caddy's bundled local CA — fine for a laptop or private LAN,
> but not [SimpleFIN-spec-compliant](https://www.simplefin.org/protocol.html)
> on the open internet (the cert isn't in any public trust store and
> the hostname is `*.localhost`). Before going live read
> [Production deployment](docs/operator-guide.md#production-deployment)
> — short version: swap the local-CA cert for a publicly-trusted one,
> point `SIMPLEFREEN_PUBLIC_URL` at a real hostname, don't publish
> the freentonic container to the internet.

## Required environment variables

| Var | Purpose |
| --- | ------- |
| `SIMPLEFREEN_SECRETS_KEY` | 32-byte base64 master key. Encrypts every bank credential on disk. |
| `SIMPLEFREEN_ADMIN_PASSWORD` | Admin UI + admin API bearer. |
| `SIMPLEFREEN_PUBLIC_URL` | URL Actual will reach. Embedded in setup tokens + access URLs. |
| `FREENTONIC_URL` | Where simplefreen calls `/invoke` (e.g. `http://freentonic:7878`). |
| `FREENTONIC_INVOKE_TOKEN` | Bearer token that protects freentonic's `/invoke`. |

Optional: `SIMPLEFREEN_ROOT` (state dir, default `/data`),
`SIMPLEFREEN_LISTEN_ADDR` / `_PORT` (default `0.0.0.0:7878`),
`SIMPLEFREEN_CORS_ALLOWED_ORIGINS` (comma-separated),
`SIMPLEFREEN_INTERNAL_PUSH_URL` (default: falls back to
`SIMPLEFREEN_PUBLIC_URL`; set if freentonic reaches simplefreen at a
different hostname, e.g. on the same Docker network).

## Development

```sh
bundle install
bundle exec rake test
```

All tests are network-free — no live freentonic, no Chrome. See
[AGENTS.md](AGENTS.md) for the autonomous-agent contribution guide,
[docs/roadmap.md](docs/roadmap.md) for locked architectural decisions
and planned work, and [CHANGELOG.md](CHANGELOG.md) for the release
history.

## License

MIT. See [LICENSE](LICENSE).
