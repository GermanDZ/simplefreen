# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "time"

module Simplefreen
  class WatchdogTest < Minitest::Test
    # Records every notify() call; always "configured".
    class FakeNotifier
      attr_reader :sent

      def initialize(configured: true)
        @configured = configured
        @sent = []
      end

      def configured?
        @configured
      end

      def notify(title:, message:, priority: nil, tags: nil)
        @sent << { title: title, message: message, priority: priority, tags: tags }
        true
      end
    end

    # Stand-in scheduler exposing only what the watchdog reads.
    class FakeScheduler
      attr_accessor :alive
      def initialize(alive: true); @alive = alive; end
      def worker_alive?; @alive; end
    end

    def setup
      @root = Dir.mktmpdir("simplefreen-wd-")
      @master = Crypto.decode_master_key(Crypto.generate_master_key_b64)
      @feature = Feature.new(
        root:                    @root,
        master_key:              @master,
        admin_password:          "pw",
        public_url:              "http://example",
        freentonic_url:          "http://fake-freentonic:7878",
        freentonic_invoke_token: "token"
      )
      @notifier = FakeNotifier.new
      @scheduler = FakeScheduler.new(alive: true)
      @feature.install_scheduler(@scheduler)
    end

    def teardown
      FileUtils.rm_rf(@root)
    end

    # Fixed clock helper so staleness math is deterministic.
    def watchdog(now:, renotify_seconds: 24 * 3600)
      Watchdog.new(feature: @feature, notifier: @notifier,
                   renotify_seconds: renotify_seconds,
                   clock: -> { now })
    end

    def create_profile(key, sync_interval_seconds: 3600, access: true)
      @feature.profile_store.create(key: key, workflow: "wf/#{key}.yml",
                                    sync_interval_seconds: sync_interval_seconds)
      if access
        @feature.profile_store.update(key) do |p|
          p.merge("access_url" => { "username" => "u", "password_pw" => "x" })
        end
      end
    end

    def set_state(key, state, extras = {})
      @feature.state_store.force_state(key, state, extras)
    end

    # ── nothing to alert ─────────────────────────────────────

    def test_no_notification_when_all_healthy
      create_profile("acme")
      set_state("acme", "ready",
        "last_synced_at" => Time.now.utc.iso8601)
      sent = watchdog(now: Time.now).check_once
      assert_empty sent
      assert_empty @notifier.sent
    end

    def test_noop_when_notifier_unconfigured
      create_profile("acme")
      set_state("acme", "error", "last_error" => "boom")
      wd = Watchdog.new(feature: @feature, notifier: FakeNotifier.new(configured: false))
      assert_empty wd.check_once
    end

    # ── error / needs_reauth ─────────────────────────────────

    def test_alerts_on_error_state
      create_profile("acme")
      set_state("acme", "error", "last_error" => "exit 7 (nav_timeout)")
      wd = watchdog(now: Time.now)
      sent = wd.check_once
      assert_equal [{ subject: "acme", condition: "error", delivered: true }], sent
      msg = @notifier.sent.fetch(0)
      assert_match(/sync failed/, msg[:title])
      assert_match(/exit 7/, msg[:message])
      assert_equal 4, msg[:priority]
    end

    def test_alerts_on_needs_reauth_state
      create_profile("acme")
      set_state("acme", "needs_reauth", "last_error" => "reauth")
      sent = watchdog(now: Time.now).check_once
      assert_equal "needs_reauth", sent.fetch(0)[:condition]
      assert_match(/re-authentication needed/, @notifier.sent.fetch(0)[:title])
    end

    # ── edge-triggering / dedup ──────────────────────────────

    def test_does_not_realert_same_condition_within_renotify_window
      create_profile("acme")
      set_state("acme", "error", "last_error" => "boom")
      now = Time.now
      wd = watchdog(now: now)
      assert_equal 1, wd.check_once.size
      # Second pass, same condition, well within the 24h window → silent.
      assert_empty wd.check_once
      assert_equal 1, @notifier.sent.size
    end

    def test_realerts_after_renotify_window_elapses
      create_profile("acme")
      set_state("acme", "error", "last_error" => "boom")
      t0 = Time.parse("2026-07-05T00:00:00Z")
      wd0 = watchdog(now: t0, renotify_seconds: 3600)
      assert_equal 1, wd0.check_once.size

      # A fresh Watchdog instance (simulates a later tick / restart) reads the
      # persisted dedup file; 2h later, past the 1h re-notify window → alert.
      t1 = t0 + 2 * 3600
      wd1 = watchdog(now: t1, renotify_seconds: 3600)
      assert_equal 1, wd1.check_once.size
      assert_equal 2, @notifier.sent.size
    end

    def test_alerts_again_when_condition_changes_type
      create_profile("acme")
      set_state("acme", "error", "last_error" => "boom")
      now = Time.now
      wd = watchdog(now: now)
      assert_equal "error", wd.check_once.fetch(0)[:condition]
      # Transition error → needs_reauth is a new, more-actionable condition:
      # alert even though we're inside the re-notify window.
      set_state("acme", "needs_reauth", "last_error" => "kicked out")
      assert_equal "needs_reauth", wd.check_once.fetch(0)[:condition]
      assert_equal 2, @notifier.sent.size
    end

    # ── recovery ─────────────────────────────────────────────

    def test_sends_recovery_note_when_problem_clears
      create_profile("acme")
      set_state("acme", "error", "last_error" => "boom")
      now = Time.now
      wd = watchdog(now: now)
      wd.check_once
      # Recover: ready + fresh success.
      set_state("acme", "ready", "last_synced_at" => now.utc.iso8601, "last_error" => nil)
      sent = wd.check_once
      assert_equal [{ subject: "acme", condition: "ok", delivered: true }], sent
      assert_match(/recovered/, @notifier.sent.last[:title])
      # And it does not keep sending recovery notes on subsequent passes.
      assert_empty wd.check_once
    end

    def test_no_recovery_note_if_never_alerted
      create_profile("acme")
      set_state("acme", "ready", "last_synced_at" => Time.now.utc.iso8601)
      assert_empty watchdog(now: Time.now).check_once
    end

    # ── staleness ────────────────────────────────────────────

    def test_alerts_on_stale_profile
      create_profile("acme", sync_interval_seconds: 3600)
      # Last success 3 days ago — well past max(2h, 24h).
      old = (Time.now - 3 * 24 * 3600).utc.iso8601
      set_state("acme", "ready", "last_synced_at" => old)
      sent = watchdog(now: Time.now).check_once
      assert_equal "stale", sent.fetch(0)[:condition]
      assert_match(/stale/, @notifier.sent.fetch(0)[:title])
    end

    def test_never_synced_configured_profile_is_stale
      create_profile("acme", sync_interval_seconds: 3600)
      # default state: idle, last_synced_at nil
      sent = watchdog(now: Time.now).check_once
      assert_equal "stale", sent.fetch(0)[:condition]
    end

    def test_profile_without_interval_not_stale
      create_profile("acme", sync_interval_seconds: 0, access: true)
      sent = watchdog(now: Time.now).check_once
      assert_empty sent
    end

    # ── scheduler liveness ───────────────────────────────────

    def test_alerts_when_scheduler_worker_dead
      @scheduler.alive = false
      sent = watchdog(now: Time.now).check_once
      assert_equal Watchdog::SCHEDULER_SUBJECT, sent.fetch(0)[:subject]
      assert_equal "worker_dead", sent.fetch(0)[:condition]
      assert_equal 5, @notifier.sent.fetch(0)[:priority]
    end

    def test_scheduler_recovery_note
      @scheduler.alive = false
      now = Time.now
      wd = watchdog(now: now)
      wd.check_once
      @scheduler.alive = true
      sent = wd.check_once
      assert_equal Watchdog::SCHEDULER_SUBJECT, sent.fetch(0)[:subject]
      assert_equal "ok", sent.fetch(0)[:condition]
    end

    # ── virtual profiles skipped ─────────────────────────────

    def test_virtual_profiles_are_skipped
      @feature.profile_store.create(key: "consolidated", kind: "virtual", workflow: nil)
      # Force an error state on the virtual profile — should still be ignored.
      set_state("consolidated", "error", "last_error" => "should be ignored")
      assert_empty watchdog(now: Time.now).check_once
    end

    # ── persistence survives instance churn ──────────────────

    def test_dedup_state_persisted_across_instances
      create_profile("acme")
      set_state("acme", "error", "last_error" => "boom")
      now = Time.now
      watchdog(now: now).check_once
      assert_equal 1, @notifier.sent.size
      # A brand-new Watchdog (fresh @notified loaded from disk) must not
      # re-alert the same still-broken condition.
      assert_empty watchdog(now: now + 60).check_once
      assert_equal 1, @notifier.sent.size
    end
  end
end
