# frozen_string_literal: true

require "set"

module Simplefreen
  # Read-only consolidation layer over canonical envelopes from many
  # profiles. Groups accounts that represent the same physical bank
  # account using two link sources:
  #
  #   1. automatic — identical acc_<hex> across profiles. Works whenever
  #      freentonic produces a portable_ref (see Canonical.account_id).
  #      Example: ING (IBAN ES…1465…1234) and Fintonic (1465:1234)
  #      both hash to the same acc_<hex>; they auto-link.
  #
  #   2. manual — operator-supplied alias entries pairing two acc_<hex>
  #      ids that the operator has confirmed represent the same physical
  #      account. Used when the upstream cannot expose a portable
  #      identifier (e.g. Fintonic accounts that come back with an opaque
  #      resourceId hash for non-major Spanish banks).
  #
  # Output is a list of groups; each group lists every (profile_key,
  # account) pair contributing to it plus a suggested primary source
  # (the source whose data should be considered authoritative). Single-
  # source accounts surface as singleton groups so callers can iterate
  # uniformly.
  #
  # This module is **pure**: no I/O, no module-level state. Callers
  # marshal in canonical envelopes (typically loaded by RunLog) and the
  # alias list (loaded by ConsolidationStore).
  module Consolidation
    AccountSource = Data.define(:profile_key, :account, :txn_count)
    Group         = Data.define(:id, :sources, :suggested_primary, :linked_via, :members)

    # A cross-profile pair of accounts that look like the same physical
    # account based on transaction overlap, but aren't yet linked
    # (neither via portable_ref nor via a manual alias). `confidence`
    # is overlap / min(a_total, b_total) — i.e. "of the side with
    # fewer transactions, how much of its stream is also in the other
    # side". This surfaces aggregator↔direct pairs where the
    # aggregator returns a shorter window than the direct provider
    # (Fintonic vs Unicaja: 6 txns vs 19 — perfect 6/6 inclusion is a
    # very high confidence even though absolute coverage is 6/19).
    # `samples` is a small set of overlapping transactions for the
    # operator to eyeball before clicking Link.
    Suggestion = Data.define(:profile_a, :account_a,
                             :profile_b, :account_b,
                             :overlap, :a_total, :b_total,
                             :confidence, :samples)

    # Tunables — exposed as kwargs on suggest_matches so callers can
    # widen the net on demand without code changes. Defaults err on the
    # conservative side: we want suggestions to be obviously right.
    DEFAULT_MIN_OVERLAP    = 3
    DEFAULT_MIN_CONFIDENCE = 0.5
    DEFAULT_SAMPLE_SIZE    = 3

    # Institutions that aggregate other banks rather than serving one
    # directly. When a linked group has both an aggregator and a direct
    # provider AND no other tiebreaker differentiates them (no IBAN on
    # either side; happens for cards), the direct provider wins as
    # suggested primary because:
    #   - direct providers carry richer descriptions for card txns
    #     (merchant city, full reference codes) — observed empirically
    #     in the user's ING vs Fintonic credit-card data;
    #   - aggregators add value as a historical backfill via per-source
    #     date windows, not as the authoritative recent-data source.
    # Future: replace this constant with a per-profile `aggregator_role`
    # flag (sketched in docs/virtual-profile-design.md slice 2).
    AGGREGATOR_INSTITUTIONS = %w[fintonic].freeze

    module_function

    # Build linked groups from a hash of {profile_key => canonical_envelope}
    # plus an array of alias entries. An alias entry is a Hash with a
    # "members" array of acc_<hex> ids; every pair listed in the same
    # alias entry joins the same union-find group.
    #
    # Returns an Array of Group records, ordered: multi-source groups
    # first (most sources first), then singletons (alphabetical by id).
    def build_groups(canonicals_by_profile, aliases: [])
      sources_by_acc = collect_sources(canonicals_by_profile)
      uf             = UnionFind.new(sources_by_acc.keys)

      # Auto-links are implicit — same acc_<hex> already maps to one
      # union-find node, no explicit edge needed. Manual aliases add
      # cross-id edges.
      Array(aliases).each do |entry|
        members = Array(entry.is_a?(Hash) ? entry["members"] : nil).select { |m| m.is_a?(String) }
        next if members.size < 2
        ensure_known(uf, members)
        members.each_cons(2) { |a, b| uf.union(a, b) }
      end

      # Group account ids by their union-find root. An id may not be
      # present in any canonical (e.g. an alias references an account
      # that no longer syncs); we still surface it so the operator can
      # see the dangling reference and clean up.
      groups_by_root = Hash.new { |h, k| h[k] = [] }
      uf.members.each do |id|
        groups_by_root[uf.find(id)] << id
      end

      groups = groups_by_root.values.map do |member_ids|
        sources = member_ids.flat_map { |id| sources_by_acc[id] || [] }
        linked_via =
          if sources.empty?
            :dangling
          elsif member_ids.size == 1 && sources.size == 1
            :singleton
          elsif member_ids.size > 1
            :alias
          else
            :portable_ref
          end
        Group.new(
          id:                canonical_group_id(member_ids),
          sources:           sources.sort_by { |s| s.profile_key.to_s },
          suggested_primary: pick_primary(sources),
          linked_via:        linked_via,
          members:           member_ids.sort
        )
      end

      groups.sort_by do |g|
        # Multi-source first (largest sources count first), then
        # singletons / dangling alphabetically by group id.
        [-g.sources.size, g.id.to_s]
      end
    end

    # Cross-profile match suggester. For every pair of accounts owned
    # by different profiles that are not already in the same group,
    # build a signature set of (date, amount, currency) tuples from
    # each side's transactions and compute their intersection. Pairs
    # whose overlap clears `min_overlap` and `min_confidence` are
    # returned ranked by confidence.
    #
    # This is the discovery surface for accounts whose upstream cannot
    # produce a portable_ref. The Unicaja↔Fintonic case (Fintonic emits
    # an opaque resourceId hash for the underlying Unicaja account) is
    # the canonical example: there's no shared identifier, but the
    # transaction streams overlap nearly 1:1.
    def suggest_matches(canonicals_by_profile, existing_groups,
                        min_overlap:    DEFAULT_MIN_OVERLAP,
                        min_confidence: DEFAULT_MIN_CONFIDENCE,
                        sample_size:    DEFAULT_SAMPLE_SIZE)
      sigs_by_pair = build_signatures(canonicals_by_profile)
      group_of = group_index(existing_groups)
      acc_meta = account_metadata_index(canonicals_by_profile)

      # Group (profile, acc_id) keys by profile so we only enumerate
      # cross-profile pairs (intra-profile pairs can't represent the
      # same physical account — would be a within-provider duplicate
      # and is the freentonic team's problem to fix).
      by_profile = Hash.new { |h, k| h[k] = [] }
      sigs_by_pair.each_key { |(pk, aid)| by_profile[pk] << aid }

      suggestions = []
      profile_keys = by_profile.keys.sort
      profile_keys.combination(2) do |pa, pb|
        by_profile[pa].each do |a|
          a_sig = sigs_by_pair[[pa, a]]
          next if a_sig.empty?
          by_profile[pb].each do |b|
            # Already linked (same group via portable_ref or alias)?
            # Skip — we don't want to suggest what's already a fact.
            next if group_of[a] && group_of[a] == group_of[b]
            b_sig = sigs_by_pair[[pb, b]]
            next if b_sig.empty?

            overlap = (a_sig & b_sig).size
            next if overlap < min_overlap

            smaller = [a_sig.size, b_sig.size].min
            confidence = overlap.to_f / smaller
            next if confidence < min_confidence

            samples = (a_sig & b_sig).first(sample_size).map do |(date, amount, currency)|
              { "date" => date, "amount" => amount, "currency" => currency }
            end

            suggestions << Suggestion.new(
              profile_a:  pa,  account_a: acc_meta[[pa, a]],
              profile_b:  pb,  account_b: acc_meta[[pb, b]],
              overlap:    overlap,
              a_total:    a_sig.size,
              b_total:    b_sig.size,
              confidence: confidence,
              samples:    samples
            )
          end
        end
      end

      suggestions.sort_by { |s| [-s.confidence, -s.overlap, s.account_a["id"].to_s] }
    end

    # Build {profile_key => canonical_envelope} by reading each profile's
    # durable HistoryStore record (the union of every run, deduped by
    # txn id). Convenience wrapper for callers that have a Feature in
    # hand. Returns {} if no profile has any history yet.
    #
    # HistoryStore is the source — not RunLog#latest_canonical — so the
    # admin previews and the SimpleFIN serve path agree on the same
    # durable union, and an incremental short-lookback run can't shrink
    # the previewed view to just its window. The HistoryStore record has
    # the same {accounts, transactions, liabilities, investments} shape
    # the downstream Consolidation / Reshape consumers expect.
    #
    # `apply_source_hidden` (default true) drops accounts (and their
    # transactions) that the source profile has marked in its
    # hidden_accounts list. Operators expect a hide on a source profile
    # to take effect everywhere — raw /simplefin emit, virtual /simplefin
    # emit, and the admin preview/groups views — so default is to hide.
    # Pass false only when the caller specifically needs the unfiltered
    # canonical (e.g. listing what was hidden, for the export-preview
    # admin endpoint).
    def load_canonicals(feature, apply_source_hidden: true)
      out = {}
      feature.profile_store.list.each do |profile|
        key = profile["profile_key"]
        canonical = feature.history_store.read(key)
        next unless canonical
        if apply_source_hidden
          hidden = Array(profile["hidden_accounts"])
          canonical = filter_canonical_hidden(canonical, hidden) if hidden.any?
        end
        out[key] = canonical
      end
      out
    end

    # Drop accounts (and their transactions) by id. Pure helper; reusable
    # both as the inline default-on filter inside load_canonicals and as
    # an explicit step for callers that load raw canonicals first
    # (e.g. the export-preview admin endpoint, which needs to compute the
    # suppression list using account names from the un-filtered envelope
    # before discarding those rows).
    def filter_canonical_hidden(canonical, hidden_ids)
      return canonical unless canonical.is_a?(Hash)
      return canonical if hidden_ids.empty?
      canonical.merge(
        "accounts"     => Array(canonical["accounts"]).reject     { |a| hidden_ids.include?(a["id"]) },
        "transactions" => Array(canonical["transactions"]).reject { |t| hidden_ids.include?(t["account_id"]) }
      )
    end

    # ── private ─────────────────────────────────────────────

    def collect_sources(canonicals_by_profile)
      acc = Hash.new { |h, k| h[k] = [] }
      canonicals_by_profile.each do |profile_key, canonical|
        next unless canonical.is_a?(Hash)
        txns_per_acc = Array(canonical["transactions"]).each_with_object(Hash.new(0)) do |t, h|
          aid = t.is_a?(Hash) ? t["account_id"] : nil
          h[aid] += 1 if aid
        end
        Array(canonical["accounts"]).each do |account|
          next unless account.is_a?(Hash) && account["id"].is_a?(String)
          acc[account["id"]] << AccountSource.new(
            profile_key: profile_key,
            account:     account,
            txn_count:   txns_per_acc[account["id"]] || 0
          )
        end
      end
      acc
    end

    # Build {[profile_key, acc_id] => Set<[date, amount, currency]>}
    # from every canonical's transactions. Currency is folded into the
    # signature so a -100.00 EUR doesn't accidentally match a -100.00
    # USD on a multi-currency aggregator.
    def build_signatures(canonicals_by_profile)
      sigs = Hash.new { |h, k| h[k] = [] }
      canonicals_by_profile.each do |pk, canonical|
        next unless canonical.is_a?(Hash)
        Array(canonical["transactions"]).each do |t|
          next unless t.is_a?(Hash)
          aid = t["account_id"]
          next unless aid.is_a?(String)
          date     = t["date"].to_s
          amount   = t["amount"].to_s
          currency = t["currency"].to_s
          next if date.empty? || amount.empty?
          sigs[[pk, aid]] << [date, amount, currency]
        end
      end
      # Set semantics: dedup signatures within an account. Multiple
      # txns sharing (date, amount, currency) within ONE provider
      # collapse to a single signature so they don't double-count
      # against an aggregator that didn't emit the duplicate.
      sigs.each_value(&:uniq!)
      sigs.transform_values(&:to_set)
    end

    def group_index(existing_groups)
      out = {}
      Array(existing_groups).each do |g|
        members = g.respond_to?(:members) ? g.members : (g.is_a?(Hash) ? g["members"] : nil)
        gid     = g.respond_to?(:id)      ? g.id      : (g.is_a?(Hash) ? g["id"]      : nil)
        Array(members).each { |m| out[m] = gid }
      end
      out
    end

    def account_metadata_index(canonicals_by_profile)
      out = {}
      canonicals_by_profile.each do |pk, c|
        next unless c.is_a?(Hash)
        Array(c["accounts"]).each do |a|
          next unless a.is_a?(Hash) && a["id"]
          out[[pk, a["id"]]] = a
        end
      end
      out
    end

    # Heuristic primary-source pick. Sort key, lowest wins:
    #   1. IBAN-bearer (typically a direct provider) before non-IBAN
    #   2. non-aggregator before aggregator (for groups where neither
    #      side has an IBAN — common for credit-card pairs — the
    #      direct provider wins over the aggregator)
    #   3. profile_key alphabetical (determinism)
    # The operator can pin a different primary per group via the
    # consolidation groups config; this is just the default.
    #
    # Earlier revisions of this method used `-txn_count` as a tiebreaker
    # ("richer recent activity"). That was non-deterministic across syncs:
    # whenever two sources tied on iban+aggregator (the only branch txn_count
    # ever decided), a pending tx dropping off or a new posting landing on
    # the other source could flip the primary. Downstream consumers
    # (Sure Finances et al.) dedupe by SimpleFIN `txn_id`, and a flipped
    # primary emits a different `txn_<hex>` for the same physical posting,
    # creating duplicate transactions on every flip. See
    # test_pick_primary_stable_when_txn_count_flips_across_syncs.
    def pick_primary(sources)
      return nil if sources.empty?
      sources.min_by do |s|
        iban_present  = !s.account["iban"].to_s.strip.empty?
        is_aggregator = AGGREGATOR_INSTITUTIONS.include?(s.account["institution"].to_s)
        [iban_present ? 0 : 1, is_aggregator ? 1 : 0, s.profile_key.to_s]
      end
    end

    def canonical_group_id(member_ids)
      member_ids.sort.first || "(empty)"
    end

    def ensure_known(uf, members)
      members.each { |m| uf.add(m) unless uf.known?(m) }
    end

    # Tiny union-find. Path compression on find; union-by-rank on union.
    # Local to Consolidation so we don't take on a runtime dependency
    # for a 30-line algorithm.
    class UnionFind
      def initialize(initial_members = [])
        @parent = {}
        @rank   = Hash.new(0)
        Array(initial_members).each { |m| add(m) }
      end

      def add(member)
        @parent[member] ||= member
      end

      def known?(member)
        @parent.key?(member)
      end

      def members
        @parent.keys
      end

      def find(member)
        add(member) unless @parent.key?(member)
        root = member
        root = @parent[root] while @parent[root] != root
        # Path compression: re-point everyone we touched directly to root.
        node = member
        while @parent[node] != root
          nxt = @parent[node]
          @parent[node] = root
          node = nxt
        end
        root
      end

      def union(a, b)
        ra, rb = find(a), find(b)
        return if ra == rb
        if @rank[ra] < @rank[rb]
          @parent[ra] = rb
        elsif @rank[ra] > @rank[rb]
          @parent[rb] = ra
        else
          @parent[rb] = ra
          @rank[ra]  += 1
        end
      end
    end
  end
end
