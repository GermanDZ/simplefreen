# SimpleFIN bridge — architecture, gotchas, and debugging recipes

## Why this doc exists

simplefreen runs as a SimpleFIN bridge between multiple provider
scrapers (freentonic-providers) and one or more SimpleFIN consumers
(e.g. Sure). The bridge has subtle behaviours that turn into outages
or duplicate hell when you don't know them: per-source canonicals,
windowed consolidation, immutable per-run files, multi-layer consumer
caches, charge+refund auto-pairing on the consumer side, and a
provider-side dedup that prevents recurring drift.

This doc captures everything learned across the May 2026 cleanup
sprint. Use it when something looks broken: the first move is
usually identifying which layer is misbehaving, not running scripts.

## High-level data flow

```
┌────────────────────────────────────────────────────────────────┐
│  freentonic provider scrapers (one per bank source)            │
│                                                                │
│  - workflow.yml + extractor.rb + normalizer.rb per source      │
│  - produces a "canonical run payload" per sync                 │
└────────────────────────────────────────────────────────────────┘
                            │
                            ▼  HTTP push to /ingest/<profile>
┌────────────────────────────────────────────────────────────────┐
│  simplefreen bridge                                            │
│                                                                │
│  /data/runs/<source>/*.canonical.json   — per-sync, immutable  │
│  /data/history/<source>/history.json    — durable audit log    │
│  /data/consolidation/groups.json        — per-account routing  │
│                                                                │
│  HistoryStore.merge_run!  — append-by-id, never removes        │
│  Protocol.handle_accounts — single-source SimpleFIN serve      │
│  ConsolidatedReshape.call — virtual profile serve, windowed    │
└────────────────────────────────────────────────────────────────┘
                            │
                            ▼  GET /simplefin/<profile>/accounts
┌────────────────────────────────────────────────────────────────┐
│  Sure (consumer)                                               │
│                                                                │
│  Entry rows keyed by `simplefin_<txn_<hex>>`                   │
│  SimplefinItem.raw_payload                — per-institution    │
│  SimplefinAccount.raw_transactions_payload — per-account       │
│  Transfer model + AutoTransferMatchable    — pairing           │
└────────────────────────────────────────────────────────────────┘
```

## Canonical identity — what `txn_<hex>` actually is

Every transaction emitted by a freentonic provider has a `source_id`
string. The bridge derives the canonical `id` field via:

```
txn_<hex> = canonical_id_hash(account_id, source_id)
```

So canonical identity is **a function of `source_id` stability**.
Provider releases that change the `source_id` scheme change every
downstream `txn_<hex>`. That breaks every consumer entry pointing at
the old ids.

ING's history with this:

- Legacy `/movements`: `source_id` is the `transactionLocalUUID` —
  an encrypted blob that rotates per login session. Same posting,
  different hash every session. Unusable for consumer dedup.
- v2 `/search`: `source_id` is `v2-seq:<productId>:<sequence>` —
  stable per posting. Used since the v2 migration.

Accounts the v2 endpoint cannot reach (ING's cash sub-account,
securities sub-account, Adicional / cancelled credit cards) still
fall back to V1ID-shaped source_ids. Their canonical ids are
inherently unstable; consumer-side dedup for those relies on
heuristics rather than identity.

## Bridge serve paths

### Single-source profile

Request: `GET /simplefin/<source>/accounts`

`Protocol.handle_accounts()` reads `HistoryStore` for that source
and delegates to `Reshape.call()` to convert canonical → SimpleFIN
wire format. Transaction `id` field is passed through unchanged.

### Virtual (consolidated) profile

Request: `GET /simplefin/<virtual-profile>/accounts`

`Protocol.handle_virtual_accounts()` reads each contributing
source's HistoryStore and delegates to `ConsolidatedReshape.call()`
which:

1. Groups bridge accounts by `portable_ref` (e.g. cards on the same
   physical PAN, savings accounts sharing IBAN tail) into a single
   "consolidated account" identified by the first source's
   `acc_<hex>`.
2. For each group, applies the per-source date `windows` from
   `/data/consolidation/groups.json` to filter contributing txns.
3. Within overlap, dedups by `(date, amount, currency,
   normalized_description)` keeping the primary's row plus any
   surplus from secondaries.
4. Emits unchanged `txn_<hex>` ids — there is no synthesis at the
   reshape layer.

