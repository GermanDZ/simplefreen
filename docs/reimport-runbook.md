# Reproducible bridge re-import — runbook

## Why this doc exists

The simplefreen bridge feeds a downstream SimpleFIN consumer (Sure)
that materialises Entry rows keyed by `simplefin_<txn_<hex>>`. When the
bridge's canonical identity for a posting changes — because the
provider migrates from one ID scheme to another, or because a bug
caused stale rows to enter canonical — the consumer's existing entries
become orphans referencing IDs that no longer exist on the bridge.
Naively re-importing creates duplicates: the orphan entry stays, a new
entry appears under the current ID.

This runbook documents the procedure used in May 2026 to migrate ING
from the V1ID identity scheme (an encrypted per-session nonce blob,
unstable across logins) to v2-seq (`v2-seq:<productId>:<sequence>`,
stable across logins and across the pre-/post-clearing lifecycle), and
to clean up the dup-class-2 phantoms that ING's `/search` endpoint
emits during the clearing window. Use it any time the bridge needs to
rebuild canonical for a source whose consumer already holds entries
under the old identity scheme.

## When to run this

Trigger when **any of** these are true:

- Consumer reports duplicates for postings that should be unique
- A provider release changes the `source_id` scheme (and therefore
  `txn_<hex>`) for transactions already in consumer DBs
- Bridge canonical is suspected to contain stale rows that have since
  disappeared from the upstream bank API

Skip when only the consumer's link to a source needs to be re-mapped
(e.g. user switched between credit cards). That's a UI operation, not
a re-import.

## Authoritative references (read first)

1. Bridge architecture overview — `docs/architecture.md`
2. Canonical data model — `docs/canonical-data-model.md`
3. Provider ID stability — `~/code/freentonic-providers/ing/API-NOTES.md`
4. The scripts themselves — `ops/reimport/README.md`

## The problems this procedure solves

### Problem 1 — V1ID → v2-seq migration (one-time per source)

ING's legacy `/movements` endpoint exposes a `transactionLocalUUID`
that is an opaque encrypted blob — the same posting carries a
different value on every login session. Hashed into a `txn_<hex>`,
that produces a new canonical id per session: noisy, unstable, and
impossible to dedup against a consumer DB across reconnects.

The v2 `/v2/products/transactions/search` endpoint exposes a
`transactionId.transactionSequence` integer that is stable per
posting (within ING's pre-/post-clearing lifecycle quirk — see
Problem 2). The provider now emits `v2-seq:<productId>:<sequence>`
as `source_id` whenever it's available, and falls back to V1ID only
on accounts the v2 endpoint cannot reach (specifically: ING's cash
sub-account, securities sub-account, and Adicional / cancelled
credit cards — see the ING API quirks notes).

### Problem 2 — dup-class-2 phantoms (provider-side fix)

ING's `/search` returns the same real posting under **two**
`transactionSequence`s during the pre-/post-clearing transition: once
with a terse pre-clearing description, then again with an enriched
post-clearing description. Each gets a distinct `v2-seq:*` source_id
and hashes to a distinct `txn_<hex>`. Without collapse, every fetch
overlapping that window writes two canonical transactions for one
real posting.

**Current state:** `freentonic-providers/ing/normalizer.rb` collapses
these at the provider level (`collapse_pre_clearing_dups`, since
2026-05-23). Phase B.5 below should report 0 prefix-dups on every
run going forward. If it ever reports nonzero, that is a regression
in the provider — fix upstream rather than re-running B.5 in
production.

### Problem 3 — cross-source consolidation collisions

A single physical account (e.g. a credit card with a stable
`portable_ref` like `<BANKID>:<LAST4>`) can be fetched by multiple
provider sources (e.g. ING direct + a historical scraper). The
canonical Account.id derives from `portable_ref` and is therefore
identical across sources. Both sources contribute transactions to
the same `acc_<hex>`. The bridge's `ConsolidatedReshape` resolves
this by per-source date **windows** stored in
`/data/consolidation/groups.json` — e.g. ING serves from
`2025-01-01` onwards, historical source serves up to `2024-12-31`,
no overlap.

