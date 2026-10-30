# Accepting the freentonic Canonical Data Model

## Why this doc exists

simplefreen is a **clean-slate project** — there are no deployed users
with historical cached data to preserve. freentonic v0.4.0 (and the
matching freentonic-providers release) ships the **canonical data
model** as the wire shape every provider produces. The current
`lib/simplefreen/reshape.rb` was written against the pre-canonical
shape. We can replace the push endpoint's input contract cleanly —
no adapter layer, no legacy-compat branch, no dedup-key-continuity
workaround. Just rewrite Reshape to consume canonical directly.

## Authoritative references (read first)

All paths below are absolute on the dev machine that houses these
sibling repos. Read in this order:

1. **Spec** — `~/code/freentonic/docs/canonical-data-model.md`
   The model itself: envelope, entities, types, IDs, summary, wire format.
2. **Formatters** — `~/code/freentonic/docs/formatters.md`
   How wire shapes derive from canonical. The `canonical` formatter is
   the HTTP exporter's default — that's what simplefreen will receive.
3. **CHANGELOG** — `~/code/freentonic/CHANGELOG.md`
   v0.2 / v0.3 / v0.4 entries trace every addition.
4. **Worked canonical payload** — run this once in a freentonic
   checkout to get a representative envelope on disk to test against:
   ```sh
   cd ~/code/freentonic
   bin/freentonic invoke examples/example_bank.yml \
     --from-raw examples/raw.example.json \
     --export json --export-path /tmp/canonical.json
   ```

## What the wire looks like

```json
{
  "schema_version": "0.1",
  "summary": { "counts": {...}, "amounts_by_currency": {...},
               "balances_by_currency": {...}, "date_range": {...},
               "generated_at": "2026-04-23T10:05:12Z" },
  "meta": { "scraper_version": "ing/0.2", "freentonic_run_id": "..." },
  "accounts": [
    {
      "id":          "acc_a1b2c3d4e5f60718",
      "source_id":   "abc-123",
      "institution": "ing",
      "name":        "Cuenta Naranja",
      "type":        "checking",
      "currency":    "EUR",
      "iban":        "ES...",
      "balance":     { "current": "1500.20", "available": "1450.00",
                       "timestamp": "2026-04-23T10:00:00Z" },
      "metadata":    { ... provider-specific + legacy_* compat keys ... }
    }
  ],
  "transactions": [
    {
      "id":              "txn_4a5b6c7d8e9f0a1b",
      "source_id":       "mv-uuid",
      "account_id":      "acc_a1b2c3d4e5f60718",
      "date":            "2026-04-20",
      "value_date":      "2026-04-21",
      "amount":          "-45.20",
      "currency":        "EUR",
      "description":     "Amazon",
      "raw_description": "AMZN Mktp ES*XYZ",
      "status":          "posted",
      "merchant":        { "name": "Amazon", "normalized": true },
      "category":        null,
      "metadata":        { ... }
    }
  ],
  "liabilities": [],
  "investments": []
}
```

Key properties of the canonical shape (relative to simplefreen's
existing Reshape input):

- **Money is already a decimal string** (`"-45.20"`). SimpleFIN wants
  decimal strings too — no more `cents_to_decimal` round-trip.
- **Transaction IDs are deterministic and stable** (`txn_<16 hex>`).
  SimpleFIN wants stable tx IDs for Actual's dedup — perfect fit; no
  more `stable_tx_id` fallback hashing.
- **Account IDs are deterministic and stable** (`acc_<16 hex>`). Same
  story.
- **Balance is a sub-object** with `current`, `available`, `timestamp`
  — parallel to SimpleFIN's `balance` + `balance-date` +
  `available-balance`.
- **Transactions live in a top-level slot** keyed to accounts via
  `account_id` FK. Group them by account when building the SimpleFIN
  envelope.
- **Status semantics**: `"posted"` / `"pending"` / `nil`. SimpleFIN's
  `pending: true` maps from `status == "pending"`.

## What changes in simplefreen

### `lib/simplefreen/reshape.rb` — rewrite

Three structural shifts to the current implementation:

