# frozen_string_literal: true

require "openssl"
require "securerandom"

require_relative "crypto"

module Simplefreen
  # In-memory per-run push token table. Each entry is minted when the
  # scheduler queues a sync, passed to freentonic via
  # `invoke.body.export.token`, and consumed at most once when freentonic's
  # `http` exporter POSTs to `/push/<run_id>` with that token as the
  # Bearer value.
  #
  # Replay-safe: consume deletes the entry the moment the request's
  # bearer is verified. TTL-gated: `cleanup_expired` is called by the
  # Feature's housekeeper thread and on every mint (opportunistic sweep).
  #
  # Tokens are stored as SHA-256 hashes so a memory dump doesn't leak
  # live bearers. The plaintext token is only held by the scheduler for
  # the lifetime of the outbound /invoke call.
  class PushTokens
    Entry = Struct.new(:run_id, :expires_at, keyword_init: true)

    # Default TTL aligns with freentonic's default timeout_sec (1800s)
    # plus a small buffer so a sync that races against its own timeout
    # still lands.
    DEFAULT_TTL_SECONDS = 1800 + 60

    def initialize
      @mutex = Mutex.new
      @by_hash = {}
    end

    # Mint a fresh token for a given run. Returns the plaintext bearer.
    # The caller passes it to freentonic; we only store the hash.
    def mint(run_id, ttl_seconds: DEFAULT_TTL_SECONDS)
      token = Crypto.random_token(bytes: 32)
      hash  = OpenSSL::Digest::SHA256.hexdigest(token)
      @mutex.synchronize do
        prune_expired_locked
        @by_hash[hash] = Entry.new(run_id: run_id, expires_at: Time.now.to_f + ttl_seconds)
      end
      token
    end

    # Verify + consume. Returns the run_id if the token is valid and
    # scoped to the given run_id; nil otherwise. The entry is removed
    # on success (single-use). Constant-time hash compare via the hash
    # map + no plaintext is ever re-derivable by an attacker.
    def consume(run_id, token)
      return nil if token.nil? || token.empty?
      hash = OpenSSL::Digest::SHA256.hexdigest(token)
      @mutex.synchronize do
        entry = live_entry_locked(hash, run_id)
        return nil if entry.nil?
        @by_hash.delete(hash)
        entry.run_id
      end
    end

    # Non-consuming check with the same rules as `consume`. Used by the
    # Server to decide, from headers alone, whether a /push body may use
    # the large size cap. Never a substitute for `consume`: the receiver
    # still burns the token before accepting the payload.
    def valid?(run_id, token)
      return false if token.nil? || token.empty?
      hash = OpenSSL::Digest::SHA256.hexdigest(token)
      @mutex.synchronize { !live_entry_locked(hash, run_id).nil? }
    end

    # Remove entries for a run_id (when /invoke returns non-zero before
    # any push landed, etc.). Safe to call even if no entry exists.
    def discard_for_run(run_id)
      @mutex.synchronize do
        @by_hash.delete_if { |_h, e| e.run_id == run_id }
      end
    end

    # Housekeeper sweep. Returns the number of entries removed.
    def cleanup_expired
      @mutex.synchronize { prune_expired_locked }
    end

    def size
      @mutex.synchronize { @by_hash.size }
    end

    private

    # The entry for `hash` if it is unexpired and scoped to `run_id`;
    # nil otherwise. Drops the entry when it has expired.
    def live_entry_locked(hash, run_id)
      entry = @by_hash[hash]
      return nil if entry.nil?
      if entry.expires_at < Time.now.to_f
        @by_hash.delete(hash)
        return nil
      end
      return nil unless Crypto.secure_compare(entry.run_id, run_id.to_s)
      entry
    end

    def prune_expired_locked
      now = Time.now.to_f
      before = @by_hash.size
      @by_hash.delete_if { |_h, e| e.expires_at < now }
      before - @by_hash.size
    end
  end
end
