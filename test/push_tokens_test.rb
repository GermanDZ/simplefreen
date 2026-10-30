# frozen_string_literal: true

require_relative "test_helper"

module Simplefreen
  class PushTokensTest < Minitest::Test
    def setup
      @table = PushTokens.new
    end

    def test_mint_and_consume_happy_path
      token = @table.mint("run_1")
      assert_equal "run_1", @table.consume("run_1", token)
    end

    def test_consume_is_single_use
      token = @table.mint("run_1")
      assert_equal "run_1", @table.consume("run_1", token)
      assert_nil @table.consume("run_1", token), "second consume must fail"
    end

    def test_consume_rejects_wrong_run_id
      token = @table.mint("run_1")
      assert_nil @table.consume("other", token)
      # The token is still valid for its real run_id afterwards.
      assert_equal "run_1", @table.consume("run_1", token)
    end

    def test_consume_rejects_unknown_token
      assert_nil @table.consume("run_1", "fake-bearer")
    end

    def test_consume_rejects_nil_or_empty_token
      assert_nil @table.consume("run_1", nil)
      assert_nil @table.consume("run_1", "")
    end

    def test_expired_token_is_rejected
      token = @table.mint("run_1", ttl_seconds: 0)
      sleep 0.05
      assert_nil @table.consume("run_1", token)
    end

    def test_cleanup_expired_removes_past_entries
      # Mint both in one go (mint() opportunistically prunes the
      # expired-at-mint-time entries, so we have to work around that).
      @table.mint("run_1", ttl_seconds: 3600)
      @table.mint("run_2", ttl_seconds: 3600)
      # Expire one by hand via discard to avoid a sleep race.
      @table.discard_for_run("run_1")
      # Sanity: both entries accounted for.
      assert_equal 1, @table.size
      # A second mint with 0 TTL tests the real path.
      @table.mint("run_3", ttl_seconds: 0)
      sleep 0.05
      # cleanup_expired returns the count it actually removed.
      assert_equal 1, @table.cleanup_expired
      assert_equal 1, @table.size
    end

    def test_discard_for_run_removes_entry
      token = @table.mint("run_1")
      @table.discard_for_run("run_1")
      assert_nil @table.consume("run_1", token)
    end

    def test_valid_does_not_consume
      token = @table.mint("run_1")
      assert @table.valid?("run_1", token)
      assert @table.valid?("run_1", token), "valid? must be repeatable"
      assert_equal "run_1", @table.consume("run_1", token), "token still consumable"
      refute @table.valid?("run_1", token), "consumed token is no longer valid"
    end

    def test_valid_applies_consume_rules
      token = @table.mint("run_1")
      refute @table.valid?("other", token)
      refute @table.valid?("run_1", "fake-bearer")
      refute @table.valid?("run_1", nil)
      refute @table.valid?("run_1", "")
      expired = @table.mint("run_2", ttl_seconds: 0)
      sleep 0.05
      refute @table.valid?("run_2", expired)
    end
  end
end
