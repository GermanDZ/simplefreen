# frozen_string_literal: true

require "json"
require "time"
require "date"
require "set"

require_relative "atomic_file"
require_relative "paths"

module Simplefreen
  # Permanent per-profile transaction history. Where CacheStore holds the
  # latest *rendered* SimpleFIN envelope (ephemeral, GC'd) and RunLog keeps
  # the immutable per-run canonicals (pruned at 100 runs), HistoryStore is
  # the durable union of every transaction we've ever seen — deduped by
  # SimpleFIN txn id, with pending→posted promotions applied as later runs
  # observe them.
  #
  # Layout: <root>/history/<profile_key>/history.json
  #
  # Verified empirically against 25 ING runs (2,053/2,736 ids reappeared
  # across runs; 48 transitioned pending→posted with the id preserved;
  # only `source_id` was unstable — `id` is the right dedup key).
  #
  # Merge precedence on id collision:
  #   1. posted beats pending (a late backfill can't regress a posted txn)
  #   2. otherwise the new run wins (caller decides ordering)
  #
  # `accounts`, `liabilities`, `investments` are point-in-time snapshots and
  # are replaced wholesale from the most recently merged run.
  class HistoryStore
    SCHEMA_VERSION = "1"

    # Cross-fetch supersession ("renumber") detection. ING re-emits a
    # settled transaction under a NEW transactionSequence — hence a new
    # canonical id — when it clears, usually enriching the description and
    # occasionally shifting the date a day or two, while the provisional
    # version disappears from /search. Because the two halves land in
    # different runs, the per-fetch provider collapse never pairs them and
    # this never-pruned union would keep both — a duplicate that also
    # propagates downstream under two external_ids. We instead recognise the
    # confirmed row as an in-place promotion of the provisional, keeping the
    # original id so the union (and the consumer's external_id) stays stable.
    # Same-fetch prefix dups remain the provider's job (collapse_pre_clearing_dups).
    SUPERSEDE_DATE_WINDOW = 3   # max days between provisional and confirmed
    SUPERSEDE_MIN_DESC    = 5   # min normalized desc length to trust an overlap

    def initialize(root: Paths.root)
      @root = root
    end

    def path_for(key)
      Paths.history_path(key, @root)
    end

    def exists?(key)
      File.exist?(path_for(key))
    end

    # Returns the full history hash or nil if no history has been
    # accumulated yet for this profile.
    def read(key)
      AtomicFile.read_json(path_for(key))
    end

    # Lightweight stats for the admin UI's history panel. Returns nil if
    # the profile has no history yet; otherwise a hash:
    #   { txn_count:, last_tx_date:, last_run_id:, file_size_bytes:,
    #     updated_at:, created_at: }
    # All values are derived from a single read, so cost is one stat +
    # one JSON parse — fine to call from the profile-listing endpoint.
    def stats(key)
      hist = read(key) or return nil
      size = File.size(path_for(key)) rescue nil
      max_date = nil
      Array(hist["transactions"]).each do |t|
        d = t["date"]
        max_date = d if d.is_a?(String) && (max_date.nil? || d > max_date)
      end
      {
        "txn_count"       => Array(hist["transactions"]).size,
        "last_tx_date"    => max_date,
        "last_run_id"     => hist["last_run_id"],
        "file_size_bytes" => size,
        "updated_at"      => hist["updated_at"],
        "created_at"      => hist["created_at"]
      }
    end

    # ISO date string of the most recent transaction in history, or nil if
    # the profile has no history yet. Used by the scheduler to compute a
    # per-source incremental lookback window.
    def last_tx_date(key)
      hist = read(key) or return nil
      max = nil
      Array(hist["transactions"]).each do |t|
        d = t["date"]
        max = d if d.is_a?(String) && (max.nil? || d > max)
      end
      max
    end

    # Merge a canonical freentonic payload into the durable history for
    # this profile. Atomic read-modify-write under an advisory lock so two
    # concurrent pushes can't race the union. Returns the persisted hash.
    def merge_run!(key, run_id:, payload:)
      Paths.validate_component!(key, "profile_key")
      Paths.validate_component!(run_id, "run_id")
      raise ArgumentError, "payload must be a Hash" unless payload.is_a?(Hash)

      path = path_for(key)
      result = nil
      AtomicFile.update_json(path) do |current|
        base = current.nil? || current.empty? ? new_history(key) : current
        result = apply_run(base, key, run_id, payload)
      end
      result
    end

    # Drop the entire history for a profile. Operator-initiated reset only —
    # nothing in the normal sync flow should call this.
    def delete!(key)
      AtomicFile.delete(path_for(key))
    end

    # Rebuild a profile's history by replaying every canonical run file on
    # disk in mtime order (oldest first). Useful after a history.json
    # corruption or schema change. Returns the rebuilt hash, or nil if no
    # canonicals exist for the profile.
    def rebuild_from_runs!(key, runs_root: Paths.runs_dir(@root))
      Paths.validate_component!(key, "profile_key")
      dir = File.join(runs_root, key)
      return nil unless Dir.exist?(dir)
      canonicals = Dir.children(dir)
        .select { |n| n.end_with?(".canonical.json") && !n.end_with?(".canonical.meta.json") }
        .map { |n| File.join(dir, n) }
        .sort_by { |p| File.mtime(p).to_f }
      return nil if canonicals.empty?

      delete!(key)
      last = nil
      canonicals.each do |path|
        payload = AtomicFile.read_json(path) or next
        run_id = File.basename(path).sub(/\.canonical\.json\z/, "")
        last = merge_run!(key, run_id: run_id, payload: payload)
      end
      last
    end

    private

    def new_history(key)
      now = Time.now.utc.iso8601
      {
        "schema_version" => SCHEMA_VERSION,
        "profile_key"    => key,
        "created_at"     => now,
        "updated_at"     => now,
        "last_run_id"    => nil,
        "accounts"       => [],
        "transactions"   => [],
        "liabilities"    => [],
        "investments"    => [],
        # id => run_id that last wrote this txn (debug aid: tells you which
        # run introduced a given duplicate or status promotion)
        "tx_run_index"   => {}
      }
    end

    def apply_run(base, key, run_id, payload)
      txns_by_id = index_by_id(base["transactions"])
      run_index  = base["tx_run_index"] || {}

      incoming = Array(payload["transactions"]).select do |t|
        t["id"].is_a?(String) && !t["id"].empty?
      end
      incoming_ids = incoming.map { |t| t["id"] }.to_set

      # Provisional candidates for supersession: history rows that did NOT
      # reappear in this run (vanished from the latest fetch), indexed by
      # [account_id, amount-in-cents] so a confirmed row only scans rows of
      # the same signed amount. A row still present this run is live, not
      # superseded, so it's excluded — that's what keeps genuine same-amount
      # twins (both live) from being collapsed.
      candidates = Hash.new { |h, k| h[k] = [] }
      txns_by_id.each_value do |t|
        next if incoming_ids.include?(t["id"])
        c = cents(t["amount"]) or next
        candidates[[t["account_id"], c]] << t
      end
      used = {}   # provisional id => true; never reuse one provisional

      incoming.each do |new_tx|
        id = new_tx["id"]
        existing = txns_by_id[id]

        if existing
          # Same id: existing pending→posted promotion / amendment path.
          if prefer_new?(existing, new_tx)
            txns_by_id[id] = new_tx
            run_index[id]  = run_id
          end
          next
        end

        prov = find_superseded(candidates[[new_tx["account_id"], cents(new_tx["amount"])]], new_tx, used)
        if prov
          # Confirmed version of a vanished provisional: promote in place,
          # keeping the provisional's id (and the new id is never inserted)
          # so the union and downstream external_id stay stable.
          used[prov["id"]] = true
          txns_by_id[prov["id"]] = promote(prov, new_tx)
          run_index[prov["id"]]  = run_id
        else
          txns_by_id[id] = new_tx
          run_index[id]  = run_id
        end
      end

      {
        "schema_version" => SCHEMA_VERSION,
        "profile_key"    => key,
        "created_at"     => base["created_at"] || Time.now.utc.iso8601,
        "updated_at"     => Time.now.utc.iso8601,
        "last_run_id"    => run_id,
        # Account/liability/investment metadata are point-in-time
        # snapshots — replace wholesale from the most recent run.
        "accounts"       => Array(payload["accounts"]),
        "liabilities"    => Array(payload["liabilities"]),
        "investments"    => Array(payload["investments"]),
        "transactions"   => txns_by_id.values,
        "tx_run_index"   => run_index
      }
    end

    def index_by_id(txns)
      Array(txns).each_with_object({}) do |t, h|
        id = t["id"]
        h[id] = t if id.is_a?(String) && !id.empty?
      end
    end

    # Precedence: posted beats pending; otherwise the incoming run wins.
    # Same-status replacement matters when a later run corrects a posted
    # txn (rare, but real — banks do amend amounts/descriptions).
    def prefer_new?(existing, new_tx)
      e_status = existing["status"]
      n_status = new_tx["status"]
      return false if e_status == "posted" && n_status == "pending"
      true
    end

    # The single provisional row `new_tx` confirms, or nil. `candidates` are
    # already same-account/same-amount and vanished from this run; we add a
    # near-date and description prefix-overlap test, and refuse to act on an
    # ambiguous group (>1 match → keep them separate, let manual cleanup
    # decide). This is what rejects coincidental same-amount, different-
    # merchant pairs (no desc overlap).
    def find_superseded(candidates, new_tx, used)
      matches = candidates.select do |p|
        !used[p["id"]] &&
          date_within?(p["date"], new_tx["date"], SUPERSEDE_DATE_WINDOW) &&
          desc_overlap?(p["description"], new_tx["description"])
      end
      matches.size == 1 ? matches.first : nil
    end

    # The confirmed txn's content carried under the provisional's id, with
    # the superseded id/source_id/description appended to metadata.superseded
    # for traceability. The immutable per-run canonicals remain the full
    # audit, so overwriting the union row here loses nothing.
    def promote(prov, new_tx)
      trail = Array(prov.dig("metadata", "superseded")) + [{
        "id"          => prov["id"],
        "source_id"   => prov["source_id"],
        "description" => prov["description"],
        "date"        => prov["date"]
      }]
      meta = (new_tx["metadata"].is_a?(Hash) ? new_tx["metadata"] : {}).merge("superseded" => trail)
      new_tx.merge("id" => prov["id"], "metadata" => meta)
    end

    # Signed amount in integer cents, or nil if not numeric. Used as the
    # supersession match key so opposite-sign rows (charge vs refund) and
    # different amounts never pair.
    def cents(amount)
      return nil if amount.nil?
      (amount.to_f * 100).round
    end

    def date_within?(a, b, days)
      (Date.parse(a.to_s) - Date.parse(b.to_s)).to_i.abs <= days
    rescue ArgumentError, TypeError
      false
    end

    # Two descriptions overlap when, normalized, the shorter is a prefix of
    # the longer (covers identical too). Guarded by a minimum length so short
    # generic strings don't match spuriously.
    def desc_overlap?(a, b)
      na = normalize_desc(a)
      nb = normalize_desc(b)
      return false if na.length < SUPERSEDE_MIN_DESC || nb.length < SUPERSEDE_MIN_DESC
      long, short = na.length >= nb.length ? [na, nb] : [nb, na]
      long.start_with?(short)
    end

    def normalize_desc(s)
      s.to_s.upcase.gsub(/[^A-Z0-9]/, "")
    end
  end
end