1. **Input shape assumption** — the top-of-file comment block + the
   input iteration shift from "nested `accounts[].movements[]` with
   `_cents` integers" to "top-level `accounts[]` + `transactions[]`
   with JSON-string decimals".

2. **Money handling simplifies** — today's `cents_to_decimal(value)`
   (lines ~248-263) is no longer needed; canonical `amount` /
   `balance.current` are already decimal strings. You keep a small
   normalization step (strip whitespace, handle `nil`) but lose the
   integer-arithmetic branch entirely. `available_balance` follows
   the same simplification.

3. **Transaction assembly** — `reshape_account` no longer pulls
   `account["movements"]` directly; instead it receives a `by_account`
   hash of `{canonical_account_id => [canonical_transactions]}` that
   `Reshape.call` builds once per envelope.

Rough pseudocode for the new `Reshape.call`:

```ruby
def self.call(canonical)
  envelope = { "accounts" => [], "errors" => [] }
  return envelope unless canonical.is_a?(Hash)

  # Group transactions by account_id once up front.
  txs_by_account = Array(canonical["transactions"]).group_by { |t| t["account_id"] }

  Array(canonical["accounts"]).each do |account|
    txs = txs_by_account[account["id"]] || []
    reshape_account(account, txs, envelope)
  end
  envelope
end
```

And the new `reshape_account`:

```ruby
def self.reshape_account(account, transactions, envelope)
  id = account["id"]
  unless id.is_a?(String) && id.start_with?("acc_")
    envelope["errors"] << "simplefin: account missing canonical id"
    return
  end

  currency = account["currency"].to_s
  unless currency.match?(/\A[A-Z]{3}\z/)
    envelope["errors"] << "simplefin: account #{id} missing ISO 4217 currency"
    return
  end

  balance = account.dig("balance", "current")
  unless balance.is_a?(String) && !balance.empty?
    envelope["errors"] << "simplefin: account #{id} missing balance"
    return
  end

  balance_date = to_unix(account.dig("balance", "timestamp")) || Time.now.to_i

  account_hash = {
    "id"           => id,
    "name"         => account["name"] || id,
    "currency"     => currency,
    "balance"      => balance,
    "balance-date" => balance_date,
    "org"          => org_from(account),
    "transactions" => transactions.map { |tx| reshape_transaction(tx) }.compact,
    "extra"        => {}
  }

  if (avail = account.dig("balance", "available")) && avail != balance
    account_hash["available-balance"] = avail
  end

  envelope["accounts"] << account_hash
end
```

And `reshape_transaction`:

```ruby
def self.reshape_transaction(tx)
  id = tx["id"]
  return nil unless id.is_a?(String) && id.start_with?("txn_")
  return nil unless tx["amount"].is_a?(String)

  is_pending = tx["status"] == "pending"
  posted = is_pending ? 0 : (to_unix(tx["date"]) || 0)

  out = {
    "id"          => id,
    "posted"      => posted,
    "amount"      => tx["amount"],
    "description" => (tx["description"] || tx["raw_description"] || "").to_s
  }

  if (transacted = to_unix(tx["value_date"] || tx["date"]))
    out["transacted_at"] = transacted
  end

  out["pending"] = true if is_pending

  if (payee = tx.dig("merchant", "name")) && !payee.to_s.empty?
    out["extra"] = { "payee" => payee.to_s }
  end

  out
end
```

**Net effect**: Reshape shrinks from ~295 lines to maybe ~180 lines.
The eliminated code is mostly the `cents_to_decimal` arithmetic,
the `stable_tx_id` fallback hashing, the legacy-field-fallback
chains (`account["movements"] || account["transactions"]`,
`movement["amount"] || movement["amount_cents"]`, etc.), and the
now-unneeded bank metadata fallbacks.

### `lib/simplefreen/push_receiver.rb` — no branching, just validate

No `schema_version`-based branching needed. Add a minimal validation
that the envelope looks canonical before handing to Reshape:

