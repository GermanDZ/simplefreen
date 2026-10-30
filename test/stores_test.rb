# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "simplefreen/feature"

module Simplefreen
  class StoresTest < Minitest::Test
    def setup
      @root = Dir.mktmpdir("simplefin-test-")
      Paths.ensure_layout!(@root)
      @master = Crypto.decode_master_key(Crypto.generate_master_key_b64)
    end

    def teardown
      FileUtils.rm_rf(@root)
    end

    # ── ProfileStore ────────────────────────────────────────

    def test_profile_create_and_read
      store = ProfileStore.new(root: @root)
      profile = store.create(key: "ing_personal", workflow: "ing/workflow.yml",
        display_name: "ING", lookback_days: 14)
      assert_equal "ing_personal", profile["profile_key"]
      assert_equal "ing/workflow.yml", profile["workflow"]
      assert_equal "ING", profile["display_name"]
      assert_equal 14, profile["lookback_days"]
      assert profile["created_at"]
    end

    def test_profile_create_rejects_duplicates
      store = ProfileStore.new(root: @root)
      store.create(key: "dup", workflow: "x.yml")
      assert_raises(ArgumentError) { store.create(key: "dup", workflow: "x.yml") }
    end

    def test_profile_rejects_path_traversal_in_key
      store = ProfileStore.new(root: @root)
      assert_raises(ArgumentError) { store.create(key: "../etc", workflow: "x.yml") }
    end

    def test_credentials_round_trip_encrypted
      store = ProfileStore.new(root: @root)
      store.create(key: "ing", workflow: "ing/workflow.yml")
      store.write_credentials("ing", { "USER_DNI" => "12345678A", "USER_PIN" => "1234" }, master_key: @master)

      raw = File.read(Paths.profile_path("ing", @root))
      refute_includes raw, "12345678A"
      refute_includes raw, "1234"

      plain = store.read_credentials("ing", master_key: @master)
      assert_equal "12345678A", plain["USER_DNI"]
      assert_equal "1234",      plain["USER_PIN"]
    end

    def test_read_credentials_with_wrong_master_key_raises
      store = ProfileStore.new(root: @root)
      store.create(key: "ing", workflow: "ing/workflow.yml")
      store.write_credentials("ing", { "X" => "y" }, master_key: @master)

      other = Crypto.decode_master_key(Crypto.generate_master_key_b64)
      assert_raises(ArgumentError) { store.read_credentials("ing", master_key: other) }
    end

    def test_access_url_set_and_verify
      store = ProfileStore.new(root: @root)
      store.create(key: "ing", workflow: "ing/workflow.yml")
      store.set_access_url("ing", username: "simplefin", password_plain: "mypw")
      assert store.verify_access("ing", "simplefin", "mypw")
      refute store.verify_access("ing", "simplefin", "nope")
      refute store.verify_access("ing", "other", "mypw")
    end

    # ── StateStore ──────────────────────────────────────────

    def test_state_default_is_idle
      store = StateStore.new(root: @root)
      state = store.read("never_touched")
      assert_equal "idle", state["state"]
      assert_nil state["last_error"]
    end

    def test_state_update_persists_atomically
      store = StateStore.new(root: @root)
      store.force_state("foo", "running", "last_run_id" => "r1")
      state = store.read("foo")
      assert_equal "running", state["state"]
      assert_equal "r1", state["last_run_id"]
    end

    def test_state_rejects_invalid_enum
      store = StateStore.new(root: @root)
      assert_raises(ArgumentError) { store.force_state("foo", "bogus") }
    end

    def test_concurrent_state_writers_do_not_corrupt
      store = StateStore.new(root: @root)
      store.force_state("foo", "idle")
      threads = 8.times.map do |i|
        Thread.new do
          100.times { store.force_state("foo", "queued", "last_run_id" => "t#{i}") }
        end
      end
      threads.each(&:join)
      state = store.read("foo")
      assert_equal "queued", state["state"]
      assert_match(/\At\d\z/, state["last_run_id"])
    end

    # ── CacheStore ──────────────────────────────────────────

    def test_cache_write_and_consume
      store = CacheStore.new(root: @root)
      store.write("ing", { "accounts" => [], "errors" => [] })
      assert store.exists?("ing")

      payload = store.consume("ing")
      assert_equal [], payload["accounts"]
      refute store.exists?("ing"), "cache should be unlinked after consume"
      assert_nil store.consume("ing")
    end

    # ── ClaimStore ──────────────────────────────────────────

    def test_claim_mint_and_consume_once
      store = ClaimStore.new(root: @root, ttl_seconds: 60)
      claim = store.mint("ing")
      outcome, key = store.consume!(claim["claim_id"])
      assert_equal :ok, outcome
      assert_equal "ing", key

      outcome2, = store.consume!(claim["claim_id"])
      assert_equal :already_consumed, outcome2
    end

    def test_claim_expires
      store = ClaimStore.new(root: @root, ttl_seconds: 0)
      claim = store.mint("ing")
      sleep 0.01
      outcome, = store.consume!(claim["claim_id"])
      assert_equal :expired, outcome
    end

    def test_claim_rejects_bogus_id
      store = ClaimStore.new(root: @root)
      outcome, = store.consume!("../etc")
      assert_equal :unknown, outcome
    end

    # ── RunLog ──────────────────────────────────────────────

    def test_runlog_records_and_lists_recent
      log = RunLog.new(root: @root)
      3.times do |i|
        log.record("ing", run_id: "r#{i}", outcome: "ready", message: "ok", exit_code: 0)
      end
      recent = log.recent("ing")
      assert_equal 3, recent.size
      assert_equal %w[r2 r1 r0], recent.map { |r| r["run_id"] }
    end

    def test_runlog_validates_ids
      log = RunLog.new(root: @root)
      assert_raises(ArgumentError) { log.record("bad/key", run_id: "r", outcome: "ready") }
    end

    # ── Feature housekeeper ─────────────────────────────────

    def test_housekeeper_gcs_expired_claims_and_old_caches
      feature = Feature.new(
        root: @root, master_key: @master,
        admin_password: "pw", public_url: "http://x",
        freentonic_url: "http://freentonic:7878",
        freentonic_invoke_token: "t"
      )
      feature.profile_store.create(key: "acme", workflow: "x.yml")
      feature.cache_store.write("acme", { "accounts" => [], "errors" => [] })
      # Age the cache file past the retention window.
      File.utime(Time.now - (30 * 24 * 3600), Time.now - (30 * 24 * 3600),
                 feature.cache_store.path_for("acme"))

      # Mint an expired claim.
      claim = ClaimStore.new(root: @root, ttl_seconds: 0).mint("acme")
      sleep 0.01

      # Force a single housekeeper pass synchronously (don't spin the thread).
      assert_equal 1, feature.claim_store.gc!
      assert_equal 1, feature.cache_store.gc!(max_age_seconds: 14 * 24 * 3600)

      refute File.exist?(Paths.claim_path(claim["claim_id"], @root))
      refute feature.cache_store.exists?("acme")
    end

    def test_housekeeper_thread_stops_cleanly
      feature = Feature.new(
        root: @root, master_key: @master,
        admin_password: "pw", public_url: "http://x",
        freentonic_url: "http://freentonic:7878",
        freentonic_invoke_token: "t"
      )
      feature.start_housekeeper(interval_seconds: 60)
      feature.stop_housekeeper(timeout: 3)
      assert_nil feature.instance_variable_get(:@housekeeper_thread)
    end
  end
end
