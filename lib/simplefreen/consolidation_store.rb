# frozen_string_literal: true

require_relative "atomic_file"
require_relative "paths"

module Simplefreen
  # Persists operator-supplied account aliases used by the Consolidation
  # layer. Stored as a single JSON file at <root>/consolidation/aliases.json:
  #
  #   {
  #     "version": 1,
  #     "aliases": [
  #       { "members": ["acc_adc93a00e0d05fd4", "acc_03e1df60663a59e6"],
  #         "note":    "Unicaja Principal ↔ Fintonic 2103:hash",
  #         "created_at": "2026-05-04T10:30:00Z" }
  #     ]
  #   }
  #
  # An alias entry's `members` is a set of acc_<hex> ids that the
  # operator has confirmed represent the same physical account. Two
  # members per entry is the common case (one direct + one aggregator);
  # more is allowed (e.g. same account observed via three providers).
  #
  # The store is intentionally append/replace style — there's no per-
  # entry id, so callers replace the whole list when editing. Volume is
  # tiny (one entry per cross-source link the operator confirms).
  class ConsolidationStore
    ACC_ID_PATTERN = /\Aacc_[0-9a-f]{16}\z/

    def initialize(root: Paths.root)
      @root = root
      Paths.ensure_layout!(@root)
    end

    def path
      Paths.consolidation_aliases_path(@root)
    end

    # Returns an Array of alias-entry Hashes. An empty file (or no file)
    # reads as []. Never raises on missing file.
    def list
      data = AtomicFile.read_json(path)
      return [] unless data.is_a?(Hash)
      Array(data["aliases"]).select { |e| e.is_a?(Hash) }
    end

    # Replace the entire alias list. Validates each entry before write
    # so a bad PUT can't corrupt the store mid-flight. Returns the
    # normalized list that was written.
    def replace(entries)
      normalized = Array(entries).map { |e| normalize!(e) }
      payload = {
        "version"    => 1,
        "aliases"    => normalized,
        "updated_at" => Time.now.utc.iso8601
      }
      AtomicFile.write_json(path, payload)
      normalized
    end

    private

    def normalize!(entry)
      raise ArgumentError, "alias entry must be an object" unless entry.is_a?(Hash)
      members = Array(entry["members"]).map { |m| m.to_s.strip }.uniq
      if members.size < 2
        raise ArgumentError, "alias entry needs at least 2 members"
      end
      members.each do |m|
        unless m =~ ACC_ID_PATTERN
          raise ArgumentError,
            "alias member #{m.inspect} is not a canonical acc_<16 hex> id"
        end
      end
      out = {
        "members" => members,
        "note"    => entry["note"].to_s
      }
      out["created_at"] = entry["created_at"] || Time.now.utc.iso8601
      out
    end
  end
end
