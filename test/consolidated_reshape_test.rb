# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

module Simplefreen
  class ConsolidatedReshapeTest < Minitest::Test
    # Two profiles see acc_match (auto-linked via portable_ref).
    # Each has txns spanning a multi-year range so we can exercise
    # the per-source date windows.
    def canonicals
      ing_txs = [
        { "id" => "txn_ing_2026", "account_id" => "acc_match", "date" => "2026-04-01",
          "amount" => "-10.00", "currency" => "EUR", "description" => "Rent" },
        { "id" => "txn_ing_2025_a", "account_id" => "acc_match", "date" => "2025-06-15",
          "amount" => "-50.00", "currency" => "EUR", "description" => "Groceries" },
        { "id" => "txn_ing_2025_b", "account_id" => "acc_match", "date" => "2025-01-15",
          "amount" => "1000.00", "currency" => "EUR", "description" => "Salary" }
      ]
      fin_txs = [
        { "id" => "txn_fin_2024", "account_id" => "acc_match", "date" => "2024-12-15",
          "amount" => "-20.00", "currency" => "EUR", "description" => "Coffee" },
        { "id" => "txn_fin_2023", "account_id" => "acc_match", "date" => "2023-08-01",
          "amount" => "-100.00", "currency" => "EUR", "description" => "Electronics" },
        # Same-day-amount-desc as ing_2025_a → would be a dedup candidate
        # if their date windows overlap.
        { "id" => "txn_fin_overlap", "account_id" => "acc_match", "date" => "2025-06-15",
          "amount" => "-50.00", "currency" => "EUR", "description" => "Groceries" }
      ]
      {
        "ing" => {
          "schema_version" => "0.1",
          "accounts" => [{
            "id" => "acc_match", "source_id" => "___V1ID___xyz", "institution" => "ing",
            "name" => "Main Account", "currency" => "EUR",
            "iban" => "ES0014650000000000001234",
            "balance" => { "current" => "1500.00" }
          }],
          "transactions" => ing_txs
        },
        "fintonic" => {
          "schema_version" => "0.1",
          "accounts" => [{
            "id" => "acc_match", "source_id" => "1465:1234", "institution" => "fintonic",
            "name" => "Bank 1465 ACCOUNT #1234", "currency" => "EUR",
            "balance" => { "current" => "1500.00" }
          }],
          "transactions" => fin_txs
        }
      }
    end

    # Regression: ConsolidatedReshape.reshape_tx is a parallel
    # envelope-assembly path to Reshape.reshape_transaction. When the
    # Revolut adapter started canonicalizing DECLINED/FAILED/REVERTED
    # event-log entries, Reshape was patched to
    # drop them via SERVED_STATUSES but ConsolidatedReshape silently
    # served them on /simplefin/consolidated. Both paths must filter
    # identically.
    def test_consolidated_drops_non_served_statuses
      canonicals_with_declined = {
        "ing" => {
          "schema_version" => "0.1",
          "accounts" => [{
            "id" => "acc_match", "source_id" => "___V1ID___xyz", "institution" => "ing",
            "name" => "Acc", "currency" => "EUR",
            "iban" => "ES0014650000000000001234",
            "balance" => { "current" => "100.00" }
          }],
          "transactions" => [
            { "id" => "txn_posted00000000", "account_id" => "acc_match", "date" => "2026-04-01",
              "amount" => "-10.00", "currency" => "EUR", "description" => "ok",
              "status" => "posted" },
            { "id" => "txn_declined000000", "account_id" => "acc_match", "date" => "2026-04-01",
              "amount" => "-10.00", "currency" => "EUR", "description" => "auth retry",
              "status" => "declined" },
            { "id" => "txn_failed00000000", "account_id" => "acc_match", "date" => "2026-04-01",
              "amount" => "-10.00", "currency" => "EUR", "description" => "top-up fail",
              "status" => "failed" },
            { "id" => "txn_reverted000000", "account_id" => "acc_match", "date" => "2026-04-01",
              "amount" => "-10.00", "currency" => "EUR", "description" => "reverted leg",
              "status" => "reverted" }
          ]
        }
      }
      result = ConsolidatedReshape.call(
        canonicals_by_profile: canonicals_with_declined, aliases: [], group_configs: []
      )
      ids = result.envelope["accounts"].first["transactions"].map { |t| t["id"] }
      assert_equal ["txn_posted00000000"], ids
    end

    def test_default_no_config_serves_primary_only
      result = ConsolidatedReshape.call(
        canonicals_by_profile: canonicals, aliases: [], group_configs: []
      )
      txs = result.envelope["accounts"].first["transactions"]
      assert_equal 3, txs.size, "primary (ING) contributes all 3 txns"
      ids = txs.map { |t| t["id"] }
      assert_includes ids, "txn_ing_2026"
      refute_includes ids, "txn_fin_2024", "fintonic suppressed by default"
      refute_includes ids, "txn_fin_2023"
    end

    def test_non_overlapping_windows_serve_both_sources_no_dedup
      # ING from 2025-01-01 onward, Fintonic up to 2024-12-31. No overlap.
      configs = [{
        "members" => ["acc_match"],
        "primary" => "ing",
        "windows" => {
          "ing"      => { "from" => "2025-01-01", "to" => nil },
          "fintonic" => { "from" => nil,         "to" => "2024-12-31" }
        }
      }]
      result = ConsolidatedReshape.call(
        canonicals_by_profile: canonicals, aliases: [], group_configs: configs
      )
      ids = result.envelope["accounts"].first["transactions"].map { |t| t["id"] }
      assert_includes ids, "txn_ing_2026"
      assert_includes ids, "txn_ing_2025_a"
      assert_includes ids, "txn_ing_2025_b"
      assert_includes ids, "txn_fin_2024"
      assert_includes ids, "txn_fin_2023"
      # Crucially, the duplicate-by-signature 2025-06-15/-50/Groceries
      # only exists in ING's window — fintonic's same-shape txn is
      # OUTSIDE its window, so it doesn't appear.
      refute_includes ids, "txn_fin_overlap",
        "fintonic txn outside window must be excluded"
      assert_equal 5, ids.size
      # Dates should be sorted desc.
      dates = result.envelope["accounts"].first["transactions"].map { |t| Time.at(t["posted"]).strftime("%Y-%m-%d") }
      assert_equal dates.sort.reverse, dates
    end

    def test_overlap_collapses_cosmetic_description_divergence
      # The whole reason bucket-based dedup uses (date, amount, currency)
      # only — descriptions diverge across providers (Fintonic strips
      # merchant city, ING keeps it, etc.) and we want the dedup to
      # work *despite* that divergence. If signature accidentally
      # included description, this would emit both txns; with the
      # correct signature, it collapses to primary's only.
      cs = {
        "ing" => {
          "accounts" => [{ "id" => "acc_x", "currency" => "EUR",
                           "iban" => "ESxx", "institution" => "ing", "name" => "ING acc",
                           "balance" => { "current" => "100.00" } }],
          "transactions" => [
            { "account_id" => "acc_x", "id" => "txn_ing_a",
              "date" => "2025-04-15", "amount" => "-12.50", "currency" => "EUR",
              "description" => "PAGO EN GROCERIES MADRID" }   # ING's verbose form
          ]
        },
        "fintonic" => {
          "accounts" => [{ "id" => "acc_x", "currency" => "EUR",
                           "institution" => "fintonic", "name" => "Fintonic mirror",
                           "balance" => { "current" => "100.00" } }],
          "transactions" => [
            { "account_id" => "acc_x", "id" => "txn_fin_a",
              "date" => "2025-04-15", "amount" => "-12.50", "currency" => "EUR",
              "description" => "Pago en groceries" }   # Fintonic's stripped form
          ]
        }
      }
      configs = [{
        "members" => ["acc_x"],
        "primary" => "ing",
        "windows" => {
          "ing"      => { "from" => "2025-01-01", "to" => nil },
          "fintonic" => { "from" => "2025-01-01", "to" => nil }
        }
      }]
      result = ConsolidatedReshape.call(
        canonicals_by_profile: cs, aliases: [], group_configs: configs
      )
      txs = result.envelope["accounts"].first["transactions"]
      ids = txs.map { |t| t["id"] }
      # Bucket has 1 primary + 1 secondary. Rule emits primary's only.
      assert_equal ["txn_ing_a"], ids,
        "1 primary + 1 secondary with cosmetically-different desc should collapse to primary's only"
    end

    def test_overlap_dedups_matching_bucket_emits_extras
      # Both windows include 2025-06-15. Both sides have a txn with
      # signature (2025-06-15, -50.00, EUR, "Groceries"). Should emit
      # primary's only (1:1 collapse).
      configs = [{
        "members" => ["acc_match"],
        "primary" => "ing",
        "windows" => {
          "ing"      => { "from" => "2025-01-01", "to" => nil },
          "fintonic" => { "from" => "2025-01-01", "to" => nil }
        }
      }]
      result = ConsolidatedReshape.call(
        canonicals_by_profile: canonicals, aliases: [], group_configs: configs
      )
      ids = result.envelope["accounts"].first["transactions"].map { |t| t["id"] }
      assert_includes ids, "txn_ing_2025_a"
      refute_includes ids, "txn_fin_overlap",
        "fintonic txn with identical signature collapses into ING's"
    end

    def test_overlap_emits_secondary_when_primary_missing_from_bucket
      # Add a fintonic-only txn in a date both windows cover. Primary
      # has nothing in that bucket → emit secondary's.
      cs = canonicals
      cs["fintonic"]["transactions"] << {
        "id" => "txn_fin_unique", "account_id" => "acc_match", "date" => "2025-09-01",
        "amount" => "-77.00", "currency" => "EUR", "description" => "OnlySeenByFintonic"
      }
      configs = [{
        "members" => ["acc_match"],
        "primary" => "ing",
        "windows" => {
          "ing"      => { "from" => "2025-01-01", "to" => nil },
          "fintonic" => { "from" => "2025-01-01", "to" => nil }
        }
      }]
      result = ConsolidatedReshape.call(
        canonicals_by_profile: cs, aliases: [], group_configs: configs
      )
      ids = result.envelope["accounts"].first["transactions"].map { |t| t["id"] }
      assert_includes ids, "txn_fin_unique",
        "secondary's unique-bucket txn must surface (gap-fill)"
    end

    def test_overlap_emits_secondary_surplus_when_bucket_count_mismatch
      cs = canonicals
      # Add a SECOND fintonic txn with same signature as the existing
      # overlap one; ING has only ONE in the bucket, fintonic has TWO.
      cs["fintonic"]["transactions"] << {
        "id" => "txn_fin_overlap_2", "account_id" => "acc_match", "date" => "2025-06-15",
        "amount" => "-50.00", "currency" => "EUR", "description" => "Groceries"
      }
      configs = [{
        "members" => ["acc_match"],
        "primary" => "ing",
        "windows" => {
          "ing"      => { "from" => "2025-01-01", "to" => nil },
          "fintonic" => { "from" => "2025-01-01", "to" => nil }
        }
      }]
      result = ConsolidatedReshape.call(
        canonicals_by_profile: cs, aliases: [], group_configs: configs
      )
      bucket = result.envelope["accounts"].first["transactions"]
        .select { |t| Time.at(t["posted"]).strftime("%Y-%m-%d") == "2025-06-15" && t["amount"] == "-50.00" }
      assert_equal 2, bucket.size,
        "primary 1 + secondary surplus 1 = 2 emitted (fin had 2, ing had 1)"
    end

    def test_pinned_primary_with_no_windows_unbounds_pinned_not_heuristic
      # Regression: if operator pins `primary: "fintonic"` and leaves
      # windows empty (relying on default primary-only), fintonic must
      # be the source that gets the unbounded window — not the
      # heuristic-suggested primary (which would have been ING here
      # because of the IBAN). The earlier bug silently swapped them
      # and produced an empty stream when ING had no txns for the
      # account.
      cs = canonicals
      configs = [{
        "members" => ["acc_match"],
        "primary" => "fintonic",
        "windows" => {}
      }]
      result = ConsolidatedReshape.call(
        canonicals_by_profile: cs, aliases: [], group_configs: configs
      )
      txs = result.envelope["accounts"].first["transactions"]
      ids = txs.map { |t| t["id"] }
      # Operator wanted fintonic; ING should be skipped.
      refute_includes ids, "txn_ing_2026"
      refute_includes ids, "txn_ing_2025_a"
      # Fintonic's full set should appear.
      assert_includes ids, "txn_fin_2024"
      assert_includes ids, "txn_fin_2023"
    end

    def test_pinned_primary_overrides_heuristic
      # Default heuristic prefers the IBAN-bearing account (ING). Pin
      # fintonic and verify it's used as the emitted account_id source.
      cs = canonicals
      cs["ing"]["accounts"][0]["iban"] = "ES0014650000000000001234"
      configs = [{
        "members" => ["acc_match"],
        "primary" => "fintonic",
        "windows" => {}
      }]
      result = ConsolidatedReshape.call(
        canonicals_by_profile: cs, aliases: [], group_configs: configs
      )
      acc = result.envelope["accounts"].first
      assert_equal "Bank 1465 ACCOUNT #1234", acc["name"],
        "pinned fintonic primary surfaces fintonic's metadata"
    end

    def test_warning_overlap_surfaces
      configs = [{
        "members" => ["acc_match"],
        "primary" => "ing",
        "windows" => {
          "ing"      => { "from" => "2024-06-01", "to" => nil },
          "fintonic" => { "from" => nil,         "to" => "2025-01-01" }
        }
      }]
      result = ConsolidatedReshape.call(
        canonicals_by_profile: canonicals, aliases: [], group_configs: configs
      )
      assert(result.warnings.any? { |w| w.kind == :overlap },
             "expected an overlap warning for 2024-06-01..2025-01-01")
    end

    def test_warning_gap_surfaces
      configs = [{
        "members" => ["acc_match"],
        "primary" => "ing",
        "windows" => {
          "ing"      => { "from" => "2025-06-01", "to" => nil },
          "fintonic" => { "from" => nil,         "to" => "2025-01-01" }
        }
      }]
      result = ConsolidatedReshape.call(
        canonicals_by_profile: canonicals, aliases: [], group_configs: configs
      )
      assert(result.warnings.any? { |w| w.kind == :gap },
             "expected a gap warning for 2025-01-02..2025-05-31")
    end

    def test_warning_out_of_coverage_surfaces
      # ING earliest available is 2025-01-15 in our fixture. Set its
      # `from` to 2024-01-01 → out-of-coverage warning.
      configs = [{
        "members" => ["acc_match"],
        "primary" => "ing",
        "windows" => {
          "ing"      => { "from" => "2024-01-01", "to" => nil },
          "fintonic" => { "from" => nil,         "to" => "2023-12-31" }
        }
      }]
      result = ConsolidatedReshape.call(
        canonicals_by_profile: canonicals, aliases: [], group_configs: configs
      )
      assert(result.warnings.any? { |w| w.kind == :out_of_coverage && w.message.include?("ing") },
             "expected an out_of_coverage warning for ing")
    end

    def test_falls_back_to_available_when_current_balance_missing
      # Credit cards often surface only `available`, never `current`. Without
      # a fallback, Actual rejects the account ("must have either current or
      # available balance"). Ensure consolidated reshape uses available as
      # the SimpleFIN `balance` field in that case.
      cs = {
        "ing" => {
          "accounts" => [{
            "id" => "acc_creditcard", "institution" => "ing", "currency" => "EUR",
            "name" => "Visa", "balance" => { "available" => "230.50" }
          }],
          "transactions" => []
        }
      }
      result = ConsolidatedReshape.call(
        canonicals_by_profile: cs, aliases: [], group_configs: []
      )
      acc = result.envelope["accounts"].first
      assert_equal "230.50", acc["balance"]
      refute acc.key?("available-balance"),
        "available-balance must be omitted when equal to balance (SimpleFIN spec)"
      assert_empty result.envelope["errors"]
    end

    def test_defaults_balance_to_zero_when_neither_current_nor_available_present
      # Some providers (Fintonic credit cards in particular) surface no
      # balance figures at all. Rather than drop the account, default to
      # "0.00" so it still shows up in Actual; the operator can update.
      cs = {
        "ing" => {
          "accounts" => [{
            "id" => "acc_noBalance", "institution" => "ing", "currency" => "EUR",
            "name" => "Mystery", "balance" => {}
          }],
          "transactions" => []
        }
      }
      result = ConsolidatedReshape.call(
        canonicals_by_profile: cs, aliases: [], group_configs: []
      )
      acc = result.envelope["accounts"].first
      assert_equal "0.00", acc["balance"]
      refute acc.key?("available-balance")
      assert_empty result.envelope["errors"]
    end

    def test_balance_override_replaces_primary_balance
      # Use case: bank reports the same shared debt across several
      # plastic-card accounts (joint card, secondary cards). Operator
      # zeros out the duplicates so the downstream aggregator doesn't
      # multi-count the debt.
      cs = {
        "ing" => {
          "accounts" => [{
            "id" => "acc_dup", "institution" => "ing", "currency" => "EUR",
            "name" => "Tarjeta Crédito", "balance" => { "current" => "-1250.00", "available" => "750.00" }
          }],
          "transactions" => []
        }
      }
      configs = [{
        "members" => ["acc_dup"], "primary" => "ing", "windows" => {},
        "balance_override" => "0.00"
      }]
      result = ConsolidatedReshape.call(
        canonicals_by_profile: cs, aliases: [], group_configs: configs
      )
      acc = result.envelope["accounts"].first
      assert_equal "0.00", acc["balance"]
      refute acc.key?("available-balance"),
        "available-balance must be suppressed when override is in effect"
      assert_equal "0.00", acc["extra"]["balance_override"]
    end

    def test_balance_override_absent_falls_back_to_primary_balance
      cs = {
        "ing" => {
          "accounts" => [{
            "id" => "acc_normal", "institution" => "ing", "currency" => "EUR",
            "name" => "Cuenta", "balance" => { "current" => "100.00" }
          }],
          "transactions" => []
        }
      }
      result = ConsolidatedReshape.call(
        canonicals_by_profile: cs, aliases: [], group_configs: []
      )
      acc = result.envelope["accounts"].first
      assert_equal "100.00", acc["balance"]
      refute acc["extra"].key?("balance_override")
    end

    def test_forwards_canonical_type_to_extra_account_type
      cs = {
        "ing" => {
          "accounts" => [{
            "id" => "acc_card", "institution" => "ing", "currency" => "EUR",
            "name" => "Tarjeta Crédito", "type" => "credit_card",
            "balance" => { "current" => "-150.00" }
          }],
          "transactions" => []
        }
      }
      result = ConsolidatedReshape.call(
        canonicals_by_profile: cs, aliases: [], group_configs: []
      )
      acc = result.envelope["accounts"].first
      assert_equal "credit_card", acc["extra"]["account-type"]
    end

    def test_omits_account_type_when_canonical_lacks_it
      cs = {
        "ing" => {
          "accounts" => [{
            "id" => "acc_x", "institution" => "ing", "currency" => "EUR",
            "name" => "Mystery", "balance" => { "current" => "10.00" }
          }],
          "transactions" => []
        }
      }
      result = ConsolidatedReshape.call(
        canonicals_by_profile: cs, aliases: [], group_configs: []
      )
      acc = result.envelope["accounts"].first
      refute acc["extra"].key?("account-type")
    end

    def test_account_id_uses_primary_acc_hex
      configs = [{
        "members" => ["acc_match"], "primary" => "ing", "windows" => {}
      }]
      result = ConsolidatedReshape.call(
        canonicals_by_profile: canonicals, aliases: [], group_configs: configs
      )
      acc = result.envelope["accounts"].first
      assert_equal "acc_match", acc["id"]
      assert_equal "ing", acc["extra"]["consolidated_primary_source"]
    end

    # ── store ───────────────────────────────────────────────

    # ── per-group preview (without persisting) ───────────────

    def test_preview_group_returns_bucket_stats_and_estimated_emit_count
      cs = canonicals
      preview = ConsolidatedReshape.preview_group(
        canonicals_by_profile: cs,
        aliases:               [],
        members:               ["acc_match"],
        primary_pk:            "ing",
        windows: {
          "ing"      => { "from" => "2025-01-01", "to" => nil },
          "fintonic" => { "from" => nil,         "to" => "2024-12-31" }
        }
      )
      refute_nil preview
      assert_equal "ing", preview.primary_pk
      # Non-overlapping windows: fintonic supplies 2 txns (2024-12 and
      # 2023), ING supplies 3 (all 2025+); no buckets collide.
      stats = preview.bucket_stats
      assert_equal 0, stats["matched_collapsed"]
      assert_equal 0, stats["primary_surplus_kept"]
      assert preview.estimated_emit_count >= 5
      ing_src = preview.sources.find { |s| s["profile_key"] == "ing" }
      fin_src = preview.sources.find { |s| s["profile_key"] == "fintonic" }
      assert_equal 3, ing_src["in_window"]
      assert_equal 2, fin_src["in_window"]
      assert_equal 1, fin_src["out_of_window"], "the txn_fin_overlap (2025-06-15) is out of fintonic's window"
    end

    def test_preview_group_surfaces_collisions_in_overlap
      cs = canonicals
      preview = ConsolidatedReshape.preview_group(
        canonicals_by_profile: cs,
        aliases:               [],
        members:               ["acc_match"],
        primary_pk:            "ing",
        windows: {
          "ing"      => { "from" => "2025-01-01", "to" => nil },
          "fintonic" => { "from" => "2025-01-01", "to" => nil }
        }
      )
      # Both windows include 2025-06-15 where each side has a
      # matching (date, amount, currency) signature.
      assert_operator preview.bucket_stats["matched_collapsed"], :>=, 1
    end

    def test_preview_group_returns_nil_for_unknown_members
      preview = ConsolidatedReshape.preview_group(
        canonicals_by_profile: canonicals,
        aliases:               [],
        members:               ["acc_does_not_exist"],
        primary_pk:            nil,
        windows:               {}
      )
      assert_nil preview
    end

    # ── store ───────────────────────────────────────────────

    def test_groups_store_round_trips_via_upsert
      Dir.mktmpdir do |root|
        store = ConsolidationGroupsStore.new(root: root)
        assert_empty store.list

        store.upsert({
          "members" => ["acc_aaaaaaaaaaaaaaaa"],
          "primary" => "ing",
          "windows" => {
            "ing" => { "from" => "2025-01-01", "to" => nil }
          }
        })
        assert_equal 1, store.list.size

        store.upsert({
          "members" => ["acc_aaaaaaaaaaaaaaaa"],
          "primary" => "ing",
          "windows" => {
            "ing"      => { "from" => "2025-06-01", "to" => nil },
            "fintonic" => { "from" => nil, "to" => "2025-05-31" }
          }
        })
        all = store.list
        assert_equal 1, all.size, "upsert replaces by member set, not appends"
        assert_equal "2025-06-01", all.first["windows"]["ing"]["from"]
      end
    end

    def test_groups_store_rejects_invalid_dates
      Dir.mktmpdir do |root|
        store = ConsolidationGroupsStore.new(root: root)
        assert_raises(ArgumentError) do
          store.upsert({
            "members" => ["acc_aaaaaaaaaaaaaaaa"],
            "windows" => { "ing" => { "from" => "2025/01/01", "to" => nil } }
          })
        end
        assert_raises(ArgumentError) do
          store.upsert({
            "members" => ["acc_aaaaaaaaaaaaaaaa"],
            "windows" => { "ing" => { "from" => "2025-12-01", "to" => "2025-01-01" } }
          })
        end
      end
    end

    def test_groups_store_find_by_members
      Dir.mktmpdir do |root|
        store = ConsolidationGroupsStore.new(root: root)
        store.upsert({
          "members" => ["acc_bbbbbbbbbbbbbbbb", "acc_aaaaaaaaaaaaaaaa"],
          "primary" => "ing", "windows" => {}
        })
        # find should work regardless of input order.
        f1 = store.find_by_members(["acc_aaaaaaaaaaaaaaaa", "acc_bbbbbbbbbbbbbbbb"])
        f2 = store.find_by_members(["acc_bbbbbbbbbbbbbbbb", "acc_aaaaaaaaaaaaaaaa"])
        refute_nil f1
        assert_equal f1, f2
      end
    end

    # ── extra.bank_movement_id ──────────────────────────────

    def test_emits_bank_movement_id_from_primary_source_id
      # Inject source_ids on the canonical txns. The primary (ING, via
      # IBAN tiebreaker) contributes all three, so each emitted SimpleFIN
      # transaction must carry ING's source_id verbatim in
      # extra.bank_movement_id.
      cs = canonicals
      cs["ing"]["transactions"].each_with_index { |t, i| t["source_id"] = "ing-mv-#{i}" }
      cs["fintonic"]["transactions"].each_with_index { |t, i| t["source_id"] = "fin-mv-#{i}" }

      result = ConsolidatedReshape.call(
        canonicals_by_profile: cs, aliases: [], group_configs: []
      )
      txs = result.envelope["accounts"].first["transactions"]
      ing_emitted = txs.select { |t| t["id"].start_with?("txn_ing_") }
      assert_equal 3, ing_emitted.size
      ing_emitted.each do |t|
        bid = t.dig("extra", "bank_movement_id")
        assert_kind_of String, bid, "every primary-source txn must carry extra.bank_movement_id"
        assert bid.start_with?("ing-mv-"),
          "bank_movement_id must come from the source whose canonical id was emitted (got #{bid.inspect})"
      end
    end

    def test_bank_movement_id_omitted_when_source_id_blank_consolidated
      cs = canonicals
      cs["ing"]["transactions"].each { |t| t["source_id"] = nil }
      result = ConsolidatedReshape.call(
        canonicals_by_profile: cs, aliases: [], group_configs: []
      )
      txs = result.envelope["accounts"].first["transactions"]
      txs.each do |t|
        refute t.dig("extra")&.key?("bank_movement_id"),
          "blank source_id must not produce a bank_movement_id key"
      end
    end
  end
end
