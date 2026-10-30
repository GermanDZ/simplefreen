# Fix plan — Sure silently drops every SimpleFIN sync (`balance_date` overflow)

**Date:** 2026-07-04
**Status:** ✅ RESOLVED — deployed 2026-07-04, verified 2026-07-05 (see Resolution)
**Owner:** GermanDZ

## Symptom

simplefreen syncs fine and the bridge serves fresh data, but Sure reports
"synced" while showing **no new transactions or balances**. This has been
silent for weeks — the item-level `SyncJob` reports `completed`, so nothing
surfaces in the UI.

## Root cause

Sure's SimpleFIN importer writes the raw `balance-date` field (a Unix-epoch
**integer**, e.g. `1783154795`) straight into the `balance_date` **datetime**
column:

```ruby
# app/models/simplefin_item/importer.rb  (two call sites: import_account
# and import_account_minimal_and_balance)
balance_date: (account_data["balance-date"] || account_data[:"balance-date"]),
```

Postgres tries to parse the integer as a literal timestamp and raises:

```
PG::DatetimeFieldOverflow: ERROR: date/time field value out of range: "1783154795"
```

Because this happens inside the same `save!`/`update!` that also carries the
**merged transactions and the new balance**, the *entire* per-account update is
rolled back. The exception is caught per-account (`rescue => e ... "Skipping
account during regular sync"`) so the job still reports success — but
`raw_transactions_payload` never gets the new rows, and no `Entry` records are
created.

### Confirmed live (2026-07-04 08:46 UTC sync)

Every SimpleFIN account logged the identical error and was skipped, while the
bridge had fresh data (ING history file updated 06:30 UTC the same day). The
bug is not in simplefreen — the bridge correctly emits epoch integers per the
SimpleFIN spec. The same epoch format is already parsed correctly for
transaction `posted`/`transacted_at` timestamps and by
`SimplefinAccount#parse_balance_date`; only the two importer call sites skip the
conversion.

### Why the bridge format is NOT the fix

`balance-date` (and `posted`/`transacted_at`) are Unix-epoch integers by the
SimpleFIN spec. Switching simplefreen to ISO-8601 would be non-standard and
would break the transaction-merge comparator, which does `ax[:posted].to_i` on
the epoch value (`.to_i` on an ISO string → `0`). Fix belongs on the consumer.

## The fix already exists upstream — just pull

`~/code/sure-finances` is a clean fork of `we-promise/sure`:

- `main` has **0 local commits** (100 commits *behind* `upstream/main`, 0 ahead).
  The SimpleFIN importer is pure upstream code — no fork patches to preserve.
- Upstream commit **`dcf6260a` "Fix SimpleFIN epoch-string balance dates (#2397)"**
  (2026-06-24) fixes exactly this: it adds a `normalize_balance_date(value)`
  helper delegating to `Simplefin::DateUtils.parse_provider_time`, which handles
  `Integer`/`Float` epoch via `Time.at(val).utc`, epoch strings, and ISO. Both
  importer call sites now wrap the field. Tests were added too.

So **pulling `upstream/main` ships the fix for free** — no manual patch needed.
A fast-forward is safe because `main` is a strict ancestor of `upstream/main`.

## What the 100-commit pull brings

- **8 new DB migrations** (transfers fees/amount + `transfer_id` on
  transactions, account `exclude_from_reports`, goal allocation/progress,
  snaptrade oauth device flow). Migrations run automatically: the container
  entrypoint runs `./bin/rails db:prepare` on boot.
- General upstream feature/bugfix drift. Low risk (we track upstream directly),
  but the DB backup before deploy is the safety net.

## Recovery of the ~weeks-long gap — mostly self-healing

`last_synced_at` is on the **item**, not per-account, and advances on every
"completed" run (`syncer.rb:161`) regardless of the per-account failures — so
the watermark moved forward while no data landed.

However, **every sync's discovery phase already re-fetches full per-account
history** with no date window (`perform_account_discovery`, `start_date: nil`).
In the 08:46 log this returned the complete histories (hundreds to
thousands of txns per account) and called `import_account` on
each — it only failed at the `save!`. Once the save no longer crashes, that
first successful sync **merges the full history back into
`raw_transactions_payload` and persists it**, and the transaction processor
creates the missing `Entry` rows. So the gap self-heals on the next 1–2 syncs;
no special backfill script is required.

Fallback if any account still looks short after the first post-deploy sync:
force a full chunked-history rebuild for that item by clearing its watermark in
the Rails console, then re-sync —
`SimplefinItem.find(id).update!(last_synced_at: nil)` (triggers the
`import_with_chunked_history` path).

## Execution steps

