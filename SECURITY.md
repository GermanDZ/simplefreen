# Security

## Threat model

Simplefreen stores bank credentials — the highest-value data a
self-hosted personal-finance tool holds. An attacker with those
credentials can log into banks, initiate transfers in some regions,
harvest transaction history for identity theft, and pivot to
other accounts that share the bank as an authenticator.

Simplefreen is designed to be deployed on a self-hosted box behind
the operator's own network perimeter, alongside a separate freentonic
container that does the bank scraping. The split means a compromise
of the scraper (Chrome exploit, crafted bank-page JS, CDP escape) does
NOT automatically yield the credential vault — an attacker would need
to additionally breach the simplefreen container or its state dir.

## Invariants

These are the rules the framework guarantees to every deployment. If
your change breaks one, it is a security bug and should not merge.

1. **Credentials encrypted at rest.** Every secret in a profile is
   stored as AES-256-GCM ciphertext under a per-profile subkey derived
   via PBKDF2-HMAC-SHA256 from `SIMPLEFREEN_SECRETS_KEY` + a fresh
   salt. See `ProfileStore#write_credentials`.
2. **Master key stays in env.** `SIMPLEFREEN_SECRETS_KEY` is read once
   at startup. It must never be logged, echoed, or persisted on disk.
3. **Admin auth is bearer-token (REST) or cookie (browser UI).** Both
   resolve to the same `SIMPLEFREEN_ADMIN_PASSWORD`. Compare is
   constant-time via `OpenSSL.fixed_length_secure_compare`
   (`Crypto.secure_compare`). The browser session cookie is
   `HttpOnly; Secure; SameSite=Strict`. Cookie-authenticated mutations
   additionally require a same-origin `Origin`/`Referer` (`Router#same_origin?`)
   so a sibling `*.example.com` page can't CSRF the admin API;
   bearer clients are exempt (the token can't be forged). The login
   endpoint locks out for `LOGIN_LOCKOUT_SEC` after `LOGIN_MAX_FAILURES`
   failures in a window (`AdminUi#login_locked?`) to blunt online guessing.
4. **Push tokens are single-use, per-run, TTL-bounded.** The
   emulator → freentonic → emulator handshake uses a fresh 32-byte
   URL-safe token for each sync. The mint-table stores SHA-256
   hashes (not plaintext). `PushTokens#consume` deletes the entry
   immediately on a valid match. `PushTokens#valid?` performs the same
   check without consuming; the server uses it only to pick a body-size
   cap, and the receiver still consumes before accepting a payload.
5. **Access URLs hash their passwords with PBKDF2-HMAC-SHA256**
   (600k iterations, 16-byte salt). Verification is constant-time.
6. **No plaintext credentials on argv.** When passing to freentonic
   they go in the `credentials.inline` key of the `/invoke` body (a
   JSON object over HTTPS to a trusted endpoint) — never on
   `FREENTONIC_URL` query strings, never in log lines.
7. **YAML parsing is `YAML.safe_load(permitted_classes: [], aliases: false)`**.
   The only use site is `AdminApi#declared_secrets`. No second code
   path exists.
8. **Path traversal is foreclosed by `Paths::FILENAME_PATTERN`**.
   Every filename component that originates outside the server —
   profile keys, claim IDs, run IDs — is matched against
   `[A-Za-z0-9_.-]{1,128}` before being joined into a path.
9. **Reserved profile keys** (`claim`, `accounts`, `admin`, `api`,
   `p`, `status`, `healthz`, `invoke`, `runs`, `profiles`) are rejected
   at create time to foreclose URL routing ambiguity.
10. **Request bodies are capped before auth.** Every request body is
    buffered before any auth check runs, so the server caps it at 1 MiB
    (`Server::MAX_PREAUTH_BODY_BYTES`). Only a `POST /push/<run_id>`
    whose bearer is a live push token for that run gets the large cap
    (`SIMPLEFREEN_MAX_BODY_MB`, default 64). `Server#body_limit_for`
    decides from headers alone, before any body bytes are read.
11. **The noVNC password travels in the URL fragment** (`vnc.html#…
    password=…`). Browsers never send the fragment to a server, so the
    password stays out of proxy access logs and `Referer` headers.

## What an operator must protect

- `SIMPLEFREEN_SECRETS_KEY` — if this leaks, every encrypted bank
  credential on disk can be decrypted. Store in a real secrets
  manager. Rotate by re-uploading credentials through the admin UI
  while the new key is active (see `docs/operator-guide.md`).
- `SIMPLEFREEN_ADMIN_PASSWORD` — full admin access to the emulator.
  If it leaks, an attacker can exfiltrate access URLs, trigger syncs,
  and delete profiles. They can NOT directly read credentials (those
  are encrypted-at-rest; the admin API never surfaces them).
- `FREENTONIC_INVOKE_TOKEN` — if it leaks, an attacker who can reach
  the freentonic HTTP port can invoke arbitrary workflows, potentially
  with crafted credentials. Keep the freentonic listener bound to
  loopback or a private Docker network.
- The state dir (`/data` in the container; usually bind-mounted from
  the host). Contains the encrypted credentials. Protect filesystem
  permissions (0700 on the dir; 0600 on every file AtomicFile writes).

## Transport: HTTPS is required by the SimpleFIN spec

The [SimpleFIN protocol](https://www.simplefin.org/protocol.html)
mandates TLS on every hop:

> Only makes requests to SSL/TLS URLs. (...) Clients must verify all
> SSL/TLS certificates when making HTTPS requests.

Simplefreen's built-in HTTP server speaks plain HTTP (no TLS
termination in-process, by design — matches freentonic's shape). In
production, put it behind a TLS-terminating reverse proxy and set
`SIMPLEFREEN_PUBLIC_URL` to the `https://…` URL the proxy serves.
Setup tokens and access URLs embed this URL, so the scheme propagates
to every SimpleFIN client interaction.

The `examples/docker-compose.yml` and the quickstart in the operator
guide both set up a plain-HTTP deployment that's appropriate only
for a laptop / private LAN / wire-it-up-for-yourself setup. Before
putting real bank credentials in front of the open internet, work
through `docs/operator-guide.md#production-deployment`.

## Reporting vulnerabilities

Please report security issues privately via
github.com/GermanDZ/simplefreen/security/advisories/new — do not
open a public issue. Coordinated-disclosure timeline is 30 days unless
the vulnerability is being actively exploited.
