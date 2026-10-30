# Balance history — design

Status: design sketch, no code yet. Open for feedback before implementation.

## Goal

Simplefreen sees every bank balance the configured providers publish, but
today it only re-serves the latest one — each sync overwrites the previous
snapshot in the canonical envelope. The bank-side history is therefore
ephemeral from the consumer's perspective: if Sure (or any downstream
client) misses a sync window, the gap is unrecoverable.

This document proposes that simplefreen retain a per-account balance
**series** derived from the existing canonical run archive, and expose it
through a dedicated endpoint. SimpleFIN's wire format stays untouched;
clients that don't care about history keep working unchanged.

The motivating use case is symmetric with the Sure import bug fixed in
[we-promise/sure#1724](https://github.com/we-promise/sure/pull/1724):
historical balance rows must have a restore path. With simplefreen as the
upstream source of truth for balances, we can offer that restore path
without depending on the bank API ever supporting it.

## Non-goals

- Reconstructing balance history from transactions (we have the bank's
  reported balance — that's the authoritative number).
- Supporting clients that mutate balances (read-only, always).
- Inferring inter-day balances on weekends/holidays when the bank reports
  none. We store what providers gave us; consumers interpolate if they
  want to.
- Changing the shape of the standard SimpleFIN `/accounts` response.

## Data model

### What we already have

Every successful sync writes a canonical envelope to
`runs/<profile>/<run_id>.canonical.json` (`Paths.run_canonical_path`,
`paths.rb:85`). That envelope contains, per account, a single `balance`
plus a `balance.timestamp`. The full series for an account is therefore
*already derivable* from the runs directory — what's missing is an index
and a query path.

### New index: `balances/`

Per profile, store a compact append-only index at:

```
state/<profile>/balances/<account_id>.ndjson
```

Each row:

```json
{
  "date":        "2026-05-12",
  "amount":      "1234.56",
  "currency":    "EUR",
  "observed_at": "2026-05-12T07:14:03Z",
  "run_id":      "20260512T071403Z-ab12cd"
}
```

Key choices:

- **NDJSON, not JSON array**: append-only writes are atomic at the OS level
  for small lines, no rewrite of the whole file per sync. Matches the rest
  of simplefreen's "small append-friendly state files" idiom.
- **Per account, not per profile**: bounds file size, lets retention
  policies and rebuild jobs scale per account, and keeps unrelated
  accounts uncoupled if one needs surgical repair.
- **Logical key `(account_id, date, currency)`**: matches the
  Sure-PR-#1724 idempotency key. `amount` is *not* part of the key —
  same-day restatements update the existing row.
- **`run_id` recorded**: lets us reconstruct any row from the canonical
  archive and audit how it came to exist. Cheap insurance.
- **Amounts as strings**: same convention as SimpleFIN; avoids float
  drift.

### Path additions

In `Paths`:

```ruby
def balances_dir(root_dir = root)
  File.join(state_dir(root_dir), "balances")
end

def balance_history_path(profile_key, account_id, root_dir = root)
  validate_component!(profile_key, "profile_key")
  validate_component!(account_id, "account_id")
  File.join(state_dir(root_dir), profile_key, "balances", "#{account_id}.ndjson")
end
```

Note `account_id` is already a `Paths::FILENAME_PATTERN`-safe value
elsewhere in the codebase — the existing validator suffices.

## Write path

A new `BalanceHistoryStore.record_run!(profile_key, canonical_envelope)`
is called from the run-completion path that already writes the canonical
file (push_receiver.rb's commit step). For each account in the envelope:

1. Extract `(account_id, balance_date, currency, amount)`. If
   `balance_date` is absent, fall back to the run's `observed_at` date.
2. Read the tail of `<account_id>.ndjson` (last ~32 rows is enough — the
   key is naturally clustered by date). Find any existing row with the
   same `(date, currency)`.
3. Decide:
   - **No match** → append.
   - **Match, same `amount`** → no-op (idempotent re-sync, exactly the
     Sure-PR-#1724 property).
   - **Match, different `amount`** → bank restated. Rewrite the row in
     place (read full file, replace one line, atomic write via
     `AtomicFile`). Log at WARN with both old and new values so an
     operator can investigate.

Writes are best-effort: a failure here must not block the run from being
recorded. The canonical envelope is the source of truth; the index is
recoverable via rebuild.

## Read path

### New endpoint

Per profile (auth: existing access URL):

```
GET /accounts/<account_id>/balances
  ?start-date=<unix>
  &end-date=<unix>
```

Mirrors the date-window conventions of SimpleFIN's `/accounts` query so
clients can reuse their existing parsing. Response shape:

```json
{
  "account": "<account_id>",
  "balances": [
    { "date": "2026-05-10", "amount": "1230.00", "currency": "EUR" },
    { "date": "2026-05-11", "amount": "1240.00", "currency": "EUR" },
    { "date": "2026-05-12", "amount": "1234.56", "currency": "EUR" }
  ]
}
```

Ordered by date ascending. `observed_at` and `run_id` are intentionally
**not** in the response — they're internal audit fields; consumers care
about the bank's reported value, not how simplefreen learned it. (We can
add an `?include=audit` flag later if a real use case appears.)

Returning the data fresh from the index keeps the endpoint O(rows
returned). No caching layer needed for v1.

### Consolidated profile

The virtual consolidated profile (see `virtual-profile-design.md`)
serves the *primary* source's history per linked account, respecting the
same per-source date windows already used for transactions. Concretely:
for a given consolidation group with sources `[fintonic ≤ 2024-12-31,
ing ≥ 2025-01-01]`, the merged balance series is the union of each
source's series clipped to its window, with ties resolved in favor of
the source that owns the date range. This is the same logic as
`Consolidation#resolve_windows` — we just apply it to the balance index
instead of transactions.

### Standard `/accounts` is unchanged

The existing endpoint keeps returning a single `balance` /
`balance-date`. We are not extending it with a `balance-history` field
right now: it would either bloat every `/accounts` response or require a
new query parameter, and the dedicated endpoint is cleaner. Revisit only
if a real consumer asks.

## Rebuild

A rake task (or `bin/simplefreen` subcommand):

```
bin/simplefreen balance-history rebuild --profile=<key>
```

Walks `runs/<profile>/*.canonical.json` in chronological order, replays
the write path against an empty `balances/` directory. Idempotent;
operators can run it after any suspected corruption or after enabling
the feature on an existing install.

On first deploy of this feature on an existing install, document running
the rebuild once so operators recover whatever history the canonical
archive happens to contain. We do not auto-run on boot — surprise I/O on
upgrade is a footgun.

## Retention

Default: **unlimited**. The data is tiny (one row per account per sync,
text-NDJSON; a year of daily syncs is ~25 KB per account).

Add an optional per-profile setting:

```json
{ "balance_history_retention_days": 1825 }
```

When set, the write path trims any rows older than the cutoff after a
successful append. Trimming runs at most once per sync per account
(cheap; we already have the file open).

Note this is a separate axis from the existing run-canonical retention,
which can stay short — the balance index is the long-lived view.

## Edge cases

- **Missing `balance-date`**: use the run's observed timestamp date.
  Logged once per occurrence to spot misbehaving providers.
- **Multiple syncs same day, same amount**: idempotent no-op.
- **Multiple syncs same day, different amount**: latest wins. Common
  case: morning + evening sync, intraday movements.
- **Currency change for an account**: treated as a new series (rows are
  keyed by currency). Effectively two parallel histories. Rare; not
  worth special UI in v1.
- **Account disappears from provider**: the index file is left in
  place. Pruning is an operator decision, not automatic — we don't want
  to lose history because a bank had a flaky day.
- **Account re-keyed by provider**: outside the scope of this design;
  the existing cross-source linking layer (`Consolidation`) is the
  right place to address identity drift.

## Tradeoffs and risks

- **Stateful surface**: simplefreen stops being a stateless proxy for
  this slice. We accept the same retention/encryption-at-rest
  expectations that already apply to `state/` (root-owned, 0o700, no
  network exposure beyond the authed endpoints).
- **Bank restatements are silent today**: the proposed WARN log on
  amount changes is the first time we'd surface them. Operators may see
  unexpected noise — that's a feature, not a bug, but worth flagging.
- **Derived index can drift from canonical**: mitigated by the rebuild
  path. The canonical archive remains authoritative; the index is a
  performance/query convenience.
- **Doesn't help if simplefreen wasn't installed yet**: history starts
  the day this code ships (or the day rebuild is run against existing
  canonical files). We can't manufacture pre-existing balances.

## Implementation slices

1. **Storage + write path** — `BalanceHistoryStore`, paths, integration
   into the run-commit hook. Tests for the three idempotency cases.
2. **Read endpoint** — per-profile `GET /accounts/:id/balances`,
   protocol parsing, date filtering.
3. **Rebuild command** — walk canonical runs, emit index. CLI.
4. **Consolidated read** — apply per-source window logic to the index.
5. **Retention setting** — optional; ship only when an operator asks.

Slice 1 + 3 are usable on their own (rebuild produces a queryable file
on disk even before the endpoint exists). Slice 2 is the smallest
externally-visible deliverable. Slice 4 depends on consolidation tests
already passing.
