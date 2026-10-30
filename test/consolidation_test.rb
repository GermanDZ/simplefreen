# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "json"

module Simplefreen
  class ConsolidationTest < Minitest::Test
    # Pretend canonical envelopes — minimal but realistic shape. Two
    # profiles see the same physical account (acc_match) under different
    # source_ids; one profile has a private-only account.
    def canonicals
      {
        "ing" => {
          "schema_version" => "0.1",
          "accounts" => [
            { "id" => "acc_match", "source_id" => "___V1ID___xyz", "institution" => "ing",
              "name" => "Main Account", "iban" => "ES0014650000000000001234", "currency" => "EUR",
              "balance" => { "current" => "1500.00" } },
            { "id" => "acc_ing_only", "source_id" => "___V1ID___abc", "institution" => "ing",
              "name" => "Cuenta de valores", "iban" => nil, "currency" => "EUR",
              "balance" => { "current" => "0.00" } }
          ],
          "transactions" => [
            { "account_id" => "acc_match",     "id" => "txn_1", "amount" => "-10.00", "date" => "2026-04-01" },
            { "account_id" => "acc_match",     "id" => "txn_2", "amount" => "-20.00", "date" => "2026-04-02" },
            { "account_id" => "acc_ing_only", "id" => "txn_3", "amount" => "5.00",   "date" => "2026-04-03" }
          ]
        },
        "fintonic" => {
          "schema_version" => "0.1",
          "accounts" => [
            { "id" => "acc_match", "source_id" => "1465:1234", "institution" => "fintonic",
              "name" => "Bank 1465 ACCOUNT #1234", "iban" => nil, "currency" => "EUR",
              "balance" => { "current" => "1500.00" } },
            { "id" => "acc_fin_alias_target", "source_id" => "2103:opaque-hash",
              "institution" => "fintonic", "name" => "Bank 2103 ACCOUNT #hash",
              "iban" => nil, "currency" => "EUR", "balance" => { "current" => "1800.00" } }
          ],
          "transactions" => [
            { "account_id" => "acc_match", "id" => "txn_a", "amount" => "-10.00", "date" => "2026-04-01" }
          ]
        },
        "unicaja" => {
          "schema_version" => "0.1",
          "accounts" => [
            { "id" => "acc_uni_alias_source", "source_id" => "cuenta:004", "institution" => "unicaja",
              "name" => "Principal", "iban" => "ES0021030000000000005678", "currency" => "EUR",
              "balance" => { "current" => "1800.00" } }
          ],
          "transactions" => []
        }
      }
    end

    def test_auto_links_same_account_id_across_profiles
      groups = Consolidation.build_groups(canonicals)
      multi  = groups.select { |g| g.sources.size > 1 }
      assert_equal 1, multi.size, "exactly one auto-linked group expected"

      g = multi.first
      assert_equal "acc_match", g.id
      assert_equal :portable_ref, g.linked_via
      assert_equal %w[fintonic ing], g.sources.map(&:profile_key).sort
    end

    def test_singleton_groups_for_unmatched_accounts
      groups = Consolidation.build_groups(canonicals)
      ids = groups.map(&:id)
      assert_includes ids, "acc_ing_only"
      assert_includes ids, "acc_fin_alias_target"
      assert_includes ids, "acc_uni_alias_source"

      singletons = groups.select { |g| g.sources.size == 1 }
      singletons.each { |g| assert_equal :singleton, g.linked_via }
    end

    def test_manual_alias_links_two_distinct_account_ids
      aliases = [
        { "members" => ["acc_uni_alias_source", "acc_fin_alias_target"], "note" => "Unicaja↔Fintonic" }
      ]
      groups = Consolidation.build_groups(canonicals, aliases: aliases)
      group  = groups.find { |g| g.members.include?("acc_uni_alias_source") }
      refute_nil group
      assert_equal :alias, group.linked_via
      assert_equal %w[acc_fin_alias_target acc_uni_alias_source], group.members.sort
      assert_equal %w[fintonic unicaja], group.sources.map(&:profile_key).sort
    end

    def test_suggested_primary_prefers_iban_holder
      groups = Consolidation.build_groups(canonicals)
      g = groups.find { |gg| gg.id == "acc_match" }
      refute_nil g
      assert_equal "ing", g.suggested_primary.profile_key,
        "ING (with IBAN) should beat Fintonic (no IBAN) as suggested primary"
    end

    def test_pick_primary_deprioritizes_aggregator_when_no_iban_either_side
      # Two card accounts, neither has IBAN. ING is direct, Fintonic
      # is aggregator (institution: "fintonic"). Even though Fintonic
      # has more txns (typical aggregator pattern), ING should win as
      # suggested primary because aggregators get deprioritized in
      # the default heuristic.
      cs = {
        "ing" => {
          "accounts" => [{ "id" => "acc_card1", "institution" => "ing",
                           "name" => "Tarjeta Crédito", "currency" => "EUR" }],
          "transactions" => 5.times.map { |i|
            { "account_id" => "acc_card1", "id" => "txn_ing_#{i}",
              "date" => "2026-04-0#{i+1}", "amount" => "-10.00", "currency" => "EUR" }
          }
        },
        "fintonic" => {
          "accounts" => [{ "id" => "acc_card1", "institution" => "fintonic",
                           "name" => "Bank 1465 CREDITCARD", "currency" => "EUR" }],
          "transactions" => 50.times.map { |i|
            { "account_id" => "acc_card1", "id" => "txn_fin_#{i}",
              "date" => "2026-0#{(i / 30) + 1}-0#{(i % 28) + 1}", "amount" => "-10.00", "currency" => "EUR" }
          }
        }
      }
      groups = Consolidation.build_groups(cs)
      group = groups.find { |g| g.id == "acc_card1" }
      refute_nil group
      assert_equal "ing", group.suggested_primary.profile_key,
        "ING (direct) must beat Fintonic (aggregator) as primary even when Fintonic has more txns"
    end

    def test_pick_primary_iban_still_wins_over_aggregator_check
      # If one side has an IBAN, it always wins, even if it's an
      # aggregator — the IBAN signal is rare enough that it dominates.
      # (No real-world case for this today, but the heuristic ordering
      # should be deterministic.)
      cs = {
        "fakeagg" => {
          "accounts" => [{ "id" => "acc_x", "institution" => "fintonic",
                           "name" => "Has IBAN somehow", "iban" => "ESxx", "currency" => "EUR" }],
          "transactions" => []
        },
        "ing" => {
          "accounts" => [{ "id" => "acc_x", "institution" => "ing",
                           "name" => "No IBAN", "currency" => "EUR" }],
          "transactions" => []
        }
      }
      groups = Consolidation.build_groups(cs)
      group = groups.find { |g| g.id == "acc_x" }
      assert_equal "fakeagg", group.suggested_primary.profile_key,
        "IBAN-bearer wins regardless of aggregator status"
    end

    def test_alias_can_chain_three_accounts
      aliases = [
        { "members" => ["acc_match", "acc_ing_only", "acc_fin_alias_target"], "note" => "three-way" }
      ]
      groups = Consolidation.build_groups(canonicals, aliases: aliases)
      g = groups.find { |gg| gg.members.include?("acc_match") }
      refute_nil g
      assert_equal 3, g.members.size
      assert_equal :alias, g.linked_via
    end

    def test_dangling_alias_member_surfaces_as_dangling_group
      aliases = [
        { "members" => ["acc_does_not_exist", "acc_neither_does_this"], "note" => "stale" }
      ]
      groups = Consolidation.build_groups(canonicals, aliases: aliases)
      dangling = groups.find { |g| g.linked_via == :dangling }
      refute_nil dangling, "dangling alias should produce a :dangling group"
      assert_equal 0, dangling.sources.size
      assert_equal 2, dangling.members.size
    end

    # Property: pick_primary must be deterministic across syncs even
    # when a source's transaction count fluctuates. The hazard: any
    # downstream that dedupes by SimpleFIN `txn_id` (e.g. Sure
    # Finances) sees a fresh duplicate the moment the consolidated
    # primary flips, because each source emits its own canonical
    # `txn_<hex>` and ConsolidatedReshape uses the primary's id
    # verbatim.
    #
    # Setup: two direct-provider sources for the same physical account
    # via manual alias (neither has IBAN, neither is an aggregator —
    # the only place `-txn_count` is the deciding sort key). Counts
    # cross between the two snapshots.
    def test_pick_primary_stable_when_txn_count_flips_across_syncs
      build = ->(a_count, b_count) {
        {
          "bank_a" => {
            "schema_version" => "0.1",
            "accounts" => [{
              "id" => "acc_card_a", "institution" => "bank_a",
              "name" => "Card A", "iban" => nil, "currency" => "EUR",
              "balance" => { "current" => "-100.00" }
            }],
            "transactions" => a_count.times.map { |i|
              { "account_id" => "acc_card_a", "id" => "txn_a_#{i}",
                "amount" => "-1.00", "currency" => "EUR",
                "date" => "2026-04-#{format("%02d", i + 1)}",
                "raw_description" => "A#{i}" }
            }
          },
          "bank_b" => {
            "schema_version" => "0.1",
            "accounts" => [{
              "id" => "acc_card_b", "institution" => "bank_b",
              "name" => "Card B", "iban" => nil, "currency" => "EUR",
              "balance" => { "current" => "-100.00" }
            }],
            "transactions" => b_count.times.map { |i|
              { "account_id" => "acc_card_b", "id" => "txn_b_#{i}",
                "amount" => "-1.00", "currency" => "EUR",
                "date" => "2026-04-#{format("%02d", i + 1)}",
                "raw_description" => "B#{i}" }
            }
          }
        }
      }
      aliases = [{ "members" => ["acc_card_a", "acc_card_b"], "note" => "same physical card" }]

      sync_a = build.call(15, 10) # bank_a richer
      sync_b = build.call(8,  12) # bank_b richer (counts crossed)

      groups_a = Consolidation.build_groups(sync_a, aliases: aliases)
      groups_b = Consolidation.build_groups(sync_b, aliases: aliases)

      group_a = groups_a.find { |g| g.members.sort == %w[acc_card_a acc_card_b] }
      group_b = groups_b.find { |g| g.members.sort == %w[acc_card_a acc_card_b] }
      refute_nil group_a, "linked group must form via alias in sync A"
      refute_nil group_b, "linked group must form via alias in sync B"

      assert_equal group_a.suggested_primary.profile_key,
                   group_b.suggested_primary.profile_key,
        "pick_primary must not flip when transaction counts cross across syncs " \
        "(was #{group_a.suggested_primary.profile_key} in sync A, " \
        "#{group_b.suggested_primary.profile_key} in sync B)"
    end

    def test_txn_count_is_per_source
      groups = Consolidation.build_groups(canonicals)
      g = groups.find { |gg| gg.id == "acc_match" }
      ing_src = g.sources.find { |s| s.profile_key == "ing" }
      fin_src = g.sources.find { |s| s.profile_key == "fintonic" }
      assert_equal 2, ing_src.txn_count
      assert_equal 1, fin_src.txn_count
    end

    # ── store ───────────────────────────────────────────────

    def test_store_round_trips_aliases
      Dir.mktmpdir do |root|
        store = ConsolidationStore.new(root: root)
        assert_equal [], store.list

        written = store.replace([
          { "members" => ["acc_aaaaaaaaaaaaaaaa", "acc_bbbbbbbbbbbbbbbb"], "note" => "test" }
        ])
        assert_equal 1, written.size
        assert_equal %w[acc_aaaaaaaaaaaaaaaa acc_bbbbbbbbbbbbbbbb], written.first["members"]

        reloaded = ConsolidationStore.new(root: root).list
        assert_equal 1, reloaded.size
        assert_equal "test", reloaded.first["note"]
      end
    end

    def test_store_rejects_invalid_alias_shapes
      Dir.mktmpdir do |root|
        store = ConsolidationStore.new(root: root)

        assert_raises(ArgumentError) do
          store.replace([{ "members" => ["acc_aaaaaaaaaaaaaaaa"] }]) # only 1 member
        end

        assert_raises(ArgumentError) do
          store.replace([{ "members" => ["acc_aaaaaaaaaaaaaaaa", "not_a_canonical_id"] }])
        end

        assert_raises(ArgumentError) do
          store.replace([{ "note" => "no members at all" }])
        end

        # Verify nothing was written on the failed paths
        assert_equal [], store.list
      end
    end

    # ── suggestions ─────────────────────────────────────────

    # Pretend Unicaja and Fintonic see the same physical account under
    # *different* canonical acc_<hex> ids — exactly the situation we
    # have in production where Fintonic emits an opaque resourceId
    # hash for Unicaja accounts. The transaction streams overlap
    # nearly 1:1.
    def unmatched_pair_canonicals
      shared = [
        { "date" => "2026-04-01", "amount" => "-10.00", "currency" => "EUR" },
        { "date" => "2026-04-02", "amount" => "-20.00", "currency" => "EUR" },
        { "date" => "2026-04-03", "amount" => "100.00", "currency" => "EUR" },
        { "date" => "2026-04-04", "amount" => "-5.00",  "currency" => "EUR" }
      ]
      {
        "unicaja" => {
          "schema_version" => "0.1",
          "accounts" => [
            { "id" => "acc_uni_1", "source_id" => "cuenta:004", "institution" => "unicaja",
              "name" => "Principal", "iban" => "ES0021030000000000005678", "currency" => "EUR" }
          ],
          "transactions" => shared.each_with_index.map { |t, i|
            t.merge("id" => "txn_uni_#{i}", "account_id" => "acc_uni_1")
          }
        },
        "fintonic" => {
          "schema_version" => "0.1",
          "accounts" => [
            { "id" => "acc_fin_1", "source_id" => "2103:opaque", "institution" => "fintonic",
              "name" => "Bank 2103 ACCOUNT #opaque", "iban" => nil, "currency" => "EUR" }
          ],
          "transactions" => shared.each_with_index.map { |t, i|
            t.merge("id" => "txn_fin_#{i}", "account_id" => "acc_fin_1")
          }
        }
      }
    end

    def test_suggests_pair_with_full_overlap
      canonicals = unmatched_pair_canonicals
      groups     = Consolidation.build_groups(canonicals)
      suggs      = Consolidation.suggest_matches(canonicals, groups)
      assert_equal 1, suggs.size
      s = suggs.first
      # Profile pair order is deterministic (alphabetical by profile_key)
      # so the UI can render it consistently regardless of which canonical
      # was loaded first.
      assert_equal "fintonic", s.profile_a
      assert_equal "acc_fin_1", s.account_a["id"]
      assert_equal "unicaja",  s.profile_b
      assert_equal "acc_uni_1", s.account_b["id"]
      assert_equal 4, s.overlap
      assert_equal 4, s.a_total
      assert_equal 4, s.b_total
      assert_in_delta 1.0, s.confidence, 0.001
      assert_equal 3, s.samples.size, "samples capped at sample_size"
    end

    def test_does_not_suggest_already_linked_accounts
      # When ING and Fintonic both report acc_match (auto-linked),
      # the pair should NOT show up as a suggestion.
      groups = Consolidation.build_groups(canonicals)
      suggs  = Consolidation.suggest_matches(canonicals, groups)
      pairs  = suggs.map { |s| [s.account_a["id"], s.account_b["id"]].sort }
      refute_includes pairs, %w[acc_match acc_match]
    end

    def test_does_not_suggest_aliased_accounts
      aliases = [{ "members" => ["acc_uni_alias_source", "acc_fin_alias_target"] }]
      groups  = Consolidation.build_groups(canonicals, aliases: aliases)
      suggs   = Consolidation.suggest_matches(canonicals, groups)
      pairs = suggs.map { |s| [s.account_a["id"], s.account_b["id"]].sort }
      refute_includes pairs, %w[acc_fin_alias_target acc_uni_alias_source]
    end

    def test_skips_pairs_below_min_overlap
      # Only one shared (date, amount) — below the default min_overlap
      # of 3. Should produce no suggestions.
      cs = {
        "a" => {
          "accounts" => [{ "id" => "acc_a", "currency" => "EUR" }],
          "transactions" => [
            { "account_id" => "acc_a", "id" => "1", "date" => "2026-04-01", "amount" => "-10.00", "currency" => "EUR" },
            { "account_id" => "acc_a", "id" => "2", "date" => "2026-04-02", "amount" => "-99.00", "currency" => "EUR" }
          ]
        },
        "b" => {
          "accounts" => [{ "id" => "acc_b", "currency" => "EUR" }],
          "transactions" => [
            { "account_id" => "acc_b", "id" => "1", "date" => "2026-04-01", "amount" => "-10.00", "currency" => "EUR" },
            { "account_id" => "acc_b", "id" => "2", "date" => "2026-04-02", "amount" => "-77.00", "currency" => "EUR" }
          ]
        }
      }
      groups = Consolidation.build_groups(cs)
      assert_empty Consolidation.suggest_matches(cs, groups)
    end

    def test_skips_pairs_with_currency_mismatch
      cs = {
        "a" => {
          "accounts" => [{ "id" => "acc_a", "currency" => "EUR" }],
          "transactions" => 4.times.map { |i|
            { "account_id" => "acc_a", "id" => "a#{i}",
              "date" => "2026-04-0#{i+1}", "amount" => "-10.00", "currency" => "EUR" }
          }
        },
        "b" => {
          "accounts" => [{ "id" => "acc_b", "currency" => "USD" }],
          "transactions" => 4.times.map { |i|
            { "account_id" => "acc_b", "id" => "b#{i}",
              "date" => "2026-04-0#{i+1}", "amount" => "-10.00", "currency" => "USD" }
          }
        }
      }
      groups = Consolidation.build_groups(cs)
      assert_empty Consolidation.suggest_matches(cs, groups),
        "EUR-vs-USD txns with same date/amount must not match"
    end

    def test_min_overlap_can_be_lowered_via_kwarg
      cs = {
        "a" => {
          "accounts" => [{ "id" => "acc_a", "currency" => "EUR" }],
          "transactions" => [
            { "account_id" => "acc_a", "id" => "1", "date" => "2026-04-01", "amount" => "-10.00", "currency" => "EUR" }
          ]
        },
        "b" => {
          "accounts" => [{ "id" => "acc_b", "currency" => "EUR" }],
          "transactions" => [
            { "account_id" => "acc_b", "id" => "1", "date" => "2026-04-01", "amount" => "-10.00", "currency" => "EUR" }
          ]
        }
      }
      groups = Consolidation.build_groups(cs)
      assert_empty Consolidation.suggest_matches(cs, groups)
      relaxed = Consolidation.suggest_matches(cs, groups, min_overlap: 1)
      assert_equal 1, relaxed.size
    end

    def test_store_drops_duplicate_members_within_an_entry
      Dir.mktmpdir do |root|
        store = ConsolidationStore.new(root: root)
        written = store.replace([
          { "members" => ["acc_aaaaaaaaaaaaaaaa", "acc_aaaaaaaaaaaaaaaa", "acc_bbbbbbbbbbbbbbbb"] }
        ])
        assert_equal 2, written.first["members"].size
      end
    end
  end
end
