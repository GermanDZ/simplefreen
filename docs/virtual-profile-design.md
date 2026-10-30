# Virtual consolidated profile — design

Status: spec for slice 1. Captures the agreed shape; implementation in progress.

## Goal

Expose a single SimpleFIN URL (one access URL the operator pastes into Sure.am
/ Actual Budget) that serves a consolidated view across every configured
source profile. Per-profile URLs continue to work in parallel for debugging
and for clients that genuinely want a single source.

The signature feature: **per-source date windows per linked group.** Direct
providers (ING, Unicaja, Revolut) typically have ~18-month rolling history.
Aggregators (Fintonic) often have many years. The operator picks a calendar
cutoff per linked account — e.g. Fintonic for everything up to 2024-12-31,
ING for 2025-01-01 onward — and the merged stream for that account is the
union of each source's window. This sidesteps the deep dedup problem by
making source-of-truth explicit and date-anchored rather than fuzzy.

The consolidation logic and inspector already exist in `Consolidation` and the
admin UI — this document covers the next layer: actually serving the merged
output to SimpleFIN clients.

## Naming and lifecycle

- Add `consolidated` to `Paths::FILENAME_PATTERN`-compatible keys and to
  `RESERVED_PROFILE_KEYS` so it can't be accidentally created as a regular
  source profile.
- The virtual profile is a real `ProfileStore` entry. Its on-disk shape is
  almost identical to a regular profile (so the existing access-URL / setup-
  token / hidden-accounts machinery applies unchanged) with one new field:

  ```json
  {
    "profile_key": "consolidated",
    "kind": "virtual",
    "workflow": null,
    "display_name": "Consolidated",
    "access_url": { ... },
    "hidden_accounts": [],
    "consolidation": {
      "primary_overrides": {
        "acc_<hex>": "ing"
      },
      "hidden_in_virtual": []
    }
  }
  ```

- `kind: "virtual"` blocks sync triggers in the scheduler (no `workflow` to
  invoke; calling `/sync` returns 422).
- One virtual profile per simplefreen install. The admin UI gets a "Set up
  consolidated profile" button that creates it the first time and surfaces its
  setup token. Subsequent edits to primary overrides / hidden lists go through
  a dedicated panel rather than the generic edit form.
- Auto-created on first migration? No — explicit opt-in. Operators with one
  source don't need it; surfacing it before there's anything to consolidate is
  noise.

## SimpleFIN serve path

Hooks into the existing `Protocol#handle_accounts` with a thin "virtual"
branch at the top:

```
if profile_key == "consolidated":
    return handle_virtual_accounts(...)
else:
    # existing per-profile path, untouched
```

The virtual handler:

1. Auth check: same basic-auth flow against the virtual profile's access URL.
2. Load every source profile's latest canonical (`Consolidation.load_canonicals`).
3. Build groups (`Consolidation.build_groups`, with aliases from `consolidation_store`).
4. For each group, resolve the primary source:
   - `consolidation.primary_overrides[group_id]` if set;
   - else `Group#suggested_primary` from the existing heuristic.
5. Build the merged SimpleFIN envelope (see below).
6. Apply query params (`Reshape.apply_query`) and the virtual profile's own
   `hidden_accounts` / `consolidation.hidden_in_virtual` filter.
7. Aggregate per-source error/freshness signals into the envelope's `errors`.

## Account-id stability — the load-bearing decision

The SimpleFIN account `id` for a linked group is **the primary source's
`acc_<hex>`** — not `Group#id` (which is alphabetical-first member and would
flip when a new alias adds an earlier-sorting member).

Implications:
- Adding/removing aliases never changes the emitted SimpleFIN id. Only an
  explicit primary swap does, and that's an operator-initiated event.
- Singletons emit their own `acc_<hex>` directly.
- Account metadata (`name`, `org`, `currency`, `balance`) comes from the
  primary source's record. Secondary metadata is dropped.

