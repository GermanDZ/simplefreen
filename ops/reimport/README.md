# ops/reimport — bridge canonical and consumer remap toolkit

Scripts to diagnose and remediate divergence between simplefreen's
bridge canonical (the per-source `history.json`) and a downstream
SimpleFIN consumer (Sure). Designed for the V1ID → v2-seq migration on
ING but parameterised on `SOURCE` so they can apply to any
freentonic-provider source that emits both stable (`v2-seq:*`) and
legacy (`___V1ID___*`) identifiers.

See `docs/reimport-runbook.md` for the full operational procedure.

## Scripts

| Script | Side | Purpose |
| --- | --- | --- |
| `phase_a_bridge.rb` | bridge (ruby) | Classify canonical txns by source_id kind, tag accounts with v2 coverage, build a (acc, date, amount) → v2-seq index. Read-only. |
| `phase_a_bridge_full_canonical.rb` | bridge (ruby) | Dump all canonical txns across all sources to `/tmp/canon_full.json` (id, date, amount, description, src). Read-only. Input for Phase G/H. |
| `phase_a_sure.rb` | sure (rails runner) | Match each Sure Entry against the bridge artifact; produce v1id_remappable / v1id_preserved / v2_seq / ambiguous / historical buckets. Read-only. |
| `phase_b_bridge_wipe.rb` | bridge (ruby) | Delete V1ID rows from canonical for accounts with v2 coverage. Atomic, backed up. Set `APPLY=1` to write. |
| `phase_b5_bridge_dedup.rb` | bridge (ruby) | Drop terse pre-clearing rows that ING re-emitted alongside their enriched post-clearing twin. Should report 0 prefix-dups now that `freentonic-providers/ing/normalizer.rb` collapses them at the provider; kept as diagnostic. |
| `phase_c_sure_remap.rb` | sure (rails runner) | Update Sure Entry.external_id from V1ID-based to v2-seq form; handle conflicts richness-aware; scrub per-account snapshot cache (both array and hash payload shapes). |
| `phase_f_sure_dedup_by_external_id.rb` | sure (rails runner) | Find Sure Entry rows that share (account_id, external_id); keep richest, delete duplicates. Integrity check; should report 0 groups in steady state. |
| `phase_g_sure_v1id_orphan_cleanup.rb` | sure (rails runner) | Find V1ID orphans (external_id not in any bridge canonical) and classify by ±3d/|amount|/desc-prefix near-match. Pure-dup orphans get deleted with category transfer; truly-orphan ones (likely Adicional/cancelled CC — see `feedback_v1id_orphan_handling.md`) are left alone. |
| `phase_h_sure_date_sync_from_bridge.rb` | sure (rails runner) | For every Sure entry whose external_id matches a bridge canonical txn_<hex>, update Sure's `date` to the bridge's current date. Fixes the systematic +1d drift between V1ID-era `/movements` (merchant txn date) and v2-seq-era `/v2/search` (bank value date). |
| `xls/build_xls_dataset.py` | local (python) | Combine cash + CC XLS exports into `/tmp/xls_rows_full.json`. Partitions by file date range to avoid the dedup-collapses-real-twins bug. |
| `xls/xls_diff_full.rb` | sure (rails runner) | Triple diff: bank XLS vs bridge canonical vs Sure entries. Surfaces missing/extra/upstream-gap rows. Match keyed by (date, |amount|). |

## Standard env knobs

- `DATA` — bridge data root (default `/data`)
- `SOURCE` — provider key (default `ING`)
- `APPLY` — set to `1` on write phases; default is always dry-run
- `BRIDGE_DATA` — `phase_a_bridge.json` location (default `/tmp/phase_a_bridge.json`)
- `SURE_DATA` — `phase_a_sure.json` location (default `/tmp/phase_a_sure.json`)
- `OVERRIDES` — Phase C manual ambiguous overrides JSON (default `/tmp/phase_c_overrides.json`)

## Quick run order

```bash
# Phase A — read-only diagnostic
docker exec <bridge>  ruby /path/to/phase_a_bridge.rb
docker exec <bridge>  cat /tmp/phase_a_bridge.json | docker exec -i <sure> tee /tmp/phase_a_bridge.json >/dev/null
docker exec <sure>    bin/rails runner /path/to/phase_a_sure.rb

# Phase B / B.5 / C — write phases (dry-run first, then APPLY=1)
docker exec -e APPLY=1 <bridge> ruby /path/to/phase_b_bridge_wipe.rb
# resync source via admin UI
docker exec -e APPLY=1 <bridge> ruby /path/to/phase_b5_bridge_dedup.rb
docker exec -e APPLY=1 <sure>   bin/rails runner /path/to/phase_c_sure_remap.rb
```

All write phases produce a timestamped backup of the file they touch.
Phase C wraps DB changes in `ApplicationRecord.transaction` so a
mid-flight failure rolls back.
