# Triple diff: bank XLS  vs  bridge canonical  vs  Sure entries.
#
# Surfaces:
#   - rows in XLS but missing from Sure (consumer not yet synced or
#     a stale orphan with wrong date/external_id)
#   - rows in Sure with no XLS match (V1ID-era leftovers, phantoms,
#     or excluded entries the user opted out of)
#   - rows in XLS but missing from BRIDGE canonical (upstream provider
#     gap — most concerning; investigate the provider's extractor)
#   - count mismatches (real bank-side twin postings — same key,
#     multiple distinct postings)
#
# Inputs:
#   /tmp/xls_rows_full.json — output of build_xls_dataset.py
#   /tmp/canon_full.json    — output of phase_a_bridge_full_canonical.rb
#
# Matching is by (date_iso, |amount|.round(2)) per Sure account. The
# sign convention difference between bank XLS (debit = -) and Sure
# (debit = +; see docs/simplefin-bridge-architecture.md) is sidestepped
# by comparing absolute values. Description text is for display only.
#
# Usage:
#   docker exec <sure>    bin/rails runner xls_diff_full.rb

require "json"
require "set"

XLS   = ENV["XLS"]   || "/tmp/xls_rows_full.json"
CANON = ENV["CANON"] || "/tmp/canon_full.json"
data  = JSON.parse(File.read(XLS))
canon = JSON.parse(File.read(CANON))
cutoff = Date.parse(data["cutoff_from"])

cash_acc = Account.where("id::text LIKE ?", "#{data["cash_account_app_id"]}%").first
cc_acc   = Account.where("id::text LIKE ?", "#{data["cc_account_app_id"]}%").first

sure_acc_to_bridge = Hash.new { |h, k| h[k] = [] }
SimplefinAccount.all.each do |sfa|
  acc = Account.where(simplefin_account_id: sfa.id).first
  next unless acc
  sure_acc_to_bridge[acc.id] << sfa.account_id
end

def key_of(date, amount)
  [date.to_s, format("%.2f", amount.to_f.abs)]
end

def diff_account(account, xls_rows, canon, sure_acc_to_bridge, cutoff, label)
  return puts("=== #{label}: account not found ===") unless account

  xls_idx = Hash.new { |h, k| h[k] = [] }
  xls_rows.each { |r| xls_idx[key_of(r["date"], r["amount"])] << r }

  sure_entries = Entry.where(account_id: account.id, source: "simplefin")
                      .where("date >= ?", cutoff).to_a
  sure_idx = Hash.new { |h, k| h[k] = [] }
  sure_entries.each { |e| sure_idx[key_of(e.date.to_s, e.amount.to_f)] << e }

  bridge_entries = []
  (sure_acc_to_bridge[account.id] || []).each do |bacc|
    (canon[bacc] || []).each do |t|
      next if Date.parse(t["date"]) < cutoff
      bridge_entries << t
    end
  end
  bridge_idx = Hash.new { |h, k| h[k] = [] }
  bridge_entries.each { |t| bridge_idx[key_of(t["date"], t["amount"])] << t }

  missing_sure = []
  missing_bridge = []
  extra_sure = []
  matched = 0

  xls_idx.each do |k, xls_here|
    sure_here = sure_idx[k]
    bridge_here = bridge_idx[k]
    if bridge_here.empty?
      xls_here.each { |r| missing_bridge << r }
    end
    if sure_here.empty?
      xls_here.each { |r| missing_sure << r }
    elsif xls_here.size > sure_here.size
      (xls_here.size - sure_here.size).times { missing_sure << xls_here.first }
      matched += sure_here.size
    else
      matched += xls_here.size
    end
  end

  sure_idx.each do |k, entries|
    xls_here = xls_idx[k]
    next if entries.size <= xls_here.size
    (entries.size - xls_here.size).times { extra_sure << entries.first }
  end

  puts "=== #{label} (since #{cutoff}) ==="
  puts "  XLS rows:     #{xls_rows.size}"
  puts "  Bridge rows:  #{bridge_entries.size}"
  puts "  Sure entries: #{sure_entries.size}"
  puts "  matched:      #{matched}"
  puts "  missing in Sure:   #{missing_sure.size}"
  puts "  missing in Bridge: #{missing_bridge.size}  (← upstream gap if > 0)"
  puts "  extra in Sure:     #{extra_sure.size}"
  puts ""

  if missing_sure.any?
    puts "  MISSING IN SURE (first 20):"
    missing_sure.first(20).each do |r|
      in_bridge = bridge_idx[key_of(r["date"], r["amount"])].any? ? "in_bridge" : "NOT_in_bridge"
      puts "    #{r["date"]}  #{format("%9.2f", r["amount"])}  [#{in_bridge}]  #{r["description"][0,55]}"
    end
    puts ""
  end

  if missing_bridge.any?
    puts "  MISSING IN BRIDGE (first 20) — upstream gap:"
    missing_bridge.first(20).each do |r|
      puts "    #{r["date"]}  #{format("%9.2f", r["amount"])}  #{r["description"][0,55]}"
    end
    puts ""
  end

  if extra_sure.any?
    puts "  EXTRA IN SURE (first 20):"
    extra_sure.first(20).each do |e|
      excl  = e.excluded ? "[excl]" : ""
      bmid  = e.entryable.respond_to?(:extra) && e.entryable.extra.is_a?(Hash) ?
              e.entryable.extra.dig("simplefin", "extra", "bank_movement_id").to_s : ""
      v1id  = bmid.include?("V1ID") ? "[V1ID]" : ""
      cat   = e.entryable.respond_to?(:category) ? (e.entryable.category&.name || "-") : "-"
      puts "    #{e.date}  #{format("%9.2f", e.amount)}  #{excl}#{v1id}  cat=#{cat[0,15].ljust(15)}  #{e.name.to_s[0,40]}"
    end
    puts ""
  end
end

diff_account(cash_acc, data["cash_rows"], canon, sure_acc_to_bridge, cutoff, "CASH")
diff_account(cc_acc,   data["cc_rows"],   canon, sure_acc_to_bridge, cutoff, "CC")
