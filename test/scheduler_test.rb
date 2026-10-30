# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "json"

module Simplefreen
  class SchedulerTest < Minitest::Test
    # Fake FreentonicClient used in place of a real Net::HTTP-backed one.
    # Records every #invoke call and can be configured to simulate push
    # arrival (cache_store.write) mid-call, or to raise transport errors.
    class FakeFreentonicClient
      attr_reader :invocations
      attr_accessor :on_invoke

      def initialize(&on_invoke)
        @invocations = []
        @on_invoke   = on_invoke
      end

      def invoke(body)
        @invocations << body
        if @on_invoke
          @on_invoke.call(body)
        else
          FreentonicClient::InvokeResult.new(
            run_id: body["run_id"], exit_code: 0, error_kind: nil,
            duration_ms: 10, artifacts: [], log_path: "", warnings: []
          )
        end
      end

      def healthz(*); { "ok" => true }; end
      def fetch_run_log(*); nil; end
    end

    def setup
      @root          = Dir.mktmpdir("simplefreen-sched-")
      @workflows_dir = Dir.mktmpdir("simplefreen-sched-wf-")
      FileUtils.mkdir_p(File.join(@workflows_dir, "acme"))
      File.write(File.join(@workflows_dir, "acme/workflow.yml"), "source: {}\n")

      @master = Crypto.decode_master_key(Crypto.generate_master_key_b64)
      @feature = Feature.new(
        root:                    @root,
        master_key:              @master,
        admin_password:          "pw",
        public_url:              "http://example",
        freentonic_url:          "http://fake-freentonic:7878",
        freentonic_invoke_token: "token",
        internal_push_url:       "http://simplefreen:7878"
      )
      @feature.profile_store.create(key: "acme", workflow: "acme/workflow.yml", lookback_days: 7)
      @feature.profile_store.write_credentials("acme",
        { "USER_DNI" => "1", "USER_PIN" => "2" }, master_key: @master)

      @feature.install_push_tokens(PushTokens.new)

      @client = FakeFreentonicClient.new
      @feature.install_freentonic_client(@client)

      @scheduler = Scheduler.new(feature: @feature)
      @feature.install_scheduler(@scheduler)
    end

    def teardown
      @scheduler.stop(timeout: 3) if @scheduler.instance_variable_get(:@thread)
      FileUtils.rm_rf(@root)
      FileUtils.rm_rf(@workflows_dir)
    end

    def wait_until(timeout: 5)
      deadline = Time.now + timeout
      until yield
        raise "condition not met" if Time.now > deadline
        sleep 0.02
      end
    end

    # Simulate the push-receiver processing a payload during an /invoke call.
    # Faithful to the real PushReceiver: it writes the cache AND stamps
    # state.last_run_id with the run it just merged — that stamp is what the
    # scheduler now trusts as proof the push landed (a bare cache file from a
    # prior run must not count).
    def with_push(cache_body)
      @client.on_invoke = lambda do |body|
        @feature.cache_store.write(body["profile_key"], cache_body)
        @feature.state_store.force_state(body["profile_key"], "ready",
          "last_run_id"     => body["run_id"],
          "last_error"      => nil,
          "last_synced_at"  => Time.now.utc.iso8601,
          "last_attempt_at" => Time.now.utc.iso8601)
        FreentonicClient::InvokeResult.new(
          run_id: body["run_id"], exit_code: 0, error_kind: nil,
          duration_ms: 50, artifacts: [], log_path: "", warnings: []
        )
      end
    end

    def test_successful_sync_transitions_to_ready
      with_push("accounts" => [], "errors" => [])
      @scheduler.start
      @scheduler.enqueue("acme")
      wait_until { @feature.state_store.read("acme")["state"] == "ready" }
      state = @feature.state_store.read("acme")
      assert_equal "ready", state["state"]
      refute_nil state["last_run_id"]
      assert_equal 1, @client.invocations.size
      # Credentials were decrypted + passed inline in the request body.
      creds = @client.invocations.first.dig("credentials", "inline")
      assert_equal "1", creds["USER_DNI"]
    end

    def test_invoke_body_uses_http_export_with_push_url_and_token
      with_push("accounts" => [], "errors" => [])
      @scheduler.start
      @scheduler.enqueue("acme")
      wait_until { @client.invocations.any? }
      body = @client.invocations.first
      assert_equal "http", body.dig("export", "mode")
      assert_match(%r{http://simplefreen:7878/push/simplefreen-acme-\h+\z}, body.dig("export", "url"))
      assert_kind_of String, body.dig("export", "token")
      refute body.dig("export", "token").empty?
    end

    def test_exit_code_3_transitions_to_needs_reauth
      @client.on_invoke = lambda do |body|
        FreentonicClient::InvokeResult.new(
          run_id: body["run_id"], exit_code: 3, error_kind: "needs_reauth",
          duration_ms: 10, artifacts: [], log_path: "", warnings: []
        )
      end
      @scheduler.start
      @scheduler.enqueue("acme")
      wait_until { @feature.state_store.read("acme")["state"] == "needs_reauth" }
      entries = @feature.run_log.recent("acme")
      assert_equal "needs_reauth", entries.first["outcome"]
    end

    def test_other_failures_transition_to_error
      @client.on_invoke = lambda do |body|
        FreentonicClient::InvokeResult.new(
          run_id: body["run_id"], exit_code: 1, error_kind: "user_error",
          duration_ms: 10, artifacts: [], log_path: "", warnings: []
        )
      end
      @scheduler.start
      @scheduler.enqueue("acme")
      wait_until { @feature.state_store.read("acme")["state"] == "error" }
    end

    def test_invoke_timeout_marks_error
      @client.on_invoke = ->(_) { raise FreentonicClient::TimeoutError, "read timeout" }
      @scheduler.start
      @scheduler.enqueue("acme")
      wait_until { @feature.state_store.read("acme")["state"] == "error" }
      assert_match(/timed out/i, @feature.state_store.read("acme")["last_error"])
    end

    def test_exit_zero_but_no_push_is_an_error
      # FakeFreentonicClient default behavior returns exit_code=0 without
      # writing the cache — simulating a freentonic that completed but the
      # http exporter never hit /push (e.g. exporter crash).
      @scheduler.start
      @scheduler.enqueue("acme")
      wait_until { @feature.state_store.read("acme")["state"] == "error" }
      assert_match(/no payload was pushed/i, @feature.state_store.read("acme")["last_error"])
    end

    def test_exit_zero_with_stale_cache_from_prior_run_is_an_error
      # R-H2 regression. A previous run left a cache file behind (caches
      # live 14 days). This run exits 0 but its push never lands (token lost
      # to a restart → 401 push). The scheduler must NOT read the stale
      # cache as success — it keys off state.last_run_id, not file presence.
      @feature.cache_store.write("acme", { "accounts" => [], "errors" => [] })
      @feature.state_store.force_state("acme", "ready", "last_run_id" => "old-run")
      # Default fake: exit 0, no push (no last_run_id stamp for THIS run).
      @scheduler.start
      @scheduler.enqueue("acme")
      wait_until { @feature.state_store.read("acme")["state"] == "error" }
      assert_match(/no payload was pushed/i, @feature.state_store.read("acme")["last_error"])
    end

    def test_failure_does_not_advance_last_synced_at
      # R-M7. A failed sync records last_attempt_at but must leave
      # last_synced_at (the honest staleness signal) untouched.
      @feature.state_store.force_state("acme", "ready",
        "last_synced_at" => "2020-01-01T00:00:00Z")
      @client.on_invoke = lambda do |body|
        FreentonicClient::InvokeResult.new(
          run_id: body["run_id"], exit_code: 1, error_kind: "user_error",
          duration_ms: 10, artifacts: [], log_path: "", warnings: []
        )
      end
      @scheduler.start
      @scheduler.enqueue("acme")
      wait_until { @feature.state_store.read("acme")["state"] == "error" }
      state = @feature.state_store.read("acme")
      assert_equal "2020-01-01T00:00:00Z", state["last_synced_at"]
      refute_nil state["last_attempt_at"]
    end

    def test_push_token_ttl_tracks_configured_timeout
      # R-M1. The minted token must outlive the run, so its TTL follows the
      # scheduler's configured timeout rather than PushTokens' fixed default.
      captured_ttl = nil
      table = @feature.push_tokens
      table.define_singleton_method(:mint) do |run_id, ttl_seconds: nil|
        captured_ttl = ttl_seconds
        super(run_id, ttl_seconds: ttl_seconds || PushTokens::DEFAULT_TTL_SECONDS)
      end
      sched = Scheduler.new(feature: @feature, default_timeout_sec: 3600)
      @feature.install_scheduler(sched)
      with_push("accounts" => [], "errors" => [])
      sched.start
      sched.enqueue("acme")
      wait_until { @feature.state_store.read("acme")["state"] == "ready" }
      assert_equal 3600 + 60, captured_ttl
      sched.stop(timeout: 3)
    end

    def test_enqueue_is_idempotent_while_queued
      # Block the invoke mutex so the scheduler holds the job.
      mu = @scheduler.instance_variable_get(:@invoke_mutex)
      mu.lock
      @scheduler.start
      assert_equal :enqueued, @scheduler.enqueue("acme")
      wait_until do
        @feature.state_store.read("acme")["state"] == "queued" ||
          @scheduler.pending_keys.include?("acme") ||
          @scheduler.active_key == "acme"
      end
      assert_includes %i[already_queued already_active], @scheduler.enqueue("acme")
      mu.unlock
    end

    def test_degraded_freentonic_defers_job
      health_stub = Object.new
      def health_stub.state; :degraded; end
      def health_stub.active?; false; end
      @feature.install_freentonic_health(health_stub)

      @scheduler.start
      @scheduler.enqueue("acme")
      # The worker pops the job, sees degraded, marks error. No /invoke
      # fires.
      wait_until { @feature.state_store.read("acme")["state"] == "error" }
      assert_equal 0, @client.invocations.size
      assert_match(/degraded/i, @feature.state_store.read("acme")["last_error"])
    end

    def test_recover_on_boot_resets_queued_and_running
      @feature.state_store.force_state("acme", "queued")
      @feature.state_store.force_state("other", "running")
      @feature.recover_on_boot!
      assert_equal "idle", @feature.state_store.read("acme")["state"]
      assert_equal "idle", @feature.state_store.read("other")["state"]
    end

    # ── resolve_lookback (private) ──────────────────────────

    def resolve(profile_key, job: nil, today: Date.today)
      profile = @feature.profile_store.read(profile_key)
      @scheduler.send(:resolve_lookback, profile, job, today: today)
    end

    def seed_history(profile_key, last_date)
      @feature.history_store.merge_run!(profile_key, run_id: "seed_run", payload: {
        "schema_version" => "1",
        "accounts"       => [],
        "transactions"   => [
          { "id" => "txn_seed", "account_id" => "a", "date" => last_date,
            "amount" => "-1.00", "currency" => "EUR", "status" => "posted" }
        ]
      })
    end

    def test_resolve_lookback_fixed_mode_returns_profile_default
      @feature.profile_store.create(key: "fixed_p", workflow: "acme/workflow.yml",
        lookback_days: 7, lookback_mode: "fixed")
      assert_equal 7, resolve("fixed_p")
    end

    def test_resolve_lookback_new_profile_defaults_to_incremental
      # "acme" was created in setup without specifying lookback_mode.
      # The new default makes it incremental — with no seeded history
      # it falls through to max_lookback_days (cold start), not the
      # profile's lookback_days.
      profile = @feature.profile_store.read("acme")
      assert_equal "incremental", profile["lookback_mode"]
      assert_equal 365, resolve("acme")  # max_lookback_days default
    end

    def test_resolve_lookback_treats_legacy_profile_without_mode_as_incremental
      # Simulate a profile JSON written before lookback_mode existed:
      # strip the field directly from the on-disk record.
      @feature.profile_store.update("acme") do |p|
        p.delete("lookback_mode")
        p.delete("lookback_overlap_days")
        p
      end
      profile = @feature.profile_store.read("acme")
      refute profile.key?("lookback_mode")
      # No history → cold-start to max_lookback_days, not the legacy
      # lookback_days of 7.
      assert_equal 365, resolve("acme")
    end

    def test_resolve_lookback_operator_override_always_wins
      override = Scheduler::Job.new(profile_key: "acme", lookback: 180)
      assert_equal 180, resolve("acme", job: override)

      # And in incremental mode too, with seeded history.
      @feature.profile_store.create(key: "incr", workflow: "acme/workflow.yml",
        lookback_days: 7, max_lookback_days: 90,
        lookback_mode: "incremental", lookback_overlap_days: 10)
      seed_history("incr", "2026-05-10")
      assert_equal 180, resolve("incr", job: Scheduler::Job.new(profile_key: "incr", lookback: 180),
        today: Date.new(2026, 5, 13))
    end

    def test_resolve_lookback_incremental_cold_start_uses_max_lookback
      @feature.profile_store.create(key: "cold", workflow: "acme/workflow.yml",
        lookback_days: 7, max_lookback_days: 365,
        lookback_mode: "incremental", lookback_overlap_days: 10)
      assert_equal 365, resolve("cold")
    end

    def test_resolve_lookback_incremental_uses_days_since_last_tx_plus_overlap
      @feature.profile_store.create(key: "incr", workflow: "acme/workflow.yml",
        lookback_days: 7, max_lookback_days: 365,
        lookback_mode: "incremental", lookback_overlap_days: 10)
      seed_history("incr", "2026-05-10")
      # 3 days since last tx + 10 overlap = 13
      assert_equal 13, resolve("incr", today: Date.new(2026, 5, 13))
    end

    def test_resolve_lookback_incremental_clamps_to_max_lookback
      @feature.profile_store.create(key: "incr", workflow: "acme/workflow.yml",
        lookback_days: 7, max_lookback_days: 90,
        lookback_mode: "incremental", lookback_overlap_days: 10)
      seed_history("incr", "2026-01-01")  # ~132 days back from 2026-05-13
      assert_equal 90, resolve("incr", today: Date.new(2026, 5, 13))
    end

    def test_resolve_lookback_incremental_clamps_to_overlap_floor
      # last tx is today → days_since = 0, +overlap = 10, must not drop below overlap.
      @feature.profile_store.create(key: "incr", workflow: "acme/workflow.yml",
        lookback_days: 7, max_lookback_days: 365,
        lookback_mode: "incremental", lookback_overlap_days: 10)
      seed_history("incr", "2026-05-13")
      assert_equal 10, resolve("incr", today: Date.new(2026, 5, 13))
    end

    def test_resolve_lookback_incremental_handles_garbage_last_tx_date
      @feature.profile_store.create(key: "incr", workflow: "acme/workflow.yml",
        lookback_days: 7, max_lookback_days: 200,
        lookback_mode: "incremental", lookback_overlap_days: 10)
      # Seed history with a non-parseable date — must treat as cold start.
      @feature.history_store.merge_run!("incr", run_id: "junk", payload: {
        "schema_version" => "1",
        "accounts" => [], "transactions" => [
          { "id" => "txn_junk", "account_id" => "a", "date" => "not-a-date",
            "amount" => "-1.00", "currency" => "EUR", "status" => "posted" }
        ]
      })
      assert_equal 200, resolve("incr")
    end
  end
end
