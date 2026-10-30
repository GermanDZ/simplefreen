# frozen_string_literal: true

require "date"
require "set"

require_relative "reshape"
require_relative "consolidation"

module Simplefreen
  # Builds a SimpleFIN envelope merging canonicals from many source
  # profiles into a unified per-account view. The merge is driven by
  # operator-supplied per-group config (primary + windows) loaded from
  # ConsolidationGroupsStore.
  #
  # For each linked group:
  #
  #   - One SimpleFIN account is emitted using the primary source's
  #     `acc_<hex>` (stable id; doesn't flip when membership grows).
  #   - Account metadata (name, balance, currency, org) comes from
  #     the primary's record.
  #   - Transactions are the union of each contributing source's txns,
  #     filtered by that source's window from the group config. Default
  #     when no window is configured for a source: primary takes ALL
  #     dates, secondaries take NONE (primary-only behavior).
  #   - Within overlap regions where two sources both have configured
  #     windows covering the same dates, transactions are deduped by
  #     bucket (date, amount, currency, normalized_description) using
  #     the conservative rule: emit primary's, plus any secondary
  #     surplus per bucket. See README of #merge_group_transactions.
  #
  # Singleton accounts (one source) pass through unchanged.
  #
  # The module is pure: callers marshal in canonicals + groups + group
  # config, and a list of source profile records (used for org-name
  # resolution via Reshape::INSTITUTION_METADATA).
  module ConsolidatedReshape
    module_function

    Result = Data.define(:envelope, :warnings)

    Warning = Data.define(:kind, :group_members, :message)

    # Per-group preview shape returned by preview_group: detailed counts
    # of what the merge would emit for a candidate config without
    # actually serving the envelope. Lets the UI show "if you save
    # these windows, you'd get N txns from primary, M from secondary,
    # K bucket-collapses" before persisting.
    GroupPreview = Data.define(
      :primary_pk,
      :sources,                  # [{profile_key, in_window, out_of_window}]
      :bucket_stats,             # {matched_collapsed, primary_only, secondary_only_emitted, secondary_surplus_emitted, primary_surplus_kept}
      :estimated_emit_count,
      :sample_collisions,        # [{date, amount, currency, primary_desc, secondary_desc, sources}] — first N where descs differ
      :warnings
    )

    # Build the consolidated SimpleFIN envelope. Returns Result with
    # the envelope and a list of operator-facing warnings (overlap,
    # gap, out-of-coverage).
    def call(canonicals_by_profile:, aliases:, group_configs:, profile_records: {})
      groups = Consolidation.build_groups(canonicals_by_profile, aliases: aliases)
      configs_by_key = index_configs(group_configs)
      coverage = Consolidation.send(:build_signatures, canonicals_by_profile)

      accounts = []
      warnings = []

      groups.each do |group|
        next if group.linked_via == :dangling   # nothing to serve
        config = configs_by_key[config_key_for(group)]
        primary, primary_pk = resolve_primary(group, config)
        next unless primary                     # no contributing source

        windows  = resolve_windows(group, config)
        merged   = merge_group_transactions(group, canonicals_by_profile, primary_pk, windows)
        warnings.concat(group_warnings(group, windows, canonicals_by_profile))

        accounts << build_account(group, primary, primary_pk, merged, profile_records, config)
      end

      envelope = { "accounts" => accounts, "errors" => [] }
      Result.new(envelope: envelope, warnings: warnings)
    end

    # Preview the merge for a candidate group config without
    # persisting or emitting. Returns a GroupPreview with counts the
    # editor UI uses to show "what you'd get" before save.
    #
    # `members` is the sorted-acc_<hex>-id list; `primary_pk` is the
    # operator's pinned primary or nil for heuristic; `windows` is the
    # per-source `{from, to}` map (same shape as the persisted config's
    # `windows` field).
    def preview_group(canonicals_by_profile:, aliases:, members:, primary_pk:, windows:, sample_size: 5)
      groups = Consolidation.build_groups(canonicals_by_profile, aliases: aliases)
      group = groups.find { |g| g.members.sort == Array(members).map(&:to_s).sort }
      return nil unless group

      # Resolve primary the same way the serve path does, so preview
      # output matches what serve would later produce.
      effective_config = {
        "members" => group.members,
        "primary" => primary_pk,
        "windows" => windows || {}
      }
      _primary_account, resolved_primary_pk = resolve_primary(group, effective_config)
      return nil unless resolved_primary_pk
      resolved_windows = resolve_windows(group, effective_config)

      # Per-source in/out window counts.
      sources_stats = group.sources.map do |s|
        pk = s.profile_key.to_s
        win = resolved_windows[pk]
        all_txs = Array(canonicals_by_profile[s.profile_key]&.dig("transactions"))
          .select { |t| t.is_a?(Hash) && t["account_id"] == s.account["id"] }
        if win.nil? || win["default_empty"]
          { "profile_key" => pk, "in_window" => 0, "out_of_window" => all_txs.size, "skipped" => true }
        else
          in_w  = all_txs.count { |t| in_window?(t["date"], win) }
          { "profile_key" => pk, "in_window" => in_w, "out_of_window" => all_txs.size - in_w, "skipped" => false }
        end
      end

      # Run the same bucket walk as merge_group_transactions, but
      # count outcomes per bucket instead of emitting.
      pairs = collect_filtered(group, canonicals_by_profile, resolved_windows)
      buckets = pairs.group_by { |(_pk, t)| signature(t) }

      stats = {
        "matched_collapsed"          => 0,  # primary_count == secondary_count, collapsed to primary's
        "primary_only"               => 0,  # bucket only present in primary (no secondary)
        "secondary_only_emitted"     => 0,  # bucket only present in secondary (gap-fill)
        "secondary_surplus_emitted"  => 0,  # surplus emitted because s_count > p_count
        "primary_surplus_kept"       => 0   # primary count > secondary count; primary's full count emits
      }
      sample_collisions = []

      buckets.each do |sig_key, items|
        primary_items = items.select { |(pk, _)| pk == resolved_primary_pk }
        secondary_items_by_pk = items.group_by(&:first).reject { |pk, _| pk == resolved_primary_pk }

        if primary_items.empty?
          stats["secondary_only_emitted"] += items.size
        else
          # All buckets emit primary's items
          if secondary_items_by_pk.empty?
            stats["primary_only"] += primary_items.size
          else
            # Mixed bucket
            secondary_items_by_pk.each do |sec_pk, sec_items|
              p = primary_items.size
              s = sec_items.size
              if s > p
                stats["matched_collapsed"]         += p
                stats["secondary_surplus_emitted"] += (s - p)
              elsif s == p
                stats["matched_collapsed"] += p
              else
                stats["matched_collapsed"]      += s
                stats["primary_surplus_kept"]   += (p - s)
              end
              # Sample: surface the first few buckets where primary &
              # secondary descriptions diverge, so the operator can
              # eyeball whether the dedup will be cosmetically clean.
              if sample_collisions.size < sample_size
                pcount = [p, s].min
                primary_items.first(pcount).zip(sec_items.first(pcount)).each do |pi, si|
                  next unless pi && si
                  pd = normalize_desc(pi.last["raw_description"] || pi.last["description"])
                  sd = normalize_desc(si.last["raw_description"] || si.last["description"])
                  next if pd == sd
                  sample_collisions << {
                    "date"           => sig_key[0],
                    "amount"         => sig_key[1],
                    "currency"       => sig_key[2],
                    "primary_desc"   => pi.last["raw_description"] || pi.last["description"] || "",
                    "secondary_desc" => si.last["raw_description"] || si.last["description"] || "",
                    "secondary_pk"   => sec_pk
                  }
                  break if sample_collisions.size >= sample_size
                end
              end
            end
          end
        end
      end

      estimated_emit_count = stats["matched_collapsed"] +
                             stats["primary_only"] +
                             stats["secondary_only_emitted"] +
                             stats["secondary_surplus_emitted"] +
                             stats["primary_surplus_kept"]

      GroupPreview.new(
        primary_pk: resolved_primary_pk,
        sources: sources_stats,
        bucket_stats: stats,
        estimated_emit_count: estimated_emit_count,
        sample_collisions: sample_collisions,
        warnings: group_warnings(group, resolved_windows, canonicals_by_profile).map { |w|
          { "kind" => w.kind.to_s, "message" => w.message }
        }
      )
    end

    # ── grouping config resolution ──────────────────────────

    def config_key_for(group)
      group.members.sort.join(",")
    end

    def index_configs(group_configs)
      out = {}
      Array(group_configs).each do |c|
        members = Array(c.is_a?(Hash) ? c["members"] : nil).map(&:to_s).sort
        out[members.join(",")] = c if members.any?
      end
      out
    end

    # Resolve which source is primary for a group, returning [account
    # hash, profile_key]. Order of preference:
    #   1. Operator-pinned `primary` from group config (if it's actually
    #      a contributing source).
    #   2. group.suggested_primary (the IBAN-prefers heuristic).
    # Returns [nil, nil] if the group has no sources at all.
    def resolve_primary(group, config)
      pinned = config && config["primary"]
      if pinned
        match = group.sources.find { |s| s.profile_key.to_s == pinned.to_s }
        return [match.account, match.profile_key] if match
        # Pinned profile no longer contributing — fall through to heuristic
        # rather than emitting nothing.
      end
      sp = group.suggested_primary
      sp ? [sp.account, sp.profile_key] : [nil, nil]
    end

    # Resolve per-source window for a group. Sources without an explicit
    # entry in config["windows"] default to: primary gets the unbounded
    # window (`{from: nil, to: nil}`), secondaries get the empty window
    # (`{from: nil, to: nil, default_empty: true}` — sentinel meaning
    # "skip everything from this source").
    def resolve_windows(group, config)
      configured = (config && config["windows"]) || {}
      out = {}
      group.sources.each do |s|
        pk = s.profile_key.to_s
        if configured.key?(pk)
          out[pk] = configured[pk].merge("default_empty" => false)
        else
          out[pk] = { "from" => nil, "to" => nil, "default_empty" => true }
        end
      end
      # If NO source has a configured window, fall back to primary-only:
      # primary gets unbounded, secondaries get empty (already the default).
      # If at least one source IS configured, keep all defaults as empty
      # — the operator opted in to multi-source by configuring at least
      # one window, and any source they didn't configure is intentionally
      # excluded.
      #
      # Primary resolution here MUST match resolve_primary's preference
      # order — the operator's pinned `primary` wins over the heuristic.
      # Earlier this branch only consulted `suggested_primary`, so a
      # config of `primary: "fintonic", windows: {}` (operator wants
      # fintonic-only, no per-date split) silently unbounded ING (the
      # heuristic-suggested primary) and emitted ING's contribution
      # (often zero for empty card slots) instead of fintonic's.
      if configured.empty?
        pinned = config && config["primary"]
        primary_pk = pinned && !pinned.to_s.empty? ? pinned.to_s :
                     (group.suggested_primary&.profile_key || group.sources.first.profile_key).to_s
        if (win = out[primary_pk])
          out[primary_pk] = win.merge("default_empty" => false)
        end
      end
      out
    end

    # ── merge ───────────────────────────────────────────────

    # For each linked group, walk every contributing source's txns and:
    #   - filter to those falling in this source's window
    #   - bucket-dedup overlap regions by (date, amount, currency, normalized_desc)
    #
    # Bucket rule (conservative; biases toward emitting more, never less):
    #   Let p = primary's txn count in bucket, s_i = each secondary i's
    #   count in bucket.
    #   1. Emit all p primary txns.
    #   2. For each secondary i:
    #        if p == 0:           emit all s_i (primary missed it)
    #        elsif s_i > p:       emit (s_i - p) extras (the surplus, by
    #                              ordinal; secondaries beyond primary's
    #                              count are novel events the primary
    #                              didn't capture)
    #        else:                emit nothing (secondary fully covered
    #                              by primary; collapse the duplicate)
    #
    # Result is sorted by (date desc, then by stable per-source order).
    def merge_group_transactions(group, canonicals, primary_pk, windows)
      pairs = collect_filtered(group, canonicals, windows)
      buckets = pairs.group_by { |(_pk, t)| signature(t) }

      out = []
      buckets.each_value do |items|
        primary_items = items.select { |(pk, _)| pk == primary_pk }
        if primary_items.empty?
          # No primary in bucket — emit each source's items
          items.each { |(_pk, t)| out << t }
        else
          out.concat(primary_items.map(&:last))
          # Walk secondaries (each profile_key in turn), emit surplus
          items.group_by(&:first).each do |pk, src_items|
            next if pk == primary_pk
            extras = src_items.size - primary_items.size
            next if extras <= 0
            out.concat(src_items.last(extras).map(&:last))
          end
        end
      end

      out.sort_by { |t| t["date"].to_s }.reverse
    end

    # Build the [(profile_key, txn)] list, filtered by each source's
    # window. Source order is determined by the group's source list
    # (alphabetical by profile_key) so dedup ordinals are stable.
    def collect_filtered(group, canonicals, windows)
      pairs = []
      group.sources.each do |src|
        pk  = src.profile_key.to_s
        win = windows[pk]
        next if !win || win["default_empty"]
        canonical = canonicals[src.profile_key] || canonicals[pk]
        next unless canonical.is_a?(Hash)
        Array(canonical["transactions"]).each do |t|
          next unless t.is_a?(Hash)
          next unless t["account_id"] == src.account["id"]
          next unless in_window?(t["date"], win)
          pairs << [pk, t]
        end
      end
      pairs
    end

    def in_window?(date_str, win)
      return false if date_str.to_s.empty?
      from = win["from"]
      to   = win["to"]
      return false if from && date_str < from
      return false if to   && date_str > to
      true
    end

    # Bucket key is intentionally `(date, amount, currency)` only.
    # Descriptions are NOT in the key — they routinely differ across
    # providers describing the same event (Fintonic strips merchant
    # city, ING includes it, etc.) and including text would split
    # cosmetic duplicates into separate buckets, defeating the whole
    # cross-provider dedup. Description-divergence within a collapsed
    # bucket is surfaced separately as `sample_collisions` so the
    # operator can eyeball before saving.
    def signature(t)
      [t["date"].to_s, t["amount"].to_s, t["currency"].to_s]
    end

    # Light normalization for the sample-collision detector only —
    # used to decide whether two descriptions are "the same enough"
    # for the operator to tag as a cosmetic divergence vs. a real
    # difference. Not part of the bucket key.
    def normalize_desc(desc)
      desc.to_s.strip.gsub(/\s+/, " ")
    end

    # ── account emission ────────────────────────────────────

    def build_account(group, primary_account, primary_pk, transactions, profile_records, config = nil)
      institution = primary_account["institution"].to_s
      meta = Reshape::INSTITUTION_METADATA[institution]
      org =
        if meta
          { "name" => meta[:name], "domain" => meta[:domain],
            "sfin-url" => meta[:url], "url" => meta[:url], "id" => institution }
        else
          fallback = institution.empty? ? primary_pk.to_s : institution
          { "name" => fallback, "domain" => "#{fallback}.local",
            "sfin-url" => "about:blank", "url" => "about:blank", "id" => fallback }
        end

      # SimpleFIN's `balance` field is required and Actual rejects accounts
      # whose `balance` is null with "must have either current or available
      # balance". Some providers (notably Fintonic credit cards) surface
      # neither — prefer `current`, fall back to `available`, and finally
      # to "0.00" so the account still appears in Actual instead of being
      # dropped silently. Operators can correct the figure manually.
      current   = normalize_decimal(primary_account.dig("balance", "current"))
      available = normalize_decimal(primary_account.dig("balance", "available"))
      override  = normalize_decimal(config && config["balance_override"])
      # Per-group balance override: when the same shared debt is reported
      # by the bank on multiple plastic-card accounts (e.g. ING's joint
      # credit card billed to one debt account but issued as several
      # cards), the operator zeroes out all but one group so the
      # downstream aggregator doesn't multi-count the balance. Available
      # is suppressed too — re-deriving it in this branch would just
      # reintroduce the duplicate the override is meant to eliminate.
      balance   = override || current || available || "0.00"

      reshaped_txs = transactions.map { |t| reshape_tx(t) }.compact

      extra = {
        "consolidated_primary_source" => primary_pk.to_s,
        "consolidated_member_count"   => group.members.size,
        "consolidated_source_count"   => group.sources.size,
        "consolidated_sources"        => group.sources.map { |s| s.profile_key.to_s }.sort
      }
      # See reshape.rb: forward canonical account.type so consumers can
      # auto-classify (Spanish names like "Tarjeta Crédito" or "hipoteca"
      # don't match downstream English-keyword inference).
      canonical_type = primary_account["type"].to_s
      extra["account-type"] = canonical_type unless canonical_type.empty?

      acc = {
        "id"            => primary_account["id"],
        "name"          => primary_account["name"].to_s,
        "currency"      => primary_account["currency"].to_s,
        "balance"       => balance,
        "balance-date"  => to_unix(primary_account.dig("balance", "timestamp")) || Time.now.to_i,
        "org"           => org,
        "transactions"  => reshaped_txs,
        "extra"         => extra
      }

      # Skip available-balance when an override is in effect: emitting
      # the unmodified raw `available` would re-leak the duplicated
      # balance that the override was set to suppress.
      acc["available-balance"] = available if available && available != balance && override.nil?
      acc["extra"]["balance_override"] = override if override
      acc
    end

    def reshape_tx(t)
      return nil unless t.is_a?(Hash)
      id = t["id"]
      return nil unless id.is_a?(String) && id.start_with?("txn_")
      amount = normalize_decimal(t["amount"])
      return nil unless amount

      # Mirror Reshape::SERVED_STATUSES. The consolidated endpoint has
      # its own envelope-assembly path and was missing this filter, so
      # Revolut DECLINED/FAILED/REVERTED canonical rows reached clients
      # via /simplefin/consolidated while /simplefin/<source> already
      # dropped them.
      return nil unless Reshape::SERVED_STATUSES.include?(t["status"])

      pending  = t["status"] == "pending"
      raw_post = to_unix(t["date"])
      out = {
        "id"          => id,
        "posted"      => pending ? 0 : (raw_post || 0),
        "amount"      => amount,
        "description" => (t["description"] || t["raw_description"] || "").to_s
      }
      transacted = to_unix(t["value_date"]) || raw_post
      out["transacted_at"] = transacted if transacted
      out["pending"] = true if pending
      # Mirror Reshape.build_tx_extra: emit payee + bank_movement_id
      # (the canonical source_id) as a stable secondary dedup key. See
      # reshape.rb for the rationale; this path takes the primary
      # source's canonical txn — the one whose `id` we emit — so
      # `bank_movement_id` is that same source's bank-side ref.
      extra = {}
      if (payee = t.dig("merchant", "name")) && !payee.to_s.empty?
        extra["payee"] = payee.to_s
      end
      sid = t["source_id"]
      extra["bank_movement_id"] = sid if sid.is_a?(String) && !sid.empty?
      out["extra"] = extra unless extra.empty?
      out
    end

    def normalize_decimal(value)
      case value
      when String  then s = value.strip; s.empty? ? nil : s
      when Integer, Float then format("%.2f", value)
      else nil
      end
    end

    def to_unix(value)
      case value
      when nil           then nil
      when Integer       then value
      when String        then Time.parse(value).to_i
      when Time          then value.to_i
      else nil
      end
    rescue ArgumentError
      nil
    end

    # ── warnings ────────────────────────────────────────────

    # Emit operator-facing warnings for a group's window config:
    #   - overlap:           two sources cover the same date range
    #   - gap:               there's a hole in the timeline coverage
    #   - out_of_coverage:   a window's `from` is before the source's
    #                        actually-available data
    #
    # All are advisory; the merge proceeds anyway. The UI displays them
    # next to the group's editor.
    def group_warnings(group, windows, canonicals)
      out = []
      configured = windows.reject { |_pk, w| w["default_empty"] }
      return out if configured.size < 2  # warnings only meaningful with >=2 windows

      ranges = configured.map { |pk, w| [pk, [w["from"], w["to"]]] }

      # Pairwise overlap detection
      ranges.combination(2).each do |(pk_a, (fa, ta)), (pk_b, (fb, tb))|
        ovl = overlap_range(fa, ta, fb, tb)
        next unless ovl
        out << Warning.new(
          kind: :overlap,
          group_members: group.members,
          message: "#{pk_a} and #{pk_b} both cover #{ovl[0] || '~'}..#{ovl[1] || '~'}; duplicates in this range will be conservatively merged."
        )
      end

      # Gap: union of ranges should cover [earliest range start, today]
      gap = first_gap_in(ranges)
      if gap
        out << Warning.new(
          kind: :gap,
          group_members: group.members,
          message: "No source covers #{gap[0]}..#{gap[1]}; that period will be empty in the merged view."
        )
      end

      # Out-of-coverage: per-source `from` before that source's earliest tx
      configured.each do |pk, w|
        from = w["from"]
        next if from.nil?
        earliest = earliest_tx_date(canonicals, pk, group.sources)
        next unless earliest && from < earliest
        out << Warning.new(
          kind: :out_of_coverage,
          group_members: group.members,
          message: "#{pk} window starts #{from} but its earliest available txn for this account is #{earliest}; older dates won't appear from #{pk}."
        )
      end

      out
    end

    # Compute [from, to] of the intersection of two date ranges. nil
    # bounds are treated as -inf / +inf. Returns nil when ranges don't
    # overlap.
    def overlap_range(fa, ta, fb, tb)
      lo = [fa, fb].compact.max
      hi_candidates = [ta, tb].compact
      hi = hi_candidates.empty? ? nil : hi_candidates.min
      if lo && hi && lo > hi
        return nil
      end
      [lo, hi]
    end

    # Find the first gap in coverage. Sort ranges by start, sweep
    # forward, return the first uncovered interval (start, end).
    # Treats nil-from as -infinity (sentinel "0000-01-01" which sorts
    # earlier than any real ISO date); nil-to as today.
    def first_gap_in(ranges)
      today = Date.today.iso8601
      neg_inf = "0000-01-01"
      effective = ranges.map { |_, (f, t)| [f || neg_inf, t || today] }.sort_by(&:first)
      return nil if effective.empty?

      cursor = effective.first[0]
      effective.each do |(f, t)|
        if f > next_day(cursor)
          gap_start = next_day(cursor)
          gap_end   = prev_day(f)
          return [gap_start, gap_end]
        end
        cursor = max_str(cursor, t)
      end
      nil
    end

    def earliest_tx_date(canonicals, profile_pk, group_sources)
      src = group_sources.find { |s| s.profile_key.to_s == profile_pk.to_s }
      return nil unless src
      canonical = canonicals[src.profile_key] || canonicals[profile_pk]
      return nil unless canonical.is_a?(Hash)
      dates = Array(canonical["transactions"])
        .select { |t| t.is_a?(Hash) && t["account_id"] == src.account["id"] }
        .map { |t| t["date"].to_s }
        .reject(&:empty?)
      dates.min
    end

    def prev_day(date_str)
      (Date.parse(date_str) - 1).iso8601
    rescue StandardError
      date_str
    end

    def next_day(date_str)
      (Date.parse(date_str) + 1).iso8601
    rescue StandardError
      date_str
    end

    def max_str(a, b)
      a > b ? a : b
    end
  end
end
