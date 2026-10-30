# Phase G — Sure-side V1ID-orphan cleanup with category transfer.
#
# Why this script exists, separate from Phase C:
#
# Phase C handles V1ID-orphans where the v2-seq counterpart sits on
# the SAME (account, date, amount) key — `expected_by_key` finds them
# and the remap is trivial. But ING's two endpoints actually report
# different *semantic* date fields:
#   - /movements (V1ID era):       merchant transaction date
#   - /v2/search (v2-seq era):     bank value date  (matches XLS F. VALOR)
# This produces a systematic +1d shift on most postings: the V1ID-era
# orphan is dated D, the v2-seq counterpart is dated D+1. Phase C's
# strict (date, amount) match misses these and leaves them in the
# `historical_no_bridge_link` bucket where Phase C does NOT touch
# them — but they ARE duplicates of v2-seq entries that already exist
# in Sure with a different date.
#
# This script bridges that gap. For each Sure entry NOT in any bridge
# canonical (by external_id), it looks for a near-match in the same
# Sure account (±3 days, |amount|, description prefix-overlap), checks
# whether the near-match is ALREADY a Sure Entry, and:
#
#   - pure_dup_delete  → orphan and its bridge counterpart both in
#                        Sure → DELETE the orphan, transferring its
#                        category/merchant/notes/user_modified to the
#                        keeper if the keeper's fields are empty.
#   - remap_to_bridge  → bridge counterpart NOT yet in Sure → rename
#                        the orphan to the bridge's txn_<hex>.
#   - truly_orphan     → no near-match anywhere → LEAVE as-is.
#                        Likely an Adicional/cancelled-CC charge that
#                        v2-seq can't reach (see
#                        feedback_v1id_orphan_handling.md).
#
# Inputs:
#   /tmp/canon_full.json — output of phase_a_bridge_full_canonical.rb
#                          { bridge_acc_id => [ {id, date, amount,
#                                                description, src} … ] }
#
# Usage:
#   docker exec <sure>    bin/rails runner phase_g_sure_v1id_orphan_cleanup.rb
#   docker exec -e APPLY=1 <sure> bin/rails runner phase_g_sure_v1id_orphan_cleanup.rb
#
# Env:
#   APPLY=1            → actually delete (default dry-run)
#   CANON=path         → canonical dump path (default /tmp/canon_full.json)
#   CUTOFF=YYYY-MM-DD  → process Sure entries dated >= cutoff (default 2025-01-01)

require "json"
require "set"

APPLY  = ENV["APPLY"] == "1"
CANON  = ENV["CANON"]  || "/tmp/canon_full.json"
CUTOFF = Date.parse(ENV["CUTOFF"] || "2025-01-01")

puts "mode: #{APPLY ? 'APPLY' : 'DRY-RUN'}"
puts "cutoff: #{CUTOFF}"
puts ""

canon = JSON.parse(File.read(CANON))

# Build: Sure Account.id -> [bridge acc_<hex>...]
sure_acc_to_bridge = Hash.new { |h, k| h[k] = [] }
SimplefinAccount.all.each do |sfa|
  acc = Account.where(simplefin_account_id: sfa.id).first
  next unless acc
  sure_acc_to_bridge[acc.id] << sfa.account_id
end

# Per-Sure-Account index keyed by |amount|.round(2)
txn_idx = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = [] } }
sure_acc_to_bridge.each do |sure_acc_id, bridge_accs|
  bridge_accs.each do |bacc|
    (canon[bacc] || []).each do |t|
      txn_idx[sure_acc_id][t["amount"].to_f.abs.round(2)] << t
    end
  end
end

bridge_ids = Set.new
canon.each_value { |txs| txs.each { |t| bridge_ids.add(t["id"]) } }

def normalize_desc(s)
  s.to_s.upcase.gsub(/^PAGO EN\s+/, "").gsub(/^ABONOS? EN\s+/, "").gsub(/[^A-Z0-9]/, "")
end

pure_dup    = []
remap       = []
truly       = []
skipped_non_v1id = 0

