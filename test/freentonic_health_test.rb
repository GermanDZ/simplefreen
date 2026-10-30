# frozen_string_literal: true

require_relative "test_helper"

module Simplefreen
  class FreentonicHealthTest < Minitest::Test
    # Fake FreentonicClient whose healthz can be toggled to raise.
    class FakeClient
      attr_accessor :should_raise
      def initialize; @should_raise = false; end
      def healthz(*)
        raise FreentonicClient::ConnectionError, "refused" if @should_raise
        { "ok" => true }
      end
    end

    def test_initial_state_is_unknown
      h = FreentonicHealth.new(client: FakeClient.new)
      assert_equal :unknown, h.state
      refute h.active?
    end

    def test_probe_once_flips_to_active_on_success
      h = FreentonicHealth.new(client: FakeClient.new)
      assert_equal :active, h.probe_once
      assert h.active?
      assert_nil h.last_error
    end

    def test_probe_once_flips_to_degraded_on_error
      client = FakeClient.new
      client.should_raise = true
      h = FreentonicHealth.new(client: client)
      assert_equal :degraded, h.probe_once
      assert_match(/refused/, h.last_error)
      refute h.active?
    end

    def test_snapshot_contains_state_error_and_timestamp
      client = FakeClient.new
      client.should_raise = true
      h = FreentonicHealth.new(client: client)
      h.probe_once
      snap = h.snapshot
      assert_equal :degraded, snap[:state]
      assert snap[:last_error]
      assert snap[:last_probe_at]
    end

    def test_start_stop_does_not_hang
      h = FreentonicHealth.new(client: FakeClient.new, interval_seconds: 60)
      h.start
      # Give the worker thread a beat to run one probe.
      sleep 0.1
      assert h.active?
      h.stop(timeout: 3)
    end
  end
end