```ruby
def dispatch(client, method, path, request)
  # ... existing token / run_id validation ...

  payload = JSON.parse(body)
  unless canonical_payload?(payload)
    return Http.json_response(422, {
      "ok" => false,
      "error" => "expected canonical envelope with schema_version, got something else"
    })
  end

  envelope = Reshape.call(payload)
  # ... existing CacheStore write, state transition ...
end

private

def canonical_payload?(payload)
  payload.is_a?(Hash) && payload["schema_version"].is_a?(String)
end
```

The validation is cheap defense — if the freentonic container ever
gets rolled back to a pre-v0.4 build that doesn't emit
`schema_version`, simplefreen surfaces the error immediately instead
of silently producing a broken SimpleFIN envelope.

### `test/reshape_test.rb` — rewrite fixtures

The existing Reshape tests use legacy-shape fixtures (`source_tag`,
`balance_cents`, nested movements, etc.). Replace with canonical
fixtures. Reuse the worked payload from the "Authoritative references"
section as a starting point.

Good test matrix to cover:

- Multi-account canonical envelope → SimpleFIN envelope with two
  accounts, each with their transactions grouped correctly.
- Account with no transactions → empty `transactions: []` on the
  SimpleFIN side.
- Orphan transaction (`account_id` not in envelope's accounts slot)
  → logged/skipped or dropped silently. Pick a policy and test it.
- Account missing balance → surfaced in `envelope["errors"]`, not
  silently accepted.
- Non-ISO currency → same error surfacing.
- Pending transaction (`status: "pending"`) → `pending: true`,
  `posted: 0`.
- `balance.available == balance.current` → omit `available-balance`
  (SimpleFIN spec requirement).
- `balance.available != balance.current` → emit `available-balance`.
- Money passthrough: canonical `"-45.20"` → SimpleFIN `"-45.20"` as
  a raw string (no parse-and-reformat round-trip).
- Non-canonical payload (missing `schema_version`) → PushReceiver
  returns 422.

### `docs/canonical-data-model.md` — replace with a pointer

simplefreen's existing `docs/canonical-data-model.md` is a stale copy
of an early draft of the spec (Draft v0.1 without the shipped
additions: money-as-string, deterministic prefixed IDs,
`schema_version`, `source_id` first-class, `summary` block,
`legacy_*` metadata). Keeping it around risks drift — reviewers
reading simplefreen's copy will assume it's authoritative.

Delete it and replace with a stub pointing at the authoritative copy:

```markdown
# Canonical Data Model

simplefreen consumes the freentonic canonical data model. The
authoritative spec lives in the freentonic repo:

- `~/code/freentonic/docs/canonical-data-model.md`
  — spec (envelope, entities, types, IDs, summary, wire format)
- `~/code/freentonic/docs/formatters.md`
  — formatter contract + how wire shapes derive from canonical

For simplefreen's consumer-side migration plan, see
[freentonic-canonical-migration.md](freentonic-canonical-migration.md).
```

## Why canonical maps more cleanly to SimpleFIN than the legacy shape

Worth noting, because it means Reshape genuinely shrinks — not just
shifts complexity:

| SimpleFIN field  | Canonical source                    | Legacy shape source (current)     | Work done            |
| ---------------- | ----------------------------------- | --------------------------------- | -------------------- |
| account.id       | `account.id` (acc_<hex>)            | `account.external_id`             | 1:1 string passthrough |
| account.balance  | `account.balance.current` (string)  | `account.balance_cents` (integer) | canonical is already string; legacy needed cents_to_decimal |
| account.balance-date | `account.balance.timestamp`     | `account.balance_at`              | ISO → unix conversion either way |
| account.currency | `account.currency`                  | same                              | 1:1 |
| account.org.name | derived from `account.institution`  | `account.bank_name`               | canonical has less metadata; lookup table needed |
| tx.id            | `transaction.id` (txn_<hex>)        | `movement.dedup_key`              | 1:1 string passthrough; canonical is stronger (SHA-256) |
| tx.amount        | `transaction.amount` (string)       | `movement.amount_cents` (integer) | canonical is already string |
| tx.posted        | `transaction.date` → unix           | `movement.date` → unix            | same |
| tx.pending       | `transaction.status == "pending"`   | `movement.pending_status == "pending"` | 1:1 boolean |
| tx.description   | `transaction.description` or `raw_description` | `movement.description`   | 1:1 |
| tx.extra.payee   | `transaction.merchant.name`         | `movement.payee`                  | 1:1 with nil-check |

The two columns where legacy was easier: **org metadata** (canonical
dropped `bank_name` / `bank_key` / `bank_domain` / `bank_url` as
first-class fields; only `institution` survives as a lowercase slug)
and **full-movement raw_payload** (canonical puts raw provider-specific
data in `transaction.metadata` as a nested sub-hash, which Reshape
doesn't need to consume — SimpleFIN doesn't want it).

The org metadata gap was filled by the `INSTITUTION_METADATA` lookup
table in `lib/simplefreen/reshape.rb` (`ing` / `revolut` / `fintonic`
/ `unicaja` today; extend as new institutions land).

## Non-goal: pushing SimpleFIN knowledge into freentonic

It is tempting to suggest that freentonic ship a `Formatters::SimpleFIN`
upstream — simplefreen would then ask for `--export-format simplefin`,
freentonic would POST SimpleFIN directly to `/push/<run_id>`, and
Reshape would vanish from this repo. **Don't do this.** The boundary
is decided:

- **freentonic always emits the canonical model.** It is a pure
  scraper. It knows about banks, browsers, and the canonical data
  model — nothing else. Wire formats for downstream consumers are not
  its problem.
- **simplefreen always receives canonical and converts to SimpleFIN
  here.** Owning the canonical → SimpleFIN translation is part of
  simplefreen's job description: it is the SimpleFIN-speaking service.

Reasoning, so the next session doesn't re-litigate this:

1. **freentonic's job is "produce canonical."** The moment it knows a
   consumer's wire format it owns N protocols instead of one model.
   The next consumer (a YNAB bridge, a Plaid-shaped emulator, a CSV
   job) would either inherit the same special-case treatment or live
   as a second-class citizen. Canonical exists precisely so consumers
   can fan out without freentonic caring.
2. **Versioning independence.** SimpleFIN-spec drift (pending
   semantics, new balance fields, whatever Actual changes next)
   becomes a simplefreen-only patch. With the formatter living in
   freentonic, every SimpleFIN tweak would force a coordinated
   freentonic release + simplefreen pin bump for a change that has
   nothing to do with scraping.
3. **Reshape is small.** Post-canonical-migration it is ~180 lines of
   pure-function transformation with a flat test surface, sitting
   next to the protocol code that consumes its output. That is the
   right place for it.

The one real trade-off: if a *second* SimpleFIN-emulating service ever
consumes freentonic, Reshape would be duplicated. That is hypothetical
and cheap to fix the day it happens (extract a small
`freentonic-simplefin` gem then). Not worth pre-paying for.

## Open questions

All four open questions (institution metadata, orphan transactions,
`value_date`, `category`) were resolved in commit `31d11d0`. See
`lib/simplefreen/reshape.rb` for the implementations and
[`roadmap.md`](roadmap.md) for the current decision log.

## TL;DR for the next session picking this up

_(historical — migration completed in `31d11d0`)_

1. Delete `docs/canonical-data-model.md` (stale draft). Replace with
   a stub pointing at
   `~/code/freentonic/docs/canonical-data-model.md`.
2. Rewrite `lib/simplefreen/reshape.rb` to consume the canonical
   envelope directly. ~180 lines, half of today's size. Most of the
   legacy boilerplate (cents arithmetic, stable_tx_id hashing,
   field-fallback chains) goes away.
3. Add a `canonical_payload?` guard to `lib/simplefreen/push_receiver.rb`;
   return 422 if missing `schema_version`.
4. Rewrite `test/reshape_test.rb` fixtures + assertions against the
   canonical shape. Copy the worked payload from running
   `bin/freentonic invoke examples/example_bank.yml --from-raw
   examples/raw.example.json --export json ...` in a freentonic
   checkout.
5. Build an `INSTITUTION_METADATA` lookup table for Actual-facing
   org presentation (Open Question #1, option b).
6. No cache migration needed (clean-slate project; no deployed users).
