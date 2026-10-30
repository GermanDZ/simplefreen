# frozen_string_literal: true

require "time"
require "fileutils"

require_relative "atomic_file"
require_relative "crypto"
require_relative "paths"

module Simplefreen
  # One-shot setup-token claims. Each claim file is exchanged at most once
  # for an access URL, within its TTL window. Expired or consumed claims
  # respond 403 and remain on disk briefly so the admin can audit; a
  # sweeper removes them on boot and on demand.
  #
  # A claim JSON looks like:
  #   { "claim_id":    "32-hex",
  #     "profile_key": "ing_personal",
  #     "created_at":  "2026-04-22T10:00:00Z",
  #     "expires_at":  "2026-04-22T10:10:00Z",
  #     "consumed_at": null }
  class ClaimStore
    DEFAULT_TTL_SECONDS = 600   # 10 minutes

    def initialize(root: Paths.root, ttl_seconds: DEFAULT_TTL_SECONDS)
      @root = root
      @ttl  = ttl_seconds
      Paths.ensure_layout!(@root)
    end

    def mint(profile_key)
      Paths.validate_component!(profile_key, "profile_key")
      claim_id = Crypto.random_hex_id
      now      = Time.now.utc
      record   = {
        "claim_id"    => claim_id,
        "profile_key" => profile_key,
        "created_at"  => now.iso8601,
        "expires_at"  => (now + @ttl).iso8601,
        "consumed_at" => nil
      }
      AtomicFile.write_json(Paths.claim_path(claim_id, @root), record)
      record
    end

    def read(claim_id)
      return nil unless claim_id =~ Paths::FILENAME_PATTERN
      AtomicFile.read_json(Paths.claim_path(claim_id, @root))
    end

    # Atomically verify the claim is still valid, mark it consumed, and
    # yield the profile_key for the caller to mint an access URL. Raises
    # :expired / :already_consumed / :unknown tags so callers can branch.
    def consume!(claim_id)
      return [:unknown, nil] unless claim_id =~ Paths::FILENAME_PATTERN
      path = Paths.claim_path(claim_id, @root)
      result = nil
      AtomicFile.update_json(path) do |current|
        if current.nil? || current.empty?
          result = [:unknown, nil]
          next :abort
        end
        if current["consumed_at"]
          result = [:already_consumed, nil]
          next :abort
        end
        expires_at = Time.parse(current["expires_at"]) rescue nil
        if expires_at.nil? || Time.now.utc >= expires_at
          result = [:expired, nil]
          next :abort
        end
        current["consumed_at"] = Time.now.utc.iso8601
        result = [:ok, current["profile_key"]]
        current
      end
      # `:abort` returns cause the update block to skip the write but the
      # sentinel in AtomicFile is nil, which the lock protects. Translate
      # both failure paths to the captured result tuple.
      result || [:unknown, nil]
    end

    # Remove expired / consumed claims older than `grace_seconds` (an
    # audit window keeps them briefly after consumption).
    def gc!(grace_seconds: 3600)
      dir = Paths.claims_dir(@root)
      return 0 unless Dir.exist?(dir)
      removed = 0
      cutoff = Time.now.utc
      Dir.children(dir).each do |name|
        next unless name.end_with?(".json")
        claim_id = name.sub(/\.json\z/, "")
        next unless claim_id =~ Paths::FILENAME_PATTERN
        rec = read(claim_id)
        next if rec.nil?
        expired = begin
          exp = rec["expires_at"] && Time.parse(rec["expires_at"])
          exp && cutoff > exp
        rescue ArgumentError
          true
        end
        consumed_old = begin
          con = rec["consumed_at"] && Time.parse(rec["consumed_at"])
          con && cutoff - con > grace_seconds
        rescue ArgumentError
          true
        end
        if expired || consumed_old
          AtomicFile.delete(Paths.claim_path(claim_id, @root))
          removed += 1
        end
      end
      removed
    end
  end
end