**Critical property:** the bridge only serves transactions present
in current `history.json` for some contributing source AND in a
window that covers the date. Per-run files are NEVER directly
served.

## ConsolidatedReshape — the windows mechanism

`/data/consolidation/groups.json` stores per-(member-set)
operator-tunable config:

```jsonc
{
  "version": 1,
  "groups": [
    {
      "members": ["acc_<hex>"],
      "primary": "ING",
      "windows": {
        "ING":              { "from": "2025-01-01", "to": null },
        "<historical_src>": { "from": null,         "to": "2024-12-31" }
      },
      "balance_override": null,
      "updated_at": "..."
    }
  ]
}
```

Defaults: if a source has no window configured, primary takes ALL
dates and secondaries take NONE (primary-only behaviour).

Common pattern: ING (current) from a cutover date forward,
historical source up to the cutover. Both contribute, no overlap,
each posting served by exactly one source.

**Implication for consumer remap tools:** Tools that compare
consumer external_ids against a single source's canonical will
misclassify pre-cutoff entries (which the bridge serves from the
historical source) as remappable to the post-cutoff source. The
remap "succeeds" but the bridge then serves the post-cutoff source's
ids on subsequent syncs, creating new auto-imported duplicates.

The correct comparison is against `expected_by_key`: for each
(account, date, amount), which `txn_<hex>` will the bridge actually
serve? See `ops/reimport/phase_a_bridge.rb` for the canonical
implementation.

## HistoryStore merge semantics — does NOT remove

`HistoryStore.merge_run!` atomically reads `history.json`, applies
a new run via `apply_run`, atomically writes. Key rules:

1. Transactions union by `id`. Posted-status beats pending; ties
   broken by incoming-wins.
2. Accounts/liabilities/investments are **replaced wholesale** from
   the latest run. So account-level metadata reflects the latest
   sync; transaction history accumulates.
3. **Transactions are never removed by a merge.** Once an id is in
   `history.json`, it stays unless something explicitly deletes it
   (admin rebuild, manual ops script, or a `tx_run_index`
   reorganisation that physically prunes).
4. **Cross-fetch renumber promotion (since 2026-05).** The one case
   where a merge rewrites an existing row's *content*. ING re-emits a
   settled transaction under a NEW `transactionSequence` — hence a new
   `id` — when it clears, while the provisional version disappears
   from `/search` (see "ING seq-renumber" under Provider-side dedup).
   `apply_run` recognises this: an incoming *new* id that matches a
   history row which (a) vanished from this run, (b) same signed
   amount, (c) date ±3 days, (d) description prefix-overlap, and is the
   **only** such match, is written **under the provisional's id** — the
   new id is never inserted. The `id` (and therefore the consumer's
   `external_id`) stays stable, so the consumer upserts in place: no
   duplicate, categorization preserved. The superseded
   id/source_id/description is appended to `metadata.superseded`; the
   immutable per-run canonicals remain the full audit. Conservative by
   construction — "vanished this run" spares genuine same-amount twins
   (both live), description-overlap rejects coincidental
   same-amount/different-merchant, and an ambiguous (>1) match is left
   alone. See `SUPERSEDE_DATE_WINDOW` / `SUPERSEDE_MIN_DESC` in
   `history_store.rb` and `history_store_test.rb`.

`rebuild_from_runs!` exists as an admin-triggered endpoint
(`POST /admin/api/profiles/:key/history/rebuild`) that replays every
canonical run file on disk in mtime order. Replaying old runs that
contain phantoms re-introduces those phantoms into canonical — so
do **not** rebuild from runs unless you've also nuked the runs
directory or the runs are known-clean.

Workflow refresh (re-fetching freentonic-providers code from
GitHub) does NOT trigger any rebuild. The refresh updates the code
the next sync uses; existing canonical is untouched.

## Provider-side dedup vs bridge-side cleanup

### ING seq-renumber — the root mechanism

Established by forensics over `/data/runs/ING/*.canonical.json`
(2026-05-27). ING does **not** mark these `pending` — `status` is
`posted` throughout. What changes when a charge clears is the
`transactionSequence`: ING assigns a **provisional** sequence (for
a card, typically ~10 digits) when the charge first appears, then
**renumbers** it to a **permanent** sequence (typically ~9 digits) on
settlement — usually enriching the description (`ACME STORE` →
`ACME STORE <CITY>`, `APPSTORE/BILL` → `APPSTORE/BILL <COUNTRY>`) and
sometimes shifting the date a day or two. The `uuid` embeds the seq, so it changes too — there is **no
stable ING identifier** across the transition, so this can't be fixed
by re-keying.