When this routing exists, consumer-side remap tools MUST be
consolidation-aware: they need to know which source actually serves
each (account, date) combination. A single-source remap (only
reading ING canonical, say) will propose remapping pre-cutoff entries
to ING IDs the bridge never serves, breaking those entries on every
subsequent sync. Phase A below reads ALL source canonicals plus the
groups config and outputs an `expected_by_key` index — the
single-source-of-truth target external_id for each
(acc, date, amount) tuple.

### Problem 4 — Sure caching layers that survive remaps

Sure has multiple JSONB caches that hold the SimpleFIN responses
between syncs: `SimplefinItem.raw_payload` (institution-level) and
`SimplefinAccount.raw_transactions_payload` (per-account). The
per-account payload is stored as a **flat array of transaction
hashes**, NOT a hash with a `"transactions"` key (a defensive Phase C
must handle both shapes). Old transaction ids in these caches cause
the next sync to materialise new Entry rows for transactions that
have already been deleted as duplicates, undoing Phase C's work.
Phase C scrubs both layers at the end.

## Procedure

Phases A through D form a single migration. A is read-only and can be
run any time as a state check. B / B.5 / C write data — each takes
`APPLY=1` to commit, defaults to dry-run.

### Phase A — Classify state (multi-source aware)

Bridge side: reads every `/data/history/<source>/history.json`,
loads `/data/consolidation/groups.json`, computes for each
(account, date) tuple which source actually serves that date via
group windows, and writes `expected_by_key` — the canonical
`txn_<hex>` the bridge will serve for each (acc, date, amount).

Sure side: classifies each Entry against the *expected* serving
source for its (account, date), not just one source's canonical.

```bash
# Bridge
docker exec <bridge> ruby /opt/simplefreen/ops/reimport/phase_a_bridge.rb
docker cp <bridge>:/tmp/phase_a_bridge.json /tmp/
docker cp /tmp/phase_a_bridge.json <sure>:/tmp/

# Sure
docker exec <sure> bin/rails runner /opt/simplefreen/ops/reimport/phase_a_sure.rb
```

What to look for in the bridge output:

- **`per_source`** — transaction/account counts per source. Tells
  you which sources contributed to the multi-source view.
- **`expected_by_key entries`** — the count of (acc, date, amount)
  tuples for which the bridge can name a single serving canonical
  `txn_<hex>`. Lower than `v2_seq_by_key buckets` if some buckets
  don't fall inside any source's window.

What to look for in the Sure output:

- **`v2_seq`** — Sure entries whose external_id already points at
  the expected serving-source canonical id. In a clean steady state
  this is every consumer Entry that maps cleanly to bridge state.
- **`v1id_remappable`** — entries with a known expected target but
  a different current external_id. Includes per-source breakdown so
  you can spot if Phase C cycle 1 wrongly remapped pre-cutoff
  entries to the post-cutoff source. Each entry carries
  `serving_source` indicating which source's canonical is the right
  target.
- **`ambiguous`** — entries where the (date, amount) lookup returns
  multiple candidates in the serving source's canonical. Phase C
  auto-pairs them when the group cardinality matches; otherwise it
  requires manual overrides at `/tmp/phase_c_overrides.json`.
