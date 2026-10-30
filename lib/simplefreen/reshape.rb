# frozen_string_literal: true

require "time"

module Simplefreen
  # Converts a freentonic canonical envelope (schema_version "0.1") into
  # the SimpleFIN wire envelope that Actual Budget's `src/app-simplefin`
  # adapter expects.
  #
  # Canonical input (top-level):
  #
  #   { "schema_version": "0.1",
  #     "summary": { ... }, "meta": { ... },
  #     "accounts": [
  #       { "id":          "acc_a1b2c3d4e5f60718",
  #         "institution": "ing",
  #         "name":        "Cuenta Naranja",
  #         "currency":    "EUR",
  #         "balance":     { "current": "1500.20",
  #                          "available": "1450.00",
  #                          "timestamp": "2026-04-23T10:00:00Z" } } ],
  #     "transactions": [
  #       { "id":          "txn_4a5b6c7d8e9f0a1b",
  #         "account_id":  "acc_a1b2c3d4e5f60718",
  #         "date":        "2026-04-20",
  #         "value_date":  "2026-04-21",
  #         "amount":      "-45.20",
  #         "currency":    "EUR",
  #         "description": "Amazon",
  #         "status":      "posted",
  #         "merchant":    { "name": "Amazon", "normalized": true } } ] }
  #
  # SimpleFIN output:
  #
  #   { "errors": [],
  #     "accounts": [
  #       { "id":           "acc_a1b2c3d4e5f60718",
  #         "org":          { "name": "ING España", "domain": "ing.es",
  #                           "url": "https://www.ing.es", ... },
  #         "currency":     "EUR",
  #         "balance":      "1500.20",
  #         "balance-date": 1713780000,
  #         "transactions": [
  #           { "id":          "txn_4a5b6c7d8e9f0a1b",
  #             "posted":      1713621600,
  #             "amount":      "-45.20",
  #             "description": "Amazon",
  #             "extra":       { "payee": "Amazon" } } ] } ] }
  module Reshape
    # Presentation metadata for Actual Budget's CreateAccountModal. Canonical
    # only carries the institution slug (`"ing"`); Actual reads `org.domain`
    # / `org.url` / `org.name` too. Keep the mapping here so the canonical
    # payload itself doesn't have to carry display-only fields.
    INSTITUTION_METADATA = {
      "ing"      => { name: "ING España", domain: "ing.es",      url: "https://www.ing.es" },
      "revolut"  => { name: "Revolut",    domain: "revolut.com", url: "https://www.revolut.com" },
      "fintonic" => { name: "Fintonic",   domain: "fintonic.com", url: "https://www.fintonic.com" },
      "unicaja"  => { name: "Unicaja",    domain: "unicajabanco.es", url: "https://www.unicajabanco.es" }
    }.freeze

    module_function

    # Convert a canonical envelope into a SimpleFIN envelope. Returns a
    # Hash. Accounts missing required canonical fields (id, currency,
    # balance.current) surface in `errors` and are NOT included in
    # `accounts`. Orphan transactions (account_id unknown) are logged
    # into `errors` and skipped.
    def call(canonical)
      envelope = { "accounts" => [], "errors" => [] }
      return envelope unless canonical.is_a?(Hash)

      accounts = Array(canonical["accounts"])
      account_ids = accounts.each_with_object({}) do |a, h|
        id = a["id"] if a.is_a?(Hash)
        h[id] = true if id
      end

      txs_by_account = Hash.new { |h, k| h[k] = [] }
      Array(canonical["transactions"]).each do |tx|
        next unless tx.is_a?(Hash)
        aid = tx["account_id"]
        if aid && account_ids[aid]
          txs_by_account[aid] << tx
        else
          envelope["errors"] << "simplefin: orphan transaction #{tx["id"].inspect} for unknown account_id #{aid.inspect}"
        end
      end

      accounts.each do |account|
        reshape_account(account, txs_by_account[account.is_a?(Hash) ? account["id"] : nil] || [], envelope)
      end
      envelope
    end

    # Filter transactions by the SimpleFIN query params (start-date,
    # end-date, pending). The caller is responsible for parsing the
    # raw query string; this takes an already-parsed Hash.
    #
    # `serve_floor_ts` is an optional Unix timestamp the server enforces
    # as a hard lower bound regardless of what the client requested:
    # `effective_start = max(client_start, serve_floor)`. Used to clamp
    # the consolidated feed to e.g. last-90-days so a fresh-install
    # client can't pull years of history in one sync.
    def apply_query(envelope, params, serve_floor_ts: nil)
      return envelope unless envelope.is_a?(Hash) && envelope["accounts"].is_a?(Array)

      start_ts = params[:start_date] || params["start-date"]
      end_ts   = params[:end_date]   || params["end-date"]
      pending  = params[:pending]    || params["pending"]
      balances_only = params[:balances_only] || params["balances-only"]
      account_filter = Array(params[:account] || params["account"])

      start_ts = Integer(start_ts) rescue nil
      end_ts   = Integer(end_ts) rescue nil
      if serve_floor_ts
        start_ts = start_ts ? [start_ts, serve_floor_ts].max : serve_floor_ts
      end
      pending_allowed = truthy?(pending)

      accounts = envelope["accounts"].map do |account|
        next nil if account_filter.any? && !account_filter.include?(account["id"])
        reduced = account.dup
        txs = Array(account["transactions"])
        if balances_only && truthy?(balances_only)
          reduced["transactions"] = []
        else
          reduced["transactions"] = txs.select do |tx|
            posted = tx["posted"]
            next false unless posted.is_a?(Integer)
            is_pending = tx["pending"] == true
            next false if is_pending && !pending_allowed
            # Per spec, pending transactions have `posted: 0` (no settled
            # time yet). Don't apply start/end date filtering to them —
            # a client asking for `?start-date=X&pending=1` expects to
            # see pending items even though their nominal post date is 0.
            unless is_pending
              next false if start_ts && posted < start_ts
              next false if end_ts   && posted > end_ts
            end
            true
          end
        end
        reduced
      end.compact

      envelope.merge("accounts" => accounts)
    end

    # ── private helpers ─────────────────────────────────────

    def reshape_account(account, transactions, envelope)
      unless account.is_a?(Hash)
        envelope["errors"] << "simplefin: non-hash account in payload"
        return
      end

      id = account["id"]
      unless id.is_a?(String) && id.start_with?("acc_")
        envelope["errors"] << "simplefin: account missing canonical id (expected acc_<hex>)"
        return
      end

      currency = account["currency"].to_s
      unless currency.match?(/\A[A-Z]{3}\z/)
        envelope["errors"] << "simplefin: account #{id} missing ISO 4217 currency"
        return
      end

      balance = normalize_decimal(account.dig("balance", "current"))
      unless balance
        envelope["errors"] << "simplefin: account #{id} missing balance.current"
        return
      end

      # balance-date: prefer whatever the provider captured. If canonical
      # doesn't carry one (the bank didn't surface it), fall back to "now"
      # so Actual still ingests the account. Timestamp-of-capture is an
      # approximation field, not a ledger value — safer than dropping.
      balance_date = to_unix(account.dig("balance", "timestamp")) || Time.now.to_i

      reshaped_txs = transactions.map { |tx| reshape_transaction(tx) }.compact

      # Forward canonical `account.type` ("checking"/"savings"/"credit_card"/
      # "loan"/"investment"/...) into SimpleFIN's free-form `extra` bag so
      # downstream consumers (Actual forks, sure.am) can auto-classify
      # accounts whose names aren't in English. SimpleFIN spec doesn't
      # define a top-level type field; `extra` is the agreed escape hatch.
      extra = {}
      canonical_type = account["type"].to_s
      extra["account-type"] = canonical_type unless canonical_type.empty?

      account_hash = {
        "id"            => id,
        "name"          => (account["name"] || id).to_s,
        "currency"      => currency,
        "balance"       => balance,
        "balance-date"  => balance_date,
        "org"           => org_for(account),
        "transactions"  => reshaped_txs,
        "extra"         => extra
      }

      # SimpleFIN spec: available-balance is optional and MUST be omitted
      # when equal to balance.
      available = normalize_decimal(account.dig("balance", "available"))
      account_hash["available-balance"] = available if available && available != balance

      envelope["accounts"] << account_hash
    end

    # SimpleFIN serves money-moving postings only. The canonical layer
    # preserves the full event log for some providers — Revolut emits a
    # canonical Transaction for every leg in its event stream, including
    # DECLINED card-payment retries, REVERTED transfers, and FAILED
    # top-ups.
    # Drop those here so downstream clients (Actual, sure.am, …) see
    # exactly what the bank statement shows.
    #
    # nil is admitted: providers that don't yet map upstream state to a
    # canonical status (ING, fintonic, UNICAJA at time of writing) send
    # nil and represent only money-moving rows. The Revolut normalizer
    # also returns nil for upstream states it doesn't recognize, so an
    # unknown future Revolut state name reaches clients as a regular row
    # rather than vanishing — better to surface a possibly
    # mis-categorized posting than to silently lose money-moving data.
    SERVED_STATUSES = [nil, "posted", "pending"].freeze

    def reshape_transaction(tx)
      return nil unless tx.is_a?(Hash)

      id = tx["id"]
      return nil unless id.is_a?(String) && id.start_with?("txn_")

      amount = normalize_decimal(tx["amount"])
      return nil unless amount

      status = tx["status"]
      return nil unless SERVED_STATUSES.include?(status)

      is_pending = status == "pending"

      # SimpleFIN spec: pending transactions MUST have `posted: 0`. Real
      # posting time is unknown until the bank settles; keep the raw date
      # in transacted_at so downstream consumers can render something.
      raw_posted = to_unix(tx["date"])
      posted = is_pending ? 0 : (raw_posted || 0)

      description = (tx["description"] || tx["raw_description"] || "").to_s

      out = {
        "id"          => id,
        "posted"      => posted,
        "amount"      => amount,
        "description" => description
      }

      transacted = to_unix(tx["value_date"]) || raw_posted
      out["transacted_at"] = transacted if transacted

      out["pending"] = true if is_pending

      out["extra"] = build_tx_extra(tx)
      out.delete("extra") if out["extra"].empty?

      out
    end

    # SimpleFIN's `extra` is the spec-blessed escape hatch for
    # org-specific keys. We populate two:
    #
    #   - `payee` — the canonical merchant name (when normalized).
    #   - `bank_movement_id` — the canonical `transaction.source_id`,
    #     verbatim. This is a stable secondary dedup key for downstream
    #     clients that key by SimpleFIN `id` but want defense-in-depth
    #     against any future scenario where the bridge has to rotate
    #     `id` (e.g. a primary-source flip in ConsolidatedReshape, a
    #     normalizer revision that re-derives ids). The value is the
    #     same blob the bank surfaced; downstream may use it for cross-
    #     reference but should not assume any particular format.
    def build_tx_extra(tx)
      extra = {}
      if (payee = tx.dig("merchant", "name")) && !payee.to_s.empty?
        extra["payee"] = payee.to_s
      end
      sid = tx["source_id"]
      extra["bank_movement_id"] = sid if sid.is_a?(String) && !sid.empty?
      extra
    end

    # Canonical money is a decimal string (e.g. "-45.20"). Accept numerics
    # defensively — a pre-v0.4 envelope slipping through the receiver
    # guard should still reshape rather than silently drop — but keep the
    # string path zero-cost (no parse-and-reformat round trip).
    def normalize_decimal(value)
      case value
      when String
        s = value.strip
        return nil if s.empty?
        s
      when Integer, Float
        format("%.2f", value)
      else
        nil
      end
    end

    def to_unix(value)
      case value
      when nil
        nil
      when Integer
        value
      when String
        Time.parse(value).to_i
      when Time
        value.to_i
      else
        nil
      end
    rescue ArgumentError
      nil
    end

    def org_for(account)
      slug = account["institution"].to_s
      meta = INSTITUTION_METADATA[slug]
      if meta
        {
          "name"     => meta[:name],
          "domain"   => meta[:domain],
          "sfin-url" => meta[:url],
          "url"      => meta[:url],
          "id"       => slug
        }
      else
        fallback = slug.empty? ? "freentonic" : slug
        {
          "name"     => fallback,
          "domain"   => "#{fallback}.local",
          "sfin-url" => "about:blank",
          "url"      => "about:blank",
          "id"       => fallback
        }
      end
    end

    def truthy?(value)
      return true  if value == true
      return false if value == false || value.nil?
      %w[1 true yes on].include?(value.to_s.downcase)
    end
  end
end