Two caveats learned the hard way:
- **Seq magnitude is per-product, not a global signal.** Across ING
  accounts final seqs span several orders of magnitude; a clean
  provisional/final split on one card says nothing about another. Don't threshold on seq
  globally.
- **Status is not a usable signal** (always `posted`).

The robust, description- and date-independent signal is
**supersession**: the provisional vanishes from the latest fetch
while a near-twin (same account, |amount|, date±window) remains.

Three layers of protection, in order:

### 1. Provider normalizer (preventive, same-fetch only)

`freentonic-providers/<source>/normalizer.rb`
(`collapse_pre_clearing_dups` for ING). Runs per fetch, before the
push. Collapses terse+enriched rows **only when both appear in the
same `/search` response**. It cannot see a cross-fetch pair — the
provisional committed in run N and the renumbered row arriving in
run N+1 were never in one payload.

### 2. Bridge HistoryStore supersession (preventive, cross-fetch)

The gap above is closed at merge time: `HistoryStore#apply_run`
promotes the confirmed renumber **in place** under the provisional's
id (see "Cross-fetch renumber promotion" in HistoryStore merge
semantics). This is what keeps the consumer from ever receiving the
dup, since the `external_id` stays stable and the consumer upserts.
Same-fetch dups stay layer 1's job; identical-description and
date-shifted cross-fetch renumbers (which layer 3 / Phase B.5 miss)
are caught here.

### 3. Bridge canonical cleanup (reactive, fallback)