- **`historical_no_bridge_link`** — entries with no expected target
  (no source's window covers their date). Usually legitimate
  (pre-bridge-coverage or imports from older systems). Phase C
  leaves them alone.

### Phase B — Wipe V1ID from canonical (one-time per migration)

Only run once, before triggering a fresh resync. After the resync
brings v2-seq data, V1ID rows from previous sessions are dead weight
that just clutters canonical and confuses Phase A counts.

```bash
# dry-run first
docker exec <bridge> ruby /opt/simplefreen/ops/reimport/phase_b_bridge_wipe.rb

# apply
docker exec -e APPLY=1 <bridge> ruby /opt/simplefreen/ops/reimport/phase_b_bridge_wipe.rb
```

Backup written to `<history>.phase-b-bak-<UTC-stamp>`.

### Resync the source

Trigger a sync with maximum lookback via the bridge admin UI. For ING,
the SCA elevation flow lets `/search` reach the full ~600 days; for
other sources, use whatever lookback is supported. Wait for the sync
to complete before continuing.

### Phase B.5 — Diagnostic dedup

```bash
docker exec <bridge> ruby /opt/simplefreen/ops/reimport/phase_b5_bridge_dedup.rb
```

With the provider prefix-collapse in place, this should report
`prefix-dups (terse → delete): 0`. If it doesn't, that is a regression
in the freentonic-providers ING normalizer — open an issue there
before applying the cleanup, because the next sync will just put the
phantoms back.

### Phase C — Remap Sure entries

```bash
# refresh Phase A artifacts post-resync
docker exec <bridge> ruby /opt/simplefreen/ops/reimport/phase_a_bridge.rb
docker cp <bridge>:/tmp/phase_a_bridge.json /tmp/
docker cp /tmp/phase_a_bridge.json <sure>:/tmp/
docker exec <sure> bin/rails runner /opt/simplefreen/ops/reimport/phase_a_sure.rb

# dry-run Phase C; review collision counts and `missing_old` / `drifted` checks
docker exec <sure> bin/rails runner /opt/simplefreen/ops/reimport/phase_c_sure_remap.rb

# apply
docker exec -e APPLY=1 <sure> bin/rails runner /opt/simplefreen/ops/reimport/phase_c_sure_remap.rb
```

Conflict policy reminder (locked into the script): pick the **richer**
entry in any conflict — category > notes > earliest created_at — and
delete the other. Direction-agnostic: the orphan v1id-remappable entry
may be richer than the conflict at the target, or vice versa.

| Situation | Action |
| --- | --- |
| `v1id_remappable`, target external_id free | Rename orphan to new external_id |
| `v1id_remappable`, target occupied, orphan is richer | Rename orphan; DELETE the existing entry at target |
| `v1id_remappable`, target occupied, existing is richer | Keep existing in place (already has the right external_id); DELETE the orphan |
| Two orphans → same target (Sure-side dup ghosts) | Pick richer as winner; rename winner if needed; DELETE the rest |
| Ambiguous group: N Sure entries vs N candidates with identical candidate sets | Pair 1:1 by sorted external_id ↔ sorted candidate id |
| Ambiguous group: anything else | ABORT — requires manual overrides at `/tmp/phase_c_overrides.json` |

> **Historical note (2026-05-23):** Phase C cycle 2 of the ING
> migration deleted ~442 categorized entries because an earlier
> version of the conflict policy interpreted "keep OLD" as
> "keep the v1id_remappable entry regardless of richness". After a
> dup-class-2 re-sync, the orphan v1id-remappable entries were
> newly-created uncategorized phantoms — keeping them and deleting
> the categorized entries was the wrong direction. Restore from
> backup + replay the procedure with the richness-aware policy is
> the recovery path; the policy table above is the post-fix
> behavior.

> **Historical note (2026-05-24):** Phase C cycle 1 (post-restore)
> of the same migration remapped ~141 pre-cutoff entries to the
> wrong source's canonical because Phase A read only one source.
> The next sync served those postings from the actually-routing
> source and created auto-imported duplicates. Fix: Phase A now
> reads all source canonicals + consolidation groups config and
> outputs `expected_by_key` so Phase C remaps to the right source
> regardless of which source the operator is "thinking about".

The DB updates run inside a single `ApplicationRecord.transaction` so
a mid-flight failure rolls back. The snapshot-cache scrub at the
end handles both array-shaped and hash-shaped
`SimplefinAccount.raw_transactions_payload` (Sure stores it as a
flat array of transaction hashes — an earlier hash-only scrub
silently skipped array payloads and let stale txn ids leak back in
on subsequent syncs).

### Phase F — Sure-side dedup by external_id (optional integrity check)

After a Phase C cycle, or any time you want to verify no canonical
transaction is duplicated within Sure on the same account:

```bash
docker exec <sure> bin/rails runner /opt/simplefreen/ops/reimport/phase_f_sure_dedup_by_external_id.rb
docker exec -e APPLY=1 <sure> bin/rails runner /opt/simplefreen/ops/reimport/phase_f_sure_dedup_by_external_id.rb
```

Finds entries sharing the same non-null external_id within the
same account and deletes all but the richest. Real bank-side twins
(same date+amount+description but different canonical ids) survive
because they have different external_ids. In a clean steady state
this should report zero duplicate groups.

### Phase D — Validate

```bash
# expected: 0 v1id_remappable, 0 ambiguous
docker exec <sure> bin/rails runner /opt/simplefreen/ops/reimport/phase_a_sure.rb

# baseline entry count
docker exec <sure> bin/rails runner "puts Entry.where(source: %q(simplefin)).count"

# trigger a small resync (7 days); recount
# delta should be 0 (or only genuinely new postings since the previous resync)
docker exec <sure> bin/rails runner "puts Entry.where(source: %q(simplefin)).count"
```

UI spot-check the postings that hit the dup-class-2 trail during
migration (typically a handful of recent transactions across the
pre-/post-clearing window). Expect: one Entry each, original
categorization intact, no terse-vs-enriched twins.

## Rollback

Each write phase writes a timestamped backup before mutating:

```
/data/history/<SOURCE>/history.json.phase-b-bak-<UTC>
/data/history/<SOURCE>/history.json.phase-b5-bak-<UTC>
```

To revert canonical:

```bash
cp /data/history/<SOURCE>/history.json.phase-b-bak-<UTC> /data/history/<SOURCE>/history.json
```

Phase C runs inside a DB transaction. Mid-flight failure rolls back
automatically. To revert a successfully-applied Phase C, restore the
Sure DB from a snapshot taken before Phase C ran — there is no
in-script undo. The Phase A Sure artifact at `/tmp/phase_a_sure.json`
contains every `(sure_entry_id, old_external_id, new_external_id)`
mapping, so a hand-written reverse-rename script is possible if the
snapshot is unavailable, but it is not in scope here.

## Known limitations

- **Three-way phantom groups** (one terse + one enriched + one
  unrelated posting on the same (acc, date, amount)) are NOT collapsed
  by the provider or by Phase B.5 — too risky to over-collapse without
  manual confirmation. The pinned behavior is documented in
  `freentonic-providers/ing/test/ing_normalizer_test.rb#
  test_three_way_group_with_unrelated_posting_keeps_all`.
- **Sources without v2 coverage** (e.g. ING's "Cuenta de efectivo",
  Adicional / cancelled CCs) keep V1ID rows indefinitely. Their
  `txn_<hex>` is unstable across sessions; consumer dedup relies on
  the consumer's own (date, amount, description) heuristic rather
  than canonical identity. No procedure here fixes that — it requires
  upstream API access we don't have.
- **The procedure assumes a single SimpleFIN consumer** (Sure). If
  multiple consumers point at the same bridge, Phase C must run
  against each consumer separately with its own `phase_a_sure.json`.

## Related

- `ops/reimport/` — the scripts themselves
- `freentonic-providers/ing/REPORT-cc-v2-migration.md` — the migration
  report filed with the providers team
- `freentonic-providers/ing/test/ing_normalizer_test.rb` —
  prefix-collapse test coverage that pins the provider behavior