Operator UX: in the Linked-accounts panel, each multi-source group gets a
primary-source selector. Switching it updates `consolidation.primary_overrides`
and on the next `/accounts` call Actual sees the account-id change. We surface
a warning at switch time ("This will appear as a new account in Actual; reconcile
manually after").

## Transaction strategy: per-source date windows

Each linked group can have a `windows` map keyed by source profile:

```json
{
  "members": ["acc_0123456789abcdef"],
  "primary": "ING",
  "windows": {
    "ING":      { "from": "2025-01-01", "to": null },
    "FINTONIC": { "from": null,         "to": "2024-12-31" }
  }
}
```

A source's transaction is included in the merged stream iff its `date` is
within that source's `[from, to]` (inclusive on both ends; null = unbounded).

**Default when `windows` is unset for a group: primary-only.** Primary takes
all dates, secondaries get nothing. Operator opts in to multi-source by
editing windows. This keeps fresh virtual profiles predictable.

**Overlap policy: warn-but-allow with conservative bucket dedup.** If two
sources are configured to cover the same date range, the operator gets a
warning at save time but the config is accepted. At serve time, in the
overlap region, transactions from both sources are bucketed by `(account,
date, amount, currency, normalized_description)`:

- If only primary has txns in a bucket: emit primary's. (Trivial case.)
- If only secondary has txns in a bucket: emit secondary's. (Primary missed
  the txn — backfill from secondary.)
- If both have txns: emit primary's. If secondary has more in the bucket
  than primary, emit the surplus from secondary too. (Operator preference:
  duplication is preferred to data loss; descriptions that don't normalize
  identically end up in different buckets and both surface.)

This dedup applies only within overlap regions. Outside the overlap, each
source's txns flow through unfiltered.

**Validations at config save (and re-evaluated on every serve):**

1. **Overlap**: two sources cover the same date range. Warn-but-allow.
2. **Gap**: there's a date between the earliest source's earliest covered
   date and today that no source covers. Warn — that period will be empty.
3. **Out-of-coverage**: a configured `from` is before the source's earliest
   actually-available txn. Warn — older dates won't appear from that source
   even though configured. This warning is dynamic; each source's earliest
   txn moves as data rolls.

## Transaction id stability