Entry.where(source: "simplefin").where("date >= ?", CUTOFF).find_each do |e|
  next unless e.external_id&.start_with?("simplefin_")
  bare = e.external_id.sub("simplefin_", "")
  next if bridge_ids.include?(bare)

  bmid = e.entryable.respond_to?(:extra) && e.entryable.extra.is_a?(Hash) ?
         e.entryable.extra.dig("simplefin", "extra", "bank_movement_id").to_s : ""
  unless bmid.include?("V1ID")
    skipped_non_v1id += 1
    next
  end

  candidates = txn_idx[e.account_id][e.amount.to_f.abs.round(2)]
  near = candidates.select { |c| (Date.parse(c["date"]) - e.date).to_i.abs <= 3 }
  sure_norm = normalize_desc(e.name)
  matches = near.select do |c|
    cn = normalize_desc(c["description"])
    sure_norm.length >= 6 && cn.length >= 6 &&
      (sure_norm.start_with?(cn[0,12]) || cn.start_with?(sure_norm[0,12]))
  end

  if matches.empty?
    truly << e
    next
  end

  ing_match = matches.find { |m| m["src"] == "ING" } || matches.first
  sure_existing = Entry.find_by(account_id: e.account_id, external_id: "simplefin_#{ing_match["id"]}")
  if sure_existing
    pure_dup << { orphan: e, keeper: sure_existing, target: ing_match }
  else
    remap << { orphan: e, target: ing_match }
  end
end

puts "=== classification ==="
puts "pure_dup_delete (bridge counterpart in Sure → delete orphan): #{pure_dup.size}"
puts "remap_to_bridge (rename orphan to bridge txn_<hex>):           #{remap.size}"
puts "truly_orphan    (no bridge match — leave in place):            #{truly.size}"
puts "skipped (non-V1ID):                                            #{skipped_non_v1id}"
puts ""

richness_xfers = { category: 0, merchant: 0, notes: 0, user_modified: 0 }
both_diff_cat = []
pure_dup.each do |row|
  o = row[:orphan]; k = row[:keeper]
  o_t = o.entryable; k_t = k.entryable
  if o_t.respond_to?(:category_id) && o_t.category_id && k_t.category_id.nil?
    richness_xfers[:category] += 1
  elsif o_t.respond_to?(:category_id) && o_t.category_id && k_t.category_id && o_t.category_id != k_t.category_id
    both_diff_cat << row
  end
  if o_t.respond_to?(:merchant_id) && o_t.merchant_id && k_t.merchant_id.nil?
    richness_xfers[:merchant] += 1
  end
  if !o.notes.to_s.strip.empty? && k.notes.to_s.strip.empty?
    richness_xfers[:notes] += 1
  end
  if o.user_modified && !k.user_modified
    richness_xfers[:user_modified] += 1
  end
end
puts "field transfers planned (orphan → keeper, only when keeper field is empty):"
richness_xfers.each { |k, n| puts "  #{k.to_s.ljust(20)} #{n}" }
puts "both categorized differently (will leave keeper as-is): #{both_diff_cat.size}"
both_diff_cat.first(10).each do |r|
  oc = Category.find_by(id: r[:orphan].entryable.category_id)&.name
  kc = Category.find_by(id: r[:keeper].entryable.category_id)&.name
  puts "  #{r[:orphan].date} amt=#{sprintf("%9.2f", r[:orphan].amount)} orphan=#{oc} vs keeper=#{kc}  #{r[:orphan].name.to_s[0,40]}"
end
puts ""

unless APPLY
  puts "DRY-RUN — set APPLY=1 to commit"
  exit 0
end

puts "applying… all changes wrapped in ApplicationRecord.transaction"
applied = { deleted: 0, remapped: 0, transferred: 0 }
ApplicationRecord.transaction do
  pure_dup.each do |row|
    o = row[:orphan]; k = row[:keeper]
    o_t = o.entryable; k_t = k.entryable
    if o_t.respond_to?(:category_id) && o_t.category_id && k_t.category_id.nil?
      k_t.update!(category_id: o_t.category_id)
      applied[:transferred] += 1
    end
    if o_t.respond_to?(:merchant_id) && o_t.merchant_id && k_t.merchant_id.nil?
      k_t.update!(merchant_id: o_t.merchant_id)
    end
    if !o.notes.to_s.strip.empty? && k.notes.to_s.strip.empty?
      k.update!(notes: o.notes)
    end
    if o.user_modified && !k.user_modified
      k.update!(user_modified: true)
    end
    o.destroy!
    applied[:deleted] += 1
  end

  remap.each do |row|
    row[:orphan].update!(external_id: "simplefin_#{row[:target]["id"]}")
    applied[:remapped] += 1
  end
end
puts "done. deleted=#{applied[:deleted]}  remapped=#{applied[:remapped]}  cat_transfers=#{applied[:transferred]}"
