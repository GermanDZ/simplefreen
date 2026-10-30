# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "json"
require "simplefreen"

module Simplefreen
  class HistoryStoreTest < Minitest::Test
    def setup
      @root = Dir.mktmpdir("simplefin-history-test-")
      Paths.ensure_layout!(@root)
      @store = HistoryStore.new(root: @root)
    end

    def teardown
      FileUtils.rm_rf(@root)
    end

    # ── Construction & path layout ──────────────────────────

    def test_path_under_history_dir
      assert_equal File.join(@root, "history", "ING", "history.json"),
        @store.path_for("ING")
    end

    def test_path_rejects_path_traversal
      assert_raises(ArgumentError) { @store.path_for("../etc") }
      assert_raises(ArgumentError) { @store.read("../etc") }
    end

    def test_read_returns_nil_for_unknown_profile
      assert_nil @store.read("never_synced")
    end

    def test_last_tx_date_nil_when_no_history
      assert_nil @store.last_tx_date("never_synced")
    end

    # ── First merge from empty ──────────────────────────────

    def test_first_merge_creates_history_with_all_txns
      payload = build_payload(transactions: [
        tx(id: "txn_a", date: "2026-05-01", amount: "-10.00", status: "posted"),
        tx(id: "txn_b", date: "2026-05-02", amount: "-20.00", status: "posted")
      ])
      result = @store.merge_run!("ING", run_id: "run_1", payload: payload)
      assert_equal "1", result["schema_version"]
      assert_equal "ING", result["profile_key"]
      assert_equal "run_1", result["last_run_id"]
      assert_equal 2, result["transactions"].size
      assert result["created_at"]
      assert result["updated_at"]
    end

    def test_first_merge_persists_to_disk
      @store.merge_run!("ING", run_id: "run_1", payload: build_payload(transactions: [tx(id: "txn_a")]))
      assert File.exist?(@store.path_for("ING"))
      reread = @store.read("ING")
      assert_equal 1, reread["transactions"].size
    end

    # ── Dedup / idempotency ────────────────────────────────

    def test_idempotent_remerge_of_same_run
      payload = build_payload(transactions: [
        tx(id: "txn_a", date: "2026-05-01"),
        tx(id: "txn_b", date: "2026-05-02")
      ])
      @store.merge_run!("ING", run_id: "run_1", payload: payload)
      @store.merge_run!("ING", run_id: "run_1", payload: payload)
      result = @store.read("ING")
      assert_equal 2, result["transactions"].size
    end

    def test_overlapping_runs_union_dedup
      r1 = build_payload(transactions: [
        tx(id: "txn_a", date: "2026-05-01"),
        tx(id: "txn_b", date: "2026-05-02")
      ])
      r2 = build_payload(transactions: [
        tx(id: "txn_b", date: "2026-05-02"),
        tx(id: "txn_c", date: "2026-05-03")
      ])
      @store.merge_run!("ING", run_id: "run_1", payload: r1)
      @store.merge_run!("ING", run_id: "run_2", payload: r2)
      ids = @store.read("ING")["transactions"].map { |t| t["id"] }.sort
      assert_equal %w[txn_a txn_b txn_c], ids
    end

    def test_tx_run_index_tracks_contributing_run
      @store.merge_run!("ING", run_id: "run_1",
        payload: build_payload(transactions: [tx(id: "txn_a"), tx(id: "txn_b")]))
      @store.merge_run!("ING", run_id: "run_2",
        payload: build_payload(transactions: [tx(id: "txn_c")]))
      idx = @store.read("ING")["tx_run_index"]
      assert_equal "run_1", idx["txn_a"]
      assert_equal "run_1", idx["txn_b"]
      assert_equal "run_2", idx["txn_c"]
    end

    # ── Status precedence (the load-bearing rule) ──────────

    def test_pending_to_posted_promotion
      r1 = build_payload(transactions: [
        tx(id: "txn_a", date: "2026-05-01", status: "pending", amount: "-10.00")
      ])
      r2 = build_payload(transactions: [
        tx(id: "txn_a", date: "2026-05-01", status: "posted", amount: "-10.00")
      ])
      @store.merge_run!("ING", run_id: "run_1", payload: r1)
      @store.merge_run!("ING", run_id: "run_2", payload: r2)
      tx = @store.read("ING")["transactions"].find { |t| t["id"] == "txn_a" }
      assert_equal "posted", tx["status"]
      assert_equal "run_2", @store.read("ING")["tx_run_index"]["txn_a"]
    end

    def test_pending_does_not_regress_posted
      # A backfill run (run_2) arrives after a forward-only run (run_1)
      # and tries to revive a "pending" version of an already-posted txn.
      # The posted version must stick.
      r1 = build_payload(transactions: [
        tx(id: "txn_a", status: "posted", amount: "-10.00")
      ])
      r2 = build_payload(transactions: [
        tx(id: "txn_a", status: "pending", amount: "-10.00")
      ])
      @store.merge_run!("ING", run_id: "run_1", payload: r1)
      @store.merge_run!("ING", run_id: "run_2", payload: r2)
      tx = @store.read("ING")["transactions"].find { |t| t["id"] == "txn_a" }
      assert_equal "posted", tx["status"]
      assert_equal "run_1", @store.read("ING")["tx_run_index"]["txn_a"]
    end

    def test_same_status_new_run_replaces_existing
      # Bank amends the description on an already-posted txn — the newer
      # run's version should win.
      r1 = build_payload(transactions: [
        tx(id: "txn_a", status: "posted", amount: "-10.00", description: "OLD")
      ])
      r2 = build_payload(transactions: [
        tx(id: "txn_a", status: "posted", amount: "-10.00", description: "NEW")
      ])
      @store.merge_run!("ING", run_id: "run_1", payload: r1)
      @store.merge_run!("ING", run_id: "run_2", payload: r2)
      tx = @store.read("ING")["transactions"].find { |t| t["id"] == "txn_a" }
      assert_equal "NEW", tx["description"]
    end

    # ── Snapshot fields ────────────────────────────────────

    def test_accounts_replaced_wholesale_from_latest_run
      r1 = build_payload(
        transactions: [tx(id: "txn_a")],
        accounts: [{ "id" => "acc_1", "balance" => "100.00" }]
      )
      r2 = build_payload(
        transactions: [tx(id: "txn_b")],
        accounts: [{ "id" => "acc_1", "balance" => "200.00" }]
      )
      @store.merge_run!("ING", run_id: "run_1", payload: r1)
      @store.merge_run!("ING", run_id: "run_2", payload: r2)
      accounts = @store.read("ING")["accounts"]
      assert_equal 1, accounts.size
      assert_equal "200.00", accounts.first["balance"]
    end

    # ── Helpers / scheduler integration points ─────────────

    def test_last_tx_date_returns_max_date
      payload = build_payload(transactions: [
        tx(id: "txn_a", date: "2026-04-15"),
        tx(id: "txn_b", date: "2026-05-12"),
        tx(id: "txn_c", date: "2026-03-01")
      ])
      @store.merge_run!("ING", run_id: "run_1", payload: payload)
      assert_equal "2026-05-12", @store.last_tx_date("ING")
    end

    def test_last_tx_date_ignores_txns_without_date
      payload = build_payload(transactions: [
        tx(id: "txn_a", date: "2026-04-15"),
        tx(id: "txn_b", date: nil)
      ])
      @store.merge_run!("ING", run_id: "run_1", payload: payload)
      assert_equal "2026-04-15", @store.last_tx_date("ING")
    end

    # ── Robustness ─────────────────────────────────────────

    def test_merge_rejects_non_hash_payload
      assert_raises(ArgumentError) { @store.merge_run!("ING", run_id: "r", payload: "nope") }
    end

    def test_merge_rejects_bad_profile_key
      assert_raises(ArgumentError) do
        @store.merge_run!("../etc", run_id: "r", payload: build_payload(transactions: []))
      end
    end

    def test_merge_rejects_bad_run_id
      assert_raises(ArgumentError) do
        @store.merge_run!("ING", run_id: "../etc", payload: build_payload(transactions: []))
      end
    end

    def test_merge_skips_txns_with_blank_id
      payload = build_payload(transactions: [
        tx(id: "txn_a"),
        { "id" => "", "date" => "2026-05-01" },
        { "id" => nil, "date" => "2026-05-01" }
      ])
      @store.merge_run!("ING", run_id: "run_1", payload: payload)
      ids = @store.read("ING")["transactions"].map { |t| t["id"] }
      assert_equal ["txn_a"], ids
    end

    # ── Reset & rebuild ────────────────────────────────────

    def test_delete_removes_history
      @store.merge_run!("ING", run_id: "run_1",
        payload: build_payload(transactions: [tx(id: "txn_a")]))
      assert @store.exists?("ING")
      @store.delete!("ING")
      refute @store.exists?("ING")
      assert_nil @store.read("ING")
    end

    def test_delete_on_missing_is_noop
      @store.delete!("never_existed")  # must not raise
    end

    def test_rebuild_from_runs_replays_canonicals_in_mtime_order
      runs_dir = File.join(Paths.runs_dir(@root), "ING")
      FileUtils.mkdir_p(runs_dir, mode: 0o700)

      # Write three canonicals in chronological order. The middle one
      # promotes txn_a from pending to posted; the last adds a new txn.
      write_canonical(runs_dir, "run_1", transactions: [
        tx(id: "txn_a", status: "pending"),
        tx(id: "txn_b", status: "posted")
      ], mtime: Time.now - 300)
      write_canonical(runs_dir, "run_2", transactions: [
        tx(id: "txn_a", status: "posted")
      ], mtime: Time.now - 200)
      write_canonical(runs_dir, "run_3", transactions: [
        tx(id: "txn_c", status: "posted")
      ], mtime: Time.now - 100)

      result = @store.rebuild_from_runs!("ING")
      ids = result["transactions"].map { |t| t["id"] }.sort
      assert_equal %w[txn_a txn_b txn_c], ids
      tx_a = result["transactions"].find { |t| t["id"] == "txn_a" }
      assert_equal "posted", tx_a["status"]
      assert_equal "run_3", result["last_run_id"]
    end

    def test_rebuild_returns_nil_when_no_canonicals
      assert_nil @store.rebuild_from_runs!("ING")
    end

    def test_rebuild_replaces_any_existing_history
      # Seed history with stale data; rebuild should drop it.
      @store.merge_run!("ING", run_id: "stale",
        payload: build_payload(transactions: [tx(id: "txn_stale")]))

      runs_dir = File.join(Paths.runs_dir(@root), "ING")
      FileUtils.mkdir_p(runs_dir, mode: 0o700)
      write_canonical(runs_dir, "run_1", transactions: [tx(id: "txn_fresh")])

      @store.rebuild_from_runs!("ING")
      ids = @store.read("ING")["transactions"].map { |t| t["id"] }
      assert_equal ["txn_fresh"], ids
    end

    # ── Stats helper ───────────────────────────────────────

    def test_stats_returns_nil_when_no_history
      assert_nil @store.stats("never_synced")
    end

    def test_stats_after_merge_returns_expected_hash
      payload = build_payload(transactions: [
        tx(id: "txn_a", date: "2026-05-01"),
        tx(id: "txn_b", date: "2026-05-12"),
        tx(id: "txn_c", date: "2026-04-15")
      ])
      @store.merge_run!("ING", run_id: "run_42", payload: payload)
      stats = @store.stats("ING")
      assert_equal 3, stats["txn_count"]
      assert_equal "2026-05-12", stats["last_tx_date"]
      assert_equal "run_42", stats["last_run_id"]
      assert stats["file_size_bytes"].is_a?(Integer)
      assert stats["file_size_bytes"] > 0
      assert stats["updated_at"]
      assert stats["created_at"]
    end

    # ── Multi-profile isolation ────────────────────────────

    def test_profiles_are_isolated
      @store.merge_run!("ING", run_id: "r1",
        payload: build_payload(transactions: [tx(id: "txn_a")]))
      @store.merge_run!("REVOLUT", run_id: "r1",
        payload: build_payload(transactions: [tx(id: "txn_b")]))
      assert_equal ["txn_a"], @store.read("ING")["transactions"].map { |t| t["id"] }
      assert_equal ["txn_b"], @store.read("REVOLUT")["transactions"].map { |t| t["id"] }
    end

    # ── Cross-fetch supersession (ING seq-renumber) ────────

    def test_renumber_with_enriched_description_promotes_in_place
      prov = tx(id: "txn_prov", date: "2026-05-24", amount: "-120.00", description: "ACME SPORTS")
               .merge("source_id" => "v2-seq:card:9000000001")
      @store.merge_run!("ING", run_id: "r1", payload: build_payload(transactions: [prov]))

      conf = tx(id: "txn_conf", date: "2026-05-24", amount: "-120.00", description: "ACME SPORTS STORE CITY")
               .merge("source_id" => "v2-seq:card:600000001")
      result = @store.merge_run!("ING", run_id: "r2", payload: build_payload(transactions: [conf]))

      assert_equal 1, result["transactions"].size, "renumber must not duplicate"
      t = result["transactions"].first
      assert_equal "txn_prov", t["id"], "keeps provisional id → stable downstream external_id"
      assert_equal "ACME SPORTS STORE CITY", t["description"], "carries confirmed content"
      assert_equal "v2-seq:card:600000001", t["source_id"]
      assert_equal "r2", result["tx_run_index"]["txn_prov"]
      refute result["tx_run_index"].key?("txn_conf"), "renumbered id is never inserted"
      trail = t.dig("metadata", "superseded")
      assert_equal ["txn_prov"], trail.map { |s| s["id"] }
      assert_equal "v2-seq:card:9000000001", trail[0]["source_id"], "records the provisional for audit"
    end

    def test_renumber_with_identical_description_promotes_in_place
      @store.merge_run!("ING", run_id: "r1", payload: build_payload(transactions: [
        tx(id: "txn_prov", date: "2026-05-23", amount: "-0.99", description: "APPSTORE.EXAMPLE/BILL")
      ]))
      result = @store.merge_run!("ING", run_id: "r2", payload: build_payload(transactions: [
        tx(id: "txn_conf", date: "2026-05-23", amount: "-0.99", description: "APPSTORE.EXAMPLE/BILL")
      ]))
      assert_equal ["txn_prov"], result["transactions"].map { |t| t["id"] },
        "identical-description renumber (no prefix change) still collapses"
    end

    def test_renumber_with_date_shift_within_window_promotes
      @store.merge_run!("ING", run_id: "r1", payload: build_payload(transactions: [
        tx(id: "txn_prov", date: "2026-05-23", amount: "-5.99", description: "ACME SUBSCRIPTION")
      ]))
      result = @store.merge_run!("ING", run_id: "r2", payload: build_payload(transactions: [
        tx(id: "txn_conf", date: "2026-05-25", amount: "-5.99", description: "ACME SUBSCRIPTION CITY")
      ]))
      assert_equal ["txn_prov"], result["transactions"].map { |t| t["id"] }
    end

    def test_renumber_beyond_date_window_is_not_promoted
      @store.merge_run!("ING", run_id: "r1", payload: build_payload(transactions: [
        tx(id: "txn_prov", date: "2026-05-10", amount: "-5.99", description: "ACME SUBSCRIPTION")
      ]))
      result = @store.merge_run!("ING", run_id: "r2", payload: build_payload(transactions: [
        tx(id: "txn_conf", date: "2026-05-25", amount: "-5.99", description: "ACME SUBSCRIPTION CITY")
      ]))
      assert_equal %w[txn_conf txn_prov], result["transactions"].map { |t| t["id"] }.sort
    end

    def test_same_amount_different_merchant_is_not_promoted
      # The subscription/app-store false-positive: same amount, near date, but no
      # description overlap → must stay two separate transactions.
      @store.merge_run!("ING", run_id: "r1", payload: build_payload(transactions: [
        tx(id: "txn_acme_sub", date: "2026-01-23", amount: "-5.99", description: "ACME SUBSCRIPTION")
      ]))
      result = @store.merge_run!("ING", run_id: "r2", payload: build_payload(transactions: [
        tx(id: "txn_appstore", date: "2026-01-25", amount: "-5.99", description: "APPSTORE.EXAMPLE/BILL")
      ]))
      assert_equal %w[txn_acme_sub txn_appstore], result["transactions"].map { |t| t["id"] }.sort
    end

    def test_identical_twins_both_live_are_kept
      # Two genuinely distinct identical charges that BOTH stay in the feed
      # must never collapse — the "vanished from this run" guard protects them.
      both = [
        tx(id: "txn_x", date: "2026-05-20", amount: "-42.50", description: "CITY HALL FEE"),
        tx(id: "txn_y", date: "2026-05-20", amount: "-42.50", description: "CITY HALL FEE")
      ]
      @store.merge_run!("ING", run_id: "r1", payload: build_payload(transactions: both))
      result = @store.merge_run!("ING", run_id: "r2", payload: build_payload(transactions: both))
      assert_equal %w[txn_x txn_y], result["transactions"].map { |t| t["id"] }.sort
    end

    def test_new_identical_charge_while_twins_live_is_kept_separate
      both = [
        tx(id: "txn_x", date: "2026-05-20", amount: "-42.50", description: "CITY HALL FEE"),
        tx(id: "txn_y", date: "2026-05-20", amount: "-42.50", description: "CITY HALL FEE")
      ]
      @store.merge_run!("ING", run_id: "r1", payload: build_payload(transactions: both))
      result = @store.merge_run!("ING", run_id: "r2", payload: build_payload(transactions: both + [
        tx(id: "txn_z", date: "2026-05-21", amount: "-42.50", description: "CITY HALL FEE")
      ]))
      assert_equal 3, result["transactions"].size,
        "a real third identical charge (existing twins still live) is not absorbed"
    end

    def test_ambiguous_multiple_provisionals_are_not_promoted
      @store.merge_run!("ING", run_id: "r1", payload: build_payload(transactions: [
        tx(id: "txn_p1", date: "2026-05-20", amount: "-15.00", description: "MERCADONA MADRID"),
        tx(id: "txn_p2", date: "2026-05-20", amount: "-15.00", description: "MERCADONA MADRID")
      ]))
      result = @store.merge_run!("ING", run_id: "r2", payload: build_payload(transactions: [
        tx(id: "txn_conf", date: "2026-05-20", amount: "-15.00", description: "MERCADONA MADRID CENTRO")
      ]))
      assert_equal %w[txn_conf txn_p1 txn_p2], result["transactions"].map { |t| t["id"] }.sort,
        "ambiguous (>1 provisional match) → refuse to merge, keep all"
    end

    def test_renumber_does_not_cross_accounts
      @store.merge_run!("ING", run_id: "r1", payload: build_payload(transactions: [
        tx(id: "txn_prov", account_id: "acc_A", date: "2026-05-24", amount: "-30.00", description: "GLOVO PEDIDO")
      ]))
      result = @store.merge_run!("ING", run_id: "r2", payload: build_payload(transactions: [
        tx(id: "txn_conf", account_id: "acc_B", date: "2026-05-24", amount: "-30.00", description: "GLOVO PEDIDO BARCELONA")
      ]))
      assert_equal %w[txn_conf txn_prov], result["transactions"].map { |t| t["id"] }.sort,
        "supersession is scoped per account"
    end

    private

    def build_payload(transactions:, accounts: [], liabilities: [], investments: [])
      {
        "schema_version" => "freentonic.canonical.v1",
        "accounts"       => accounts,
        "transactions"   => transactions,
        "liabilities"    => liabilities,
        "investments"    => investments
      }
    end

    def tx(id:, date: "2026-05-01", amount: "-10.00", status: "posted",
           account_id: "acc_1", description: "X")
      {
        "id"          => id,
        "account_id"  => account_id,
        "date"        => date,
        "amount"      => amount,
        "currency"    => "EUR",
        "status"      => status,
        "description" => description
      }
    end

    def write_canonical(runs_dir, run_id, transactions:, mtime: nil)
      path = File.join(runs_dir, "#{run_id}.canonical.json")
      File.write(path, JSON.generate(build_payload(transactions: transactions)))
      File.utime(mtime, mtime, path) if mtime
      path
    end
  end
end