Linked groups emit transactions that come from one specific source profile
(the primary, in v1). The txn id we put on the SimpleFIN wire is the **source
profile's txn `id` verbatim** — already a stable hash of `(account_id,
source_id || (date, amount, raw_description))`. No rewriting.

Singletons: same — emit the source's txn id.

Consequence: if the primary swaps for a group, every txn id in that group
changes. That's the explicit cost of a primary swap; it's why we put a warning
on the swap action. (The alternative — synthesizing a stable id on top — would
make it impossible to identify which provider's record is authoritative when
debugging, and the "stable across primary swaps" guarantee is mostly cosmetic
because operators rarely swap primaries.)

## Per-source error / freshness aggregation

Error states from any contributing source surface in the envelope's `errors`
array, prefixed with the source's profile_key:

```
"errors": [
  "[fintonic] Re-authentication required. Last good data is 36 hours old.",
  "[unicaja] Background refresh failed: timeout. Retry scheduled."
]
```

`enqueue_if_possible` is invoked per source whose state would normally
trigger it (error + last-good-old-enough; never from `needs_reauth`).

Freshness threshold for surfacing a stale-data warning even when state is
nominally `ready`: when a source's `last_synced_at` is older than max(2 ×
that profile's `sync_interval_seconds`, 24h). Tunable per-profile via a new
`stale_warning_seconds` field if we hit cases where the default isn't right.

## Hidden-account semantics

Two layers:

- **Per-source `hidden_accounts`** (existing): hides the account in the
  source profile's own SimpleFIN URL AND in the consolidated view. Used when
  an account shouldn't be served anywhere (closed account, test pocket, etc).
- **Virtual-profile `consolidation.hidden_in_virtual`** (new): hides only in
  the consolidated view. Used when the account should still be available
  via its own URL but isn't wanted in the merged stream — e.g., a Fintonic
  singleton account from bank `0232` that the operator doesn't track in
  Actual.

## Hidden aggregator-singletons (default-on policy?)

Open question for v1: should we, by default, hide aggregator-only singletons
in the consolidated output when the operator has direct providers configured?
i.e., if the operator has direct ING + direct Unicaja + Fintonic, should
Fintonic's `0232` and `2048` accounts (Fintonic-only banks) appear in the
consolidated view?

Argument for: operators who deliberately set up Fintonic as a fallback want
to see those accounts.

Argument against: operators who set up Fintonic just to bridge accounts they
already track directly will not want orphan aggregator accounts to leak.

Proposal: explicit per-source `aggregator_role` config. When `aggregator: true`,
the source's singletons are excluded from the consolidated view by default
unless explicitly un-hidden. Linked-group contributions are unaffected. Default
is `aggregator: false`, opt-in.

## Migration / rollout

1. Ship the virtual profile feature behind no feature flag — additive, doesn't
   touch existing per-profile flow.
2. Operator creates a virtual profile in the admin UI when ready.
3. Operator points Sure.am at the new URL; when convinced, removes the
   per-profile entries from Sure.am.
4. Per-profile URLs continue to work indefinitely. No deprecation planned.

## Slice-by-slice implementation plan

**Slice 1 — virtual profile + source-window merge (this slice).**

- `RESERVED_PROFILE_KEYS` += "consolidated".
- `ProfileStore`: accept and persist `kind`. Validate `kind ∈ {"source",
  "virtual"}` (default "source"). Skip `workflow` validation when virtual.
- `Scheduler`: refuse to enqueue a virtual profile.
- `ConsolidationGroupsStore`: persists per-group `primary` + `windows` at
  `<root>/consolidation/groups.json`, keyed by sorted-member-set.
- `Consolidation::Windows` module: window arithmetic (in_range?,
  validate_overlap, validate_gap, validate_coverage).
- `ConsolidatedReshape` module: walks all source canonicals, applies the
  per-group window filter, dedups overlap regions by `(date, amount,
  currency, normalized_desc)` buckets per the rules above, returns a
  SimpleFIN envelope.
- `Protocol#handle_accounts`: virtual branch.
- Admin API: `POST /admin/api/consolidation/virtual-profile` to create the
  virtual profile; `GET/PUT /admin/api/consolidation/groups-config` to
  manage primary + windows; warnings surface in the GET response so the UI
  can render them.
- UI: per-multi-source-group editor showing source date pickers, a timeline
  visualization, "Suggest windows" button, live warnings; virtual profile
  setup-token panel mirroring the per-profile flow.
- Tests: pure-logic coverage on Windows arithmetic and ConsolidatedReshape;
  store round-trip; protocol-level test for the virtual branch.

**Slice 2 — operator polish (deferred).**

- `aggregator_role` field on source profiles + filter for aggregator
  singletons in `ConsolidatedReshape`.
- `hidden_in_virtual` per-account control in the Linked-accounts panel.
- Coverage / drift dashboard: per linked group, show primary-vs-secondary
  diffs, source-coverage gaps over time. Diagnostic-only.

## Open questions

- Does Sure.am tolerate a SimpleFIN endpoint that serves both linked
  multi-currency accounts and singletons in different currencies? (Should be
  fine — the per-account `currency` field disambiguates — but worth a probe
  before committing.)
- Should the virtual profile's setup token appear in the regular setup-token
  panel or in a separate one? Cleaner to keep it separate; the virtual
  profile is fundamentally different from a source profile.
- Do we want a "preview merge" button in the admin UI that shows the exact
  SimpleFIN response a client would get, side-by-side with each source's
  raw envelope? Useful for debugging but maybe overkill for v1.