All commands run from `~/code/simplefreen` unless noted. Deploy tooling
lives here (`bin/deploy-sure` → `sure/bin/rebuild`); it rsyncs the local
`~/code/sure-finances` checkout to the LXC and builds with plain
`docker build` against the host-local registry (Kamal's remote buildx can't
reach the LXC loopback registry).

1. **Update the fork to latest upstream.**
   ```bash
   cd ~/code/sure-finances
   git fetch upstream
   git status -s            # confirm clean working tree
   git merge --ff-only upstream/main
   # verify the fix landed:
   grep -n "normalize_balance_date" app/models/simplefin_item/importer.rb
   git push origin main     # keep origin in sync so the built image isn't tagged -dirty
   ```
   > No manual code edit needed — the fix is in `dcf6260a`. If for some reason a
   > non-ff appears (unexpected local commits), stop and reassess rather than
   > force-merging.

2. **Optional local sanity check** (if a local Ruby/DB is handy; otherwise rely
   on upstream's CI + the added tests):
   ```bash
   bin/rails test test/models/simplefin_item/importer_test.rb \
                  test/models/simplefin_account_test.rb
   ```

3. **Back up prod DB + rebuild + roll** (single command; backs up first):
   ```bash
   cd ~/code/simplefreen
   bin/deploy-sure
   ```
   This does: `bin/backup-db pre-deploy` → `sure/bin/rebuild` (rsync local
   checkout → LXC, `docker build`, push to `127.0.0.1:5000`) →
   `kamal app stop && kamal app boot`. Migrations run via `db:prepare` on boot.

4. **Verify the deploy.**
   ```bash
   cd ~/code/simplefreen/sure
   curl -sf https://sure.example.com/up && echo OK
   kamal app logs -f                 # web
   kamal app logs -r worker -f       # Sidekiq
   ```

5. **Trigger a SimpleFIN sync** (admin "Sync all" action, or wait for the
   scheduled run) and confirm the worker log shows, for each account:
   - `Merging transactions … N existing + M new` **followed by no**
     `PG::DatetimeFieldOverflow` / `Skipping account` warning, and
   - `Completed for simplefin_account … : N processed, 0 errors`.

6. **Confirm in the Sure UI** that recent transactions and balances now appear.
   Spot-check one high-volume account (e.g. the main checking account) against the
   bridge feed or the ING XLS export.

7. **If any account is still short:** apply the per-item watermark reset from
   the Recovery section and re-sync once.

## Rollback

If a migration or upstream change misbehaves:
```bash
cd ~/code/simplefreen/sure
# restore the pre-deploy dump created in step 3
bin/restore-db backups/sure-<ts>-pre-deploy.dump
# roll back to the previous image tag (list tags on the LXC registry)
```
The previous image is still in the LXC local registry tagged by its git SHA;
boot it explicitly if needed.

## Resolution (2026-07-05)

Deployed 2026-07-04 (fork `main` ff-merged to `upstream/main` `690f1c64`,
carrying `dcf6260a`; `normalize_balance_date` confirmed at both importer call
sites). Verified live on 2026-07-05:

- **Health:** `sure.example.com/up` green; **no** `PG::DatetimeFieldOverflow`
  / `Skipping account` in worker logs since the deploy.
- **Data landing (step 5):** 25 `Entry` rows created in the trailing 36 h,
  newest 2026-07-05 02:22 UTC; item watermark advanced to the same time. Since
  the overflow rolled back the whole per-account `save!`, entries being created
  is direct proof the crash is gone.
- **Gap healed (step 6):** every live account shows a current `last_entry`
  (2026-07-01 → 07-05) and a real balance — no account stuck in mid-June, so the
  full-history re-fetch self-heal completed. Step 7 watermark reset not needed.
- **Drift audit** (a bridge↔Sure drift-audit script, prod family):
  **`phantom_payload: 0`** (every bridge-served txn present in Sure) and
  **`amount_drifts: 0`**. Remaining `date_shifts` (all Revolut FX),
  `name_drifts`, and `orphan_entries` (cancelled/Adicional ING cards) are
  pre-existing legacy items unrelated to this fix.

## References

- Bug: `sure-finances/app/models/simplefin_item/importer.rb` (import_account,
  import_account_minimal_and_balance)
- Fix: upstream `dcf6260a`; helper `Simplefin::DateUtils.parse_provider_time`
  (`lib/simplefin/date_utils.rb`)
- Deploy tooling: `simplefreen/bin/deploy-sure`, `simplefreen/sure/bin/rebuild`
- Bridge emission (correct, spec-compliant): `simplefreen/lib/simplefreen/reshape.rb`
  (`balance-date`), `consolidated_reshape.rb`
- Related memory: Sure internals (raw_transactions_payload cache, external_id),
  bridge architecture, Sure↔bridge serving.
