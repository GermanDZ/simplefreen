# AGENTS.md — simplefreen

Instructions for autonomous coding agents (Claude Code, Cursor, Aider,
etc.) working in this repository. Humans: start with
[`README.md`](README.md) and
[`docs/architecture.md`](docs/architecture.md).

Simplefreen is a sibling project to
[freentonic](https://github.com/GermanDZ/freentonic). Together they
form a two-service SimpleFIN bridge for Actual Budget:

- **Freentonic** scrapes banks via headed Chrome.
- **Simplefreen** (this project) manages profiles, stores credentials,
  schedules syncs, and speaks SimpleFIN to Actual.

Simplefreen calls freentonic's `/invoke` over HTTP and receives scraped
data back through freentonic's `http` exporter.

## Invariants — non-negotiable

1. **Zero runtime gem dependencies.** `simplefreen.gemspec` has no
   `add_dependency` lines. Dev-only gems (minitest, rake, base64) go
   in the `:development, :test` Gemfile group. Mirrors freentonic's
   same invariant.
2. **Credentials are never logged, never argv, never plaintext on
   disk.** The `ProfileStore` writes AES-256-GCM ciphertext keyed by
   the master key + a per-profile PBKDF2 subkey. Scheduler decrypts
   just long enough to hand to freentonic as inline credentials in
   the `/invoke` body.
3. **Push tokens are single-use and scoped per run_id.** The mint-
   table lives in memory (`PushTokens`). The `/push/<run_id>` handler
   rejects unknown / expired / run-mismatched bearers.
4. **`YAML.safe_load(permitted_classes: [], aliases: false)`** is the
   only YAML parser used — specifically in
   `AdminApi#declared_secrets`, which reads the workflow YAML's
   `secrets:` block. No other YAML parse paths.
5. **Tests run without network and without freentonic.** Every test
   stubs `Net::HTTP.new` via the `with_net_http_new` helper in
   `test/test_helper.rb`. Do not introduce a live-freentonic
   integration test here — that belongs in the freentonic-providers
   repo's end-to-end suite.
6. **Profile keys are charset-validated** (`[A-Za-z0-9_.-]{1,128}`)
   and a short reserved-list (`claim`, `accounts`, `admin`, etc.)
   is enforced at create time to foreclose URL ambiguity.

## Architecture map

| Subsystem | Files | Role |
| --------- | ----- | ---- |
| Stores (disk) | `lib/simplefreen/{profile_store,state_store,cache_store,claim_store,run_log,atomic_file,paths}.rb` | AES-GCM + flock-guarded JSON files. |
| Crypto | `lib/simplefreen/crypto.rb` | AES-256-GCM + PBKDF2 + constant-time compare. |
| Reshape | `lib/simplefreen/reshape.rb` | Freentonic normalized → SimpleFIN wire envelope. |
| HTTP transport | `lib/simplefreen/{server,http}.rb` | stdlib TCPServer + response helpers. |
| Router / protocol | `lib/simplefreen/{router,protocol}.rb` | `/simplefin/*` + dispatching. |
| Admin | `lib/simplefreen/{admin_api,admin_ui}.rb` + `ui/` | Operator surface. |
| Scheduler | `lib/simplefreen/scheduler.rb` | Single worker thread; serializes outbound `/invoke` calls. |
| Freentonic client | `lib/simplefreen/freentonic_client.rb` | Net::HTTP wrapper for `/invoke`. |
| Health probe | `lib/simplefreen/freentonic_health.rb` | Background `/healthz` poller; scheduler gates on it. |
| Push receiver | `lib/simplefreen/{push_receiver,push_tokens}.rb` | Accepts freentonic's http-exporter callback. |
| Feature | `lib/simplefreen/feature.rb` | Wires everything; env-driven config. |

## Common tasks

### Add a new admin API route

1. Add a route in `AdminApi#dispatch` (the big `case` block). Match on
   `pathname` + `method`. Delegate to a private handler.
2. Handler goes through the same validation dance: bearer check
   (already enforced by the outer dispatch), path-param charset
   validation, JSON body parse via `parse_json(request)`.
3. Every response shape goes through `Http.write_json(client,
   status, hash)`. 4xx responses use `bad_request(client, msg)`,
   `unauthorized(client)`, `not_found(client)`, `method_not_allowed(client)`.
4. Add a test in `test/protocol_test.rb` or a dedicated file.

### Add a field to profile records

1. `ProfileStore#create` — add the kwarg with a sensible default.
   Validate through a `coerce_*` private method.
2. `ProfileStore#update` block — allow the field in the update path.
3. `AdminApi#profile_summary` — surface it in the status response
   the UI polls.
4. `AdminApi#handle_create` + `#handle_profile` (PATCH branch) — accept
   the new field from the request body.
5. If it feeds into the sync body, wire through `Scheduler#build_invoke_body`.
6. Update the UI form in `lib/simplefreen/ui/index.html` + `app.js`.
7. Stores test and protocol test should both pick up the new field.

### Change the push-token handshake

The per-run bearer handshake is security-critical. Don't change
`PushTokens` or the token threading through the `/invoke` body without:

- Rereading `docs/architecture.md` — the handshake is documented there.
- Preserving the invariants: one-shot consume, TTL-bounded, scoped
  per run_id, no plaintext ever persisted.
- Adding a regression test in `test/push_tokens_test.rb` + a
  receiver-level test in `test/push_receiver_test.rb`.

## Safety rails — never do

- Never add a runtime gem. Dev-only gems are fine.
- Never introduce `YAML.load` or loosen `permitted_classes`.
- Never write a bank credential (or a decrypted one) to a log line,
  a file outside `ProfileStore`, or an exception message.
- Never concatenate user-controlled values into a shell command or a
  Ruby `eval` / `const_get` chain.
- Never break the `Paths::FILENAME_PATTERN` validation — it's the
  single defense against path traversal in filename components.
- Never call freentonic's `/invoke` without a one-shot push token.
  Hard-coded tokens in tests are fine; hard-coded in prod code is a
  security bug.

## When to stop and ask

- The proposed change would require a runtime gem.
- The change requires modifying freentonic's core contract (new
  request field, different exporter shape). Coordinate with the
  freentonic repo; changes that flow across the two-service boundary
  need a review there first.
- Migration question: would existing on-disk state
  (`/data/profiles/*.json`, `/data/cache/*/latest.json`) still be
  readable? If not, propose a migration path before merging.

## Completion criteria

- [ ] `bundle exec rake test` green.
- [ ] No runtime dependency added.
- [ ] SECURITY.md updated if the change touches any invariant here.
- [ ] README.md / docs updated for new operator-visible features.
- [ ] CHANGELOG.md updated under `[Unreleased]` for any operator-
      visible change.
- [ ] docs/roadmap.md updated if the change closes a "Next up" item
      or alters a locked decision.
- [ ] PR summary describes how it changes the contract with freentonic,
      if at all.