`ops/reimport/phase_b5_bridge_dedup.rb` finds same-(account, date,
amount) groups where one canonical description is a strict prefix of
another and drops the shorter. Use it for **dups that predate layer
2**, or to audit. Note its limits: it groups by **exact date** (so a
date-shifted renumber evades it) and only fires on a **description
difference** (an identical-description renumber is filed as a "real
twin" and kept). With layer 2 deployed, new cross-fetch dups
shouldn't accumulate; B.5 is no longer expected to be the steady-state
guarantee.

**Pairing with the consumer.** A reactive bridge-side delete is *not*
enough on its own: the consumer caches the per-account payload
(`SimplefinAccount.raw_transactions_payload`) and never prunes it, so
a deleted row resurrects on the next sync unless its id is **also
scrubbed from that cache** (and the orphan Entry destroyed, its
category moved to the keeper). See the Sure consumer internals below.
A past incident of this kind was cleaned exactly this
way (Phase B.5 on the bridge + entry-delete + cache-scrub on Sure)
before layer 2 was built to prevent recurrence.

## Sure consumer internals

### Caching layers

Sure has TWO JSONB tables that cache SimpleFIN responses between
syncs:

- `simplefin_items.raw_payload` — institution-level snapshot
- `simplefin_accounts.raw_transactions_payload` — per-account
  transaction list. **Stored as a flat JSON array of transaction
  hashes**, NOT a hash wrapper like `{"transactions": [...]}`. A
  defensive scrub must handle both shapes; ours does (since
  2026-05-24).

Both layers are read on every sync and can resurrect deleted Entry
rows for transaction ids the bridge still serves. Anything that
mutates Sure external_ids in bulk must scrub these caches at the
end.

### Charge+refund auto-match

Lives in `Family::AutoTransferMatchable`. Pairs same-account
opposite-sign entries within a date window into a `Transfer` row;
each side's `Transaction` carries a `transfer_id`. UI shows the
pair as a single Transfer line with `+/- AMOUNT`.

Triggered at sync time and via a delayed job after sync settles.
Sometimes one half of a pair arrives in a sync before the other
half exists — auto-match doesn't fire then, but should fire on the
next sync after both are present.

`RejectedTransfer` records pairs the user manually unmatched, so
they don't auto-re-match.

To manually trigger a re-evaluation across the family (in case
auto-match didn't fire):

```bash
# verify method name first
docker exec <sure> grep -n "def auto_match" /rails/app/models/family/auto_transfer_matchable.rb

# then call it
docker exec <sure> bin/rails runner "Family.first.auto_match_transfers!"
```

### Synthetic counterpart entries

For cross-account transfers (e.g. credit-card monthly settlement
from cash account), Sure auto-creates `src=manual` "Synthetic
counterpart for simplefin_txn_<hex>" Entry rows to balance the
ledger. These are NOT bank-side postings — they're internal to
Sure's accounting model.

When diffing Sure entries against bank ground truth (XLS exports
etc.), filter out `src=manual` synthetic counterparts or the diff
will report large bogus "extras" on the consumer side.

### `simplefin_` external_id prefix

Sure stores SimpleFIN-sourced canonical txn ids with a
`simplefin_` prefix on `Entry.external_id`. So a canonical id
`txn_abc123` becomes `simplefin_txn_abc123` in Sure. Remap scripts
must include this prefix when writing new external_ids and strip
it when looking up against bridge canonical_index.

### No auto-delete on feed disappearance

If a transaction disappears from the SimpleFIN feed (e.g. you
deleted it from bridge canonical), Sure does NOT auto-delete its
Entry. This is by design — protects against transient feed
issues. Practical consequence: pair every bridge-side delete with
a targeted consumer-side delete; do not rely on the next sync
to clean up after a canonical purge.

## Cross-source duplication via portable_ref

When you connect the same physical account through two providers
(e.g. live ING for current data + a historical scraper for older
data), both providers emit canonical accounts with the same
`portable_ref` (e.g. `<BANKID>:<LAST4>` for cards, IBAN-suffix for
checking accounts). The bridge collapses them to a single
`acc_<hex>` via `Canonical.account_id`.

This is intentional and useful — it lets a single Sure account
present a unified history. But it requires the consolidation
groups + windows mechanism described above. Without a group
config, both sources contribute their transactions to the same
account, and the consumer sees parallel imports for the same
real-world posting.

If you notice duplicates only on shared accounts (cards) and not
on single-source accounts, check `/data/consolidation/groups.json`
first.

## Common failure modes & debugging recipes

### "Sure entry count jumped by hundreds after sync"

Means one of:

1. Bridge started serving previously-suppressed transactions
   (someone changed window config, added a source, ran a rebuild).
2. Consumer's Sure caches were poisoned with stale ids that the
   bridge still serves, so each sync re-creates them. (Fixed by
   scrubbing both caching layers + re-running Phase C.)
3. Genuine backfill — Sure under-imports historical data over
   multiple syncs and gradually converges. Compare consumer count
   vs bridge `expected_by_key` count; if consumer is below bridge,
   it's backfill.

Distinguish by querying Sure for entries created in the last
N minutes; group by year-month. Backfill is spread across many
historical dates; poisoning typically clusters around recent dates
or a specific window.

### "Two entries on same day, same amount, same description"

If they're on the SAME bridge-mapped account: check whether the
bank actually recorded two postings (some recurring fees are
legitimately twin). The bank XLS export is
ground truth; if the bank shows two rows, keep both.

If they're on different accounts: probably a cross-account
transfer the auto-matcher didn't pair. Run
`Family.first.auto_match_transfers!` (verify method name) to
re-evaluate.

### "Bridge canonical is clean but Sure shows duplicates"

Either:

- Sure's `SimplefinAccount.raw_transactions_payload` (per-account
  cache, **flat array shape**) holds stale txn ids that the bridge
  still serves under different ids. The next sync materialises both
  the cache version and the current bridge version. Scrub by
  setting `raw_transactions_payload` to `nil` on affected
  SimplefinAccount rows and re-sync.
- A previous remap pointed entries at IDs the bridge doesn't
  actually serve (e.g. wrong source's canonical id for a date
  outside that source's window). The bridge then serves the
  *correct* source's id on each sync and Sure creates a new entry
  every time. Re-run Phase A (multi-source aware) and Phase C.

### "Phase A reports `ambiguous` for entries that look fine"

Phase A picks the first match in the serving source as
`expected_by_key`. If a Sure entry already points at a different
valid candidate in the same source (e.g. real-twin postings the
bank recorded twice), it shows up as ambiguous. The override
generator in `ops/reimport/` keeps the current external_id when
it's already in the candidate set; that's the correct treatment
for real-twin Sure entries.

### "Provider workflow refresh didn't take effect"

Check:

```bash
docker exec <bridge> ls -la --time-style=full-iso /workflows/.refresh-meta.json
docker exec <bridge> cat /workflows/.refresh-meta.json
```

The metadata's `commit` field should match the head of the branch
you pointed at. The workflow files at `/workflows/<source>/*` are
what the bridge actually uses; if they're stale, the refresh
didn't run.

## Validation against bank ground truth

Where available, the bank's own portal lets you export movement
files (XLS). Diff those against Sure entries to confirm the bridge
+ consumer pipeline produced a correct view of reality.

Gotchas when diffing:

- Banks may export **value date** (when funds clear) while the
  consumer stores **transaction date** (when posting was created).
  These typically differ by 1 business day for SEPA debits and
  inter-bank transfers, identical for CC charges. Build a ±1 day
  tolerance into the diff or expect a flood of false positives.
- Filter out `src=manual` synthetic counterpart Entry rows on the
  consumer side before counting — they're internal.
- Sign conventions: bridge stores credit-card charges with bank
  sign (negative), Sure stores them with liability convention
  (positive). Compare on `|amount|` to sidestep.
- Sure can be under-imported relative to the bridge (gradual
  backfill). "Missing in Sure" entries from older dates may just
  mean Sure hasn't caught up yet — re-check after a few more
  syncs.

## Date semantics — V1ID era vs v2-seq era

A subtle source of "1-day drift" duplicates is that ING's two
endpoints report *different semantic date fields* for the same
posting:

| Endpoint | Date field returned | Semantic |
| --- | --- | --- |
| `/movements` (V1ID era) | `effectiveDate` | merchant transaction date (when the card was swiped) |
| `/v2/products/transactions/search` (v2-seq era) | `transactionDate` (mapped to `effectiveDate` by the extractor) | bank value date (matches the XLS "F. VALOR" column) |

For typical card postings the value date is **one day later** than
the transaction date. So a posting captured during V1ID-era syncs
sits at date `D`, while the same posting captured by v2-seq sits at
date `D+1`. Both are correct for what they represent; the bridge
canonical was updated to v2-seq semantics when the migration ran,
but Sure's existing entries (synced earlier under V1ID) kept the
old date.

Sure's sync path is upsert-by-external-id and does **not** update
the `date` field on existing entries even when bridge canonical's
date changes. So the drift accumulates: bridge has `D+1`, Sure has
`D`, XLS has `D+1`. Run `phase_h_sure_date_sync_from_bridge.rb` to
realign.

This is NOT a timezone issue — both parsers use date-only formats
(`%d/%m/%Y` or `%Y-%m-%d`) with no time component, so no UTC↔local
conversion happens. The shift is purely semantic.

## Sign convention — Sure vs bank

Sure stores `Entry.amount` with the convention "**+X = outflow /
spending, −X = inflow / receiving**", consistently across asset
(checking) and liability (credit card) accounts. This matches
typical budgeting-app UX ("you spent +29.99 on Amazon"). It is the
**opposite** of the bank statement convention, which uses
"−X for debits, +X for credits."

Example for the same Amazon CC charge:

| Source | Amount stored |
| --- | --- |
| Bank XLS (`IMPORTE (€)` column) | -29.99 |
| Bridge canonical (`transactions[].amount`) | -29.99 |
| Sure (`Entry.amount` on liability account) | +29.99 |
| Sure UI display | "-29,99 €" (UI flips back for display) |

For asset accounts (checking/savings), the same flip applies: bank
XLS shows a payment as `-100.00` (debit); Sure stores
`+100.00`. Sign-flipped means OUTFLOW from the account.

**Practical consequence:** when diffing XLS vs Sure on `amount`,
**always compare absolute values** to sidestep the convention
difference. The `xls/xls_diff_full.rb` script does this by keying
matches on `(date, format("%.2f", amount.abs))`.

## Account-id mapping — Sure ↔ bridge

Sure's `Account.id` is a Sure-internal UUID. The bridge's canonical
uses opaque `acc_<hex>` ids. The join chain:

```
Sure Entry.account_id        ─→  Account
Account.simplefin_account_id ─→  SimplefinAccount
SimplefinAccount.id          (Sure UUID)
SimplefinAccount.account_id  ─→  bridge `acc_<hex>`
```

`Account.simplefin_account_id` is the foreign key. Once you know
the bridge `acc_<hex>` you can look up
`/data/history/<source>/history.json` for transactions on that
account.

**Critical property:** *multiple* `SimplefinAccount` rows can map
to the same Sure `Account.id`. This is the consolidation mechanism:
cards on the same physical PAN, savings accounts on the same IBAN,
etc., are merged into one Sure account but the bridge keeps them
as separate `acc_<hex>`s. So when looking up "bridge entries for
this Sure account", iterate over ALL the bridge acc_ids that map
to it. Observed in practice: one Sure credit-card account mapped to
several different bridge `acc_<hex>`s — multiple ING credit cards
(main + Adicional historical) all consolidating into one Sure CC
account.

## V1ID orphan dispositions

When V1ID-era data is left in Sure after a migration, each entry
falls into one of three categories. `phase_g_sure_v1id_orphan_cleanup.rb`
classifies them:

### 1. Pure dup (delete with category transfer)

The orphan's v2-seq counterpart already exists in Sure for the same
(account, ±3d, |amount|, desc-prefix). Bridge has only the v2-seq
version; the V1ID-era orphan is double-counting.

**Action:** delete the orphan, **transferring** category, merchant,
notes, and `user_modified` flag to the keeper if its corresponding
fields are empty. Phase G never overwrites a non-empty keeper field.

### 2. Truly orphan (leave in place)

No bridge canonical row matches the V1ID orphan at any source,
even with relaxed ±14d and looser desc criteria. Most likely
explanation: the posting belongs to an **Adicional or cancelled CC
sub-card** that ING's v2 `/search` cannot reach (no product UUID
available — see `reference_ing_api_quirks.md`).

**Action:** **keep** the orphan. Deleting would lose real history
the bank does have but the v2 path can't refresh. These entries sit
with V1ID-shaped `bank_movement_id` indefinitely; that's acceptable.

### 3. Loose dup (manual review — don't auto-delete)

Same (acc, |amount|, desc-prefix) but with a date drift >3 days.
Almost always a **distinct posting**, not the V1ID-vs-v2-seq pair.
Examples: a fixed-amount weekly fuel fill or grocery run produces
several same-amount, same-merchant postings a month — all real.

**Action:** **do not auto-delete**. The V1ID-vs-v2-seq pair's
signature is +1d drift on the SAME real posting; >3d drift is
multiple real postings. Phase G uses ±3d as its strict-match window
precisely because of this.

## Bank XLS quirks for diffing

### Multi-row same-key — twin postings are real

The bank XLS can have N rows with identical `(date, amount,
description)` — N distinct real postings whose disambiguator (the
bank's internal `store` line) the XLS doesn't expose. Example: on
a recurring-fee day the bank XLS shows several identical rows of
`Recibo ACME S.L. -100.00` (one per line item). The bridge
canonical surfaces the `store` field in its `description`, so
bridge entries are distinguishable; XLS rows are not.

**Dedup carefully across files.** Within a single XLS export, N
matching-key rows are real twins, not duplicates. Across overlapping
exports (e.g. May 14 + May 24 both contain April rows), use the
older export's rows up to its max date and only fall back to the
newer export for dates AFTER older's max. Never dedup by key alone
across exports — you'll collapse legitimate twins.

`xls/build_xls_dataset.py` implements this partitioned-combine
strategy.

### F. VALOR is the value date — matches v2-seq

The XLS column header reads "F. VALOR" — the value date. This
matches v2-seq's `transactionDate`. ING's online "movement detail"
view shows the operation date (one day earlier for typical card
postings).

### Per-card-number exports

ING's "Tarjeta Crédito" XLS export is per-card-number. To get
Adicional CC charges, export that Adicional's view separately —
the main card's XLS does NOT include Adicional postings. Always
identify the export's source card via row 0 `Número de tarjeta`
before relying on it as ground truth.

There is also an aggregated "Movimientos" view from ING that
shows the same cash + CC postings in a re-formatted style (no
balance/status columns, "Pago en X" descriptions, sign convention
matching Sure's). This view is **not** a new data source — it's
a different rendering of the same underlying transactions.

## Related artifacts

- `ops/reimport/` — the scripts (Phase A bridge + Sure, Phase B,
  Phase B.5, Phase C, Phase F, Phase G, Phase H)
- `ops/reimport/xls/` — XLS dataset builder + triple-diff
- `docs/reimport-runbook.md` — the operational procedure
- `freentonic-providers/<source>/normalizer.rb` — provider-side
  dedup (where applicable)
- `freentonic-providers/<source>/API-NOTES.md` — per-source API
  quirks
- `lib/simplefreen/consolidated_reshape.rb` — windowed merge
  logic
- `lib/simplefreen/history_store.rb` — merge semantics
- `lib/simplefreen/consolidation_groups_store.rb` — groups config
  read/write
