# frozen_string_literal: true

require_relative "test_helper"
require "simplefreen/reshape"

module Simplefreen
  class ReshapeTest < Minitest::Test
    # A minimal-but-realistic canonical envelope. Shape follows
    # `~/code/freentonic/docs/canonical-data-model.md`.
    def sample
      {
        "schema_version" => "0.1",
        "summary" => { "counts" => { "accounts" => 1, "transactions" => 2 } },
        "meta" => { "scraper_version" => "ing/0.2" },
        "accounts" => [
          {
            "id"          => "acc_a1b2c3d4e5f60718",
            "source_id"   => "12345",
            "institution" => "ing",
            "name"        => "Cuenta Naranja",
            "type"        => "checking",
            "currency"    => "EUR",
            "iban"        => "ES1234567890",
            "balance"     => {
              "current"   => "1234.56",
              "available" => "1234.56",
              "timestamp" => "2026-04-22T10:00:00Z"
            },
            "metadata" => {}
          }
        ],
        "transactions" => [
          {
            "id"          => "txn_1111111111111111",
            "source_id"   => "m1",
            "account_id"  => "acc_a1b2c3d4e5f60718",
            "date"        => "2026-04-21",
            "value_date"  => "2026-04-21",
            "amount"      => "-5.00",
            "currency"    => "EUR",
            "description" => "Coffee",
            "status"      => "posted",
            "merchant"    => nil,
            "metadata"    => {}
          },
          {
            "id"          => "txn_2222222222222222",
            "source_id"   => "m2",
            "account_id"  => "acc_a1b2c3d4e5f60718",
            "date"        => "2026-04-20",
            "value_date"  => "2026-04-20",
            "amount"      => "10.00",
            "currency"    => "EUR",
            "description" => "Refund",
            "status"      => "posted",
            "merchant"    => { "name" => "Acme Inc", "normalized" => true },
            "metadata"    => {}
          }
        ],
        "liabilities"  => [],
        "investments"  => []
      }
    end

    def test_reshape_produces_simplefin_envelope
      env = Reshape.call(sample)
      assert_equal 1, env["accounts"].size
      account = env["accounts"].first
      assert_equal "acc_a1b2c3d4e5f60718", account["id"]
      assert_equal "EUR", account["currency"]
      assert_equal "1234.56", account["balance"]
      assert_equal Time.parse("2026-04-22T10:00:00Z").to_i, account["balance-date"]
      assert_equal "ING España", account["org"]["name"]
      assert_equal "ing.es", account["org"]["domain"]
      assert_equal "ing", account["org"]["id"]
      assert_equal [], env["errors"]
    end

    def test_transactions_are_grouped_by_account_id_and_preserve_canonical_ids
      env = Reshape.call(sample)
      txs = env["accounts"].first["transactions"]
      assert_equal 2, txs.size
      assert_equal "txn_1111111111111111", txs[0]["id"]
      assert_equal "txn_2222222222222222", txs[1]["id"]
      assert_equal "-5.00", txs[0]["amount"]
      assert_equal "10.00", txs[1]["amount"]
      # `payee` is not a SimpleFIN v1/v2 spec field — we stash the
      # merchant name in `extra` instead.
      refute txs[1].key?("payee"), "transactions must not emit a top-level `payee`"
      assert_equal "Acme Inc", txs[1].dig("extra", "payee")
      # No-merchant txn no longer has a bare extra: bank_movement_id
      # (the canonical source_id) lives there now as a stable secondary
      # dedup key. The fixture has source_id "m1" on this one.
      refute txs[0].dig("extra")&.key?("payee"),
        "extra.payee must not appear when merchant is nil"
      assert_equal "m1", txs[0].dig("extra", "bank_movement_id"),
        "extra.bank_movement_id must mirror the canonical source_id"
    end

    def test_money_is_a_raw_passthrough
      # Canonical already emits decimals as strings. No parse-and-reformat.
      payload = sample
      payload["transactions"].first["amount"] = "-45.20"
      env = Reshape.call(payload)
      assert_equal "-45.20", env["accounts"].first["transactions"].first["amount"]
    end

    def test_multi_account_envelope_groups_transactions_correctly
      payload = sample
      payload["accounts"] << {
        "id"          => "acc_ffffffffffffffff",
        "institution" => "revolut",
        "currency"    => "EUR",
        "name"        => "Revolut EUR",
        "balance"     => { "current" => "42.00", "timestamp" => "2026-04-22T10:00:00Z" }
      }
      payload["transactions"] << {
        "id"          => "txn_3333333333333333",
        "account_id"  => "acc_ffffffffffffffff",
        "date"        => "2026-04-19",
        "amount"      => "1.23",
        "currency"    => "EUR",
        "description" => "Revolut top-up",
        "status"      => "posted"
      }

      env = Reshape.call(payload)
      assert_equal 2, env["accounts"].size

      ing = env["accounts"].find { |a| a["id"] == "acc_a1b2c3d4e5f60718" }
      rev = env["accounts"].find { |a| a["id"] == "acc_ffffffffffffffff" }
      assert_equal 2, ing["transactions"].size
      assert_equal 1, rev["transactions"].size
      assert_equal "txn_3333333333333333", rev["transactions"].first["id"]
      assert_equal "Revolut", rev["org"]["name"]
    end

    def test_account_with_no_transactions_emits_empty_transactions_array
      payload = sample
      payload["transactions"] = []
      env = Reshape.call(payload)
      assert_equal [], env["accounts"].first["transactions"]
    end

    def test_orphan_transaction_is_surfaced_as_error_and_dropped
      payload = sample
      payload["transactions"] << {
        "id"          => "txn_orphaned0000000",
        "account_id"  => "acc_doesnotexist00",
        "date"        => "2026-04-18",
        "amount"      => "9.99",
        "currency"    => "EUR",
        "description" => "nowhere",
        "status"      => "posted"
      }
      env = Reshape.call(payload)
      # The orphan isn't attached to any account.
      all_ids = env["accounts"].flat_map { |a| a["transactions"].map { |t| t["id"] } }
      refute_includes all_ids, "txn_orphaned0000000"
      assert env["errors"].any? { |e| e.include?("orphan") && e.include?("acc_doesnotexist00") },
        "expected orphan-transaction error, got #{env["errors"].inspect}"
    end

    def test_missing_balance_current_emits_error_and_skips_account
      payload = sample
      payload["accounts"].first["balance"]["current"] = nil
      env = Reshape.call(payload)
      assert_empty env["accounts"]
      assert_match(/acc_a1b2c3d4e5f60718/, env["errors"].first)
      assert_match(/balance/, env["errors"].first)
    end

    def test_missing_currency_emits_error_and_skips_account
      payload = sample
      payload["accounts"].first["currency"] = nil
      env = Reshape.call(payload)
      assert_empty env["accounts"]
      assert_match(/currency/, env["errors"].first)
    end

    def test_missing_canonical_id_emits_error_and_skips_account
      payload = sample
      payload["accounts"].first["id"] = "12345"  # not prefixed with acc_
      payload["transactions"] = []
      env = Reshape.call(payload)
      assert_empty env["accounts"]
      assert env["errors"].any? { |e| e.include?("canonical id") },
        "expected canonical-id error, got #{env["errors"].inspect}"
    end

    def test_missing_balance_timestamp_falls_back_to_sync_time
      payload = sample
      payload["accounts"].first["balance"].delete("timestamp")
      now_before = Time.now.to_i
      env = Reshape.call(payload)
      now_after = Time.now.to_i
      assert_equal 1, env["accounts"].size, "missing timestamp must not drop the account"
      ts = env["accounts"].first["balance-date"]
      assert ts >= now_before && ts <= now_after,
        "expected balance-date to fall back to sync time"
    end

    # SimpleFIN spec: available-balance is optional and MUST be omitted
    # when equal to balance.
    def test_available_balance_omitted_when_equal_to_current
      env = Reshape.call(sample)  # sample has available == current
      refute env["accounts"].first.key?("available-balance"),
        "available-balance must be omitted when it matches balance"
    end

    def test_available_balance_emitted_when_distinct_from_current
      payload = sample
      payload["accounts"].first["balance"]["available"] = "1000.00"
      env = Reshape.call(payload)
      assert_equal "1000.00", env["accounts"].first["available-balance"]
    end

    def test_canonical_type_forwarded_to_extra_account_type
      env = Reshape.call(sample)  # sample has type: "checking"
      assert_equal "checking", env["accounts"].first["extra"]["account-type"]
    end

    def test_extra_account_type_omitted_when_canonical_type_absent
      payload = sample
      payload["accounts"].first.delete("type")
      env = Reshape.call(payload)
      refute env["accounts"].first["extra"].key?("account-type")
    end

    # SimpleFIN spec: pending transactions have `posted: 0`.
    def test_pending_transactions_have_posted_zero
      payload = sample
      payload["transactions"] << {
        "id"          => "txn_pending000000000",
        "account_id"  => "acc_a1b2c3d4e5f60718",
        "date"        => "2026-04-20",
        "value_date"  => nil,
        "amount"      => "-2.00",
        "currency"    => "EUR",
        "description" => "Pending card authorization",
        "status"      => "pending"
      }
      env = Reshape.call(payload)
      pending_tx = env["accounts"].first["transactions"].find { |t| t["id"] == "txn_pending000000000" }
      refute_nil pending_tx
      assert_equal 0, pending_tx["posted"]
      assert_equal true, pending_tx["pending"]
      # The raw date should still be preserved as transacted_at so
      # downstream consumers can render an approximate time.
      assert pending_tx["transacted_at"].is_a?(Integer)
    end

    # Revolut canonicalizes the full event log: DECLINED authorization
    # retries, REVERTED transfer legs, FAILED top-ups. The bank
    # statement only shows the COMPLETED leg, so SimpleFIN consumers
    # (Actual, sure.am) must see only those. Drop non-served statuses
    # before they reach the envelope.
    def test_drops_non_served_statuses
    payload = sample
    %w[declined failed reverted].each_with_index do |st, i|
        payload["transactions"] << {
          "id"          => "txn_drop#{i}#{"0"*(12-i.to_s.length)}",
          "account_id"  => "acc_a1b2c3d4e5f60718",
          "date"        => "2026-04-22",
          "value_date"  => nil,
          "amount"      => "-9.99",
          "currency"    => "EUR",
          "description" => "auth retry",
          "status"      => st
        }
      end
      env = Reshape.call(payload)
      ids = env["accounts"].first["transactions"].map { |t| t["id"] }
      assert_equal 2, ids.size
      ids.each { |id| refute_match(/^txn_drop/, id) }
    end

    # Whitelist: only nil/posted/pending reach clients. An unknown
    # canonical status (provider introduces a new label and the filter
    # hasn't learned about it) is dropped. The companion guarantee on
    # the provider side: normalizers map unrecognized upstream states
    # to a nil canonical status, not an unknown string — so a new
    # upstream label still surfaces as a regular money-moving row
    # rather than vanishing. See revolut_normalizer_test.rb
    # `test_unknown_state_maps_to_nil_status`.
    def test_drops_unknown_status
      payload = sample
      payload["transactions"] << {
        "id"          => "txn_unknownstatus000",
        "account_id"  => "acc_a1b2c3d4e5f60718",
        "date"        => "2026-04-22",
        "value_date"  => nil,
        "amount"      => "-1.00",
        "currency"    => "EUR",
        "description" => "future state",
        "status"      => "quantum_superposition"
      }
      env = Reshape.call(payload)
      ids = env["accounts"].first["transactions"].map { |t| t["id"] }
      refute_includes ids, "txn_unknownstatus000"
    end

    # nil status (older provider data + Revolut normalizer's
    # unknown-state fallback) is admitted unchanged. This is the
    # release-time state for ING/fintonic/UNICAJA, and the path Revolut
    # uses when upstream introduces a new state name.
    def test_nil_status_admitted
      payload = sample
      payload["transactions"] << {
        "id"          => "txn_nilstatus0000000",
        "account_id"  => "acc_a1b2c3d4e5f60718",
        "date"        => "2026-04-22",
        "value_date"  => nil,
        "amount"      => "-3.50",
        "currency"    => "EUR",
        "description" => "legacy provider no status",
        "status"      => nil
      }
      env = Reshape.call(payload)
      ids = env["accounts"].first["transactions"].map { |t| t["id"] }
      assert_includes ids, "txn_nilstatus0000000"
    end

    def test_value_date_used_as_transacted_at_when_present
      payload = sample
      payload["transactions"].first["value_date"] = "2026-04-25"
      env = Reshape.call(payload)
      tx = env["accounts"].first["transactions"].find { |t| t["id"] == "txn_1111111111111111" }
      assert_equal Time.parse("2026-04-25").to_i, tx["transacted_at"]
    end

    def test_description_falls_back_to_raw_description
      payload = sample
      payload["transactions"].first["description"] = nil
      payload["transactions"].first["raw_description"] = "AMZN Mktp ES*XYZ"
      env = Reshape.call(payload)
      tx = env["accounts"].first["transactions"].find { |t| t["id"] == "txn_1111111111111111" }
      assert_equal "AMZN Mktp ES*XYZ", tx["description"]
    end

    def test_unknown_institution_falls_back_to_slug_based_org
      payload = sample
      payload["accounts"].first["institution"] = "somebank"
      env = Reshape.call(payload)
      org = env["accounts"].first["org"]
      assert_equal "somebank", org["name"]
      assert_equal "somebank.local", org["domain"]
      assert_equal "about:blank", org["url"]
    end

    def test_apply_query_filters_by_start_date
      env = Reshape.call(sample)
      cutoff = Time.parse("2026-04-21").to_i
      filtered = Reshape.apply_query(env, { "start-date" => cutoff.to_s })
      assert_equal 1, filtered["accounts"].first["transactions"].size
    end

    def test_apply_query_serve_floor_clamps_when_client_requests_older
      # Server-side clamp: even when the client asks for everything (no
      # start-date), a serve_floor_ts of "5 days ago" must drop anything
      # older. Sample fixture has txns dated 2026-04-{20,22}.
      env = Reshape.call(sample)
      floor = Time.parse("2026-04-21").to_i
      filtered = Reshape.apply_query(env, {}, serve_floor_ts: floor)
      assert_equal 1, filtered["accounts"].first["transactions"].size,
        "serve floor must drop txns older than the cutoff regardless of client params"
    end

    def test_apply_query_serve_floor_does_not_loosen_client_start_date
      # If client asks for txns since T1 and the floor is T0 < T1, the
      # tighter T1 wins. The clamp tightens, never loosens.
      env = Reshape.call(sample)
      tighter = Time.parse("2026-04-21").to_i
      looser  = Time.parse("2026-04-15").to_i
      filtered = Reshape.apply_query(env,
        { "start-date" => tighter.to_s }, serve_floor_ts: looser)
      txs = filtered["accounts"].first["transactions"]
      refute_empty txs
      txs.each { |t| assert_operator t["posted"], :>=, tighter }
    end

    def test_apply_query_balances_only
      env = Reshape.call(sample)
      filtered = Reshape.apply_query(env, { "balances-only" => "1" })
      assert_empty filtered["accounts"].first["transactions"]
    end

    def test_apply_query_account_filter
      payload = sample
      payload["accounts"] << {
        "id"          => "acc_ffffffffffffffff",
        "institution" => "revolut",
        "currency"    => "EUR",
        "name"        => "Revolut",
        "balance"     => { "current" => "0.00", "timestamp" => "2026-04-22T10:00:00Z" }
      }
      env = Reshape.call(payload)
      filtered = Reshape.apply_query(env, { "account" => ["acc_a1b2c3d4e5f60718"] })
      assert_equal ["acc_a1b2c3d4e5f60718"], filtered["accounts"].map { |a| a["id"] }
    end

    def test_pending_transactions_survive_start_date_filter_when_pending_flag_set
      payload = sample
      payload["transactions"] << {
        "id"          => "txn_pending000000000",
        "account_id"  => "acc_a1b2c3d4e5f60718",
        "date"        => "2026-04-20",
        "amount"      => "-2.00",
        "currency"    => "EUR",
        "description" => "Pending",
        "status"      => "pending"
      }
      env = Reshape.call(payload)
      far_future = Time.now.to_i + 86_400
      filtered = Reshape.apply_query(env, {
        "start-date" => far_future.to_s,
        "pending"    => "1"
      })
      ids = filtered["accounts"].first["transactions"].map { |t| t["id"] }
      assert_includes ids, "txn_pending000000000",
        "pending tx must bypass start-date filter (posted=0) when ?pending=1"
    end

    # ── extra.bank_movement_id ──────────────────────────────

    def test_bank_movement_id_omitted_when_source_id_blank
      payload = sample
      payload["transactions"].first["source_id"] = nil
      payload["transactions"].first["merchant"]  = nil
      env = Reshape.call(payload)
      tx = env["accounts"].first["transactions"].find { |t| t["id"] == "txn_1111111111111111" }
      refute tx.key?("extra"),
        "transactions with no merchant and no source_id must not emit a bare empty extra"
    end

    def test_bank_movement_id_omitted_when_source_id_empty_string
      payload = sample
      payload["transactions"].first["source_id"] = ""
      payload["transactions"].first["merchant"]  = nil
      env = Reshape.call(payload)
      tx = env["accounts"].first["transactions"].find { |t| t["id"] == "txn_1111111111111111" }
      refute tx.key?("extra"),
        "blank-string source_id must be treated as absent (no bank_movement_id emitted)"
    end

    def test_bank_movement_id_coexists_with_payee
      env = Reshape.call(sample)
      tx2 = env["accounts"].first["transactions"].find { |t| t["id"] == "txn_2222222222222222" }
      # Sample has both source_id "m2" AND merchant "Acme Inc" — extra
      # must carry both keys, neither clobbering the other.
      assert_equal "Acme Inc", tx2.dig("extra", "payee")
      assert_equal "m2",       tx2.dig("extra", "bank_movement_id")
    end

    def test_bank_movement_id_preserves_v1id_envelope_verbatim
      # ING's wire format wraps stable internal ids in ___V1ID___…___V1ID___.
      # The bridge must not trim or decode it — the value goes onto the
      # wire byte-for-byte so downstream consumers can use it as a
      # cross-reference key without guessing the envelope shape.
      payload = sample
      v1id = "___V1ID___abcdefABCDEF0123456789-_xyz___V1ID___"
      payload["transactions"].first["source_id"] = v1id
      payload["transactions"].first["merchant"]  = nil
      env = Reshape.call(payload)
      tx = env["accounts"].first["transactions"].find { |t| t["id"] == "txn_1111111111111111" }
      assert_equal v1id, tx.dig("extra", "bank_movement_id")
    end
  end
end
