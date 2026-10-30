# frozen_string_literal: true

require_relative "atomic_file"
require_relative "paths"

module Simplefreen
  # Persists per-group operator config used by the virtual-profile
  # serve path: primary-source pin, per-source date windows, and any
  # future per-group knobs. Keyed by the sorted member set so config
  # follows a group through sync runs as long as its membership is
  # unchanged. (Adding a new alias member to an existing group breaks
  # the lookup; the operator re-confirms the config in the UI, which
  # writes the new key. Predictable beats clever here.)
  #
  # Stored as a single JSON file at <root>/consolidation/groups.json:
  #
  #   {
  #     "version": 1,
  #     "groups": [
  #       {
  #         "members": ["acc_0123456789abcdef"],
  #         "primary": "ING",
  #         "windows": {
  #           "ING":      { "from": "2025-01-01", "to": null },
  #           "FINTONIC": { "from": null,         "to": "2024-12-31" }
  #         },
  #         "balance_override": "0.00",
  #         "updated_at": "2026-05-04T13:00:00Z"
  #       }
  #     ]
  #   }
  #
  # Volume is tiny (one entry per multi-source linked group the
  # operator has touched). The whole file is read on every virtual
  # `/accounts` request, so we keep it small and validate on write.
  class ConsolidationGroupsStore
    ACC_ID_PATTERN     = /\Aacc_[0-9a-f]{16}\z/
    DATE_PATTERN       = /\A\d{4}-\d{2}-\d{2}\z/
    DECIMAL_PATTERN    = /\A-?\d+(\.\d+)?\z/

    def initialize(root: Paths.root)
      @root = root
      Paths.ensure_layout!(@root)
    end

    def path
      Paths.consolidation_groups_path(@root)
    end

    # Returns Array of group-config Hashes. Empty when file is missing
    # or contains a non-Hash root. Never raises on missing file.
    def list
      data = AtomicFile.read_json(path)
      return [] unless data.is_a?(Hash)
      Array(data["groups"]).select { |e| e.is_a?(Hash) }
    end

    # O(1) lookup by member set. Caller passes sorted member ids; we
    # fold into a comparable shape before checking. Returns nil when
    # no config exists for this group.
    def find_by_members(members)
      key = canonical_members(members)
      return nil if key.empty?
      list.find { |g| canonical_members(g["members"]) == key }
    end

    # Replace the entire groups list. Each entry is normalized and
    # validated; an ArgumentError surfaces with a useful message so the
    # admin API can return 422 with the underlying detail.
    def replace(entries)
      normalized = Array(entries).map { |e| normalize!(e) }
      payload = {
        "version"    => 1,
        "groups"     => normalized,
        "updated_at" => Time.now.utc.iso8601
      }
      AtomicFile.write_json(path, payload)
      normalized
    end

    # Upsert one group config in place. Other groups in the file are
    # untouched. Used by the per-group editor in the UI: the operator
    # changes one group's windows and the UI PUTs that group; we
    # don't need to round-trip the whole list.
    def upsert(entry)
      normalized = normalize!(entry)
      key        = canonical_members(normalized["members"])
      current    = list
      idx        = current.index { |g| canonical_members(g["members"]) == key }
      if idx
        current[idx] = normalized
      else
        current << normalized
      end
      replace(current)
      normalized
    end

    # Remove a group config by member set. Idempotent: silently
    # succeeds if no entry matched.
    def delete_by_members(members)
      key = canonical_members(members)
      replace(list.reject { |g| canonical_members(g["members"]) == key })
    end

    private

    def normalize!(entry)
      raise ArgumentError, "group entry must be an object" unless entry.is_a?(Hash)
      members = canonical_members(entry["members"])
      raise ArgumentError, "group needs at least 1 member" if members.empty?
      members.each do |m|
        unless m =~ ACC_ID_PATTERN
          raise ArgumentError,
            "group member #{m.inspect} is not a canonical acc_<16 hex> id"
        end
      end

      primary = entry["primary"]
      if !primary.nil? && (!primary.is_a?(String) || primary.empty?)
        raise ArgumentError, "group primary must be a non-empty profile_key string or null"
      end

      windows = normalize_windows(entry["windows"])
      balance_override = normalize_balance_override(entry["balance_override"])

      out = {
        "members"    => members,
        "primary"    => primary,
        "windows"    => windows,
        "updated_at" => entry["updated_at"] || Time.now.utc.iso8601
      }
      out["balance_override"] = balance_override unless balance_override.nil?
      out
    end

    # Per-group balance override. Set to a decimal string (e.g. "0.00",
    # "-150.50") to replace the primary's balance in the consolidated
    # /accounts envelope. Use case: shared-debt credit cards where the
    # bank reports the same balance on multiple plastic-card accounts —
    # operator preserves all accounts (for per-card transaction
    # tracking) but zeroes out the duplicates so the downstream
    # aggregator (Sure.am, Actual) doesn't multi-count the debt.
    #
    # Accepts numeric or numeric-string; null/missing/empty disables.
    def normalize_balance_override(value)
      return nil if value.nil?
      return nil if value.is_a?(String) && value.strip.empty?
      str =
        case value
        when Integer, Float then format("%.2f", value)
        when String         then value.strip
        else
          raise ArgumentError, "balance_override must be a decimal string, number, or null"
        end
      unless str =~ DECIMAL_PATTERN
        raise ArgumentError, "balance_override must look like a decimal (got #{value.inspect})"
      end
      str
    end

    def canonical_members(value)
      Array(value).map { |m| m.to_s.strip }.reject(&:empty?).sort.uniq
    end

    def normalize_windows(value)
      return {} if value.nil?
      raise ArgumentError, "windows must be an object" unless value.is_a?(Hash)
      out = {}
      value.each do |source_pk, win|
        raise ArgumentError, "windows key must be a profile_key string" unless source_pk.is_a?(String)
        raise ArgumentError, "windows[#{source_pk}] must be an object" unless win.is_a?(Hash)
        from = win["from"]
        to   = win["to"]
        validate_date!(from, "windows[#{source_pk}].from")
        validate_date!(to,   "windows[#{source_pk}].to")
        if from && to && from > to
          raise ArgumentError, "windows[#{source_pk}]: from (#{from}) must be <= to (#{to})"
        end
        out[source_pk] = { "from" => from, "to" => to }
      end
      out
    end

    def validate_date!(value, label)
      return if value.nil?
      unless value.is_a?(String) && value =~ DATE_PATTERN
        raise ArgumentError, "#{label} must be a YYYY-MM-DD string or null (got #{value.inspect})"
      end
    end
  end
end
