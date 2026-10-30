# Phase H — align Sure Entry dates with current bridge canonical.
#
# Why this exists: ING's two endpoints report different *semantic*
# date fields. V1ID-era /movements returns the merchant transaction
# date; v2-seq-era /v2/search returns the bank value date (matches
# XLS F. VALOR). When a posting moves from V1ID-era to v2-seq-era
# in the bridge canonical, its date shifts forward by 1 day for
# typical card postings. Sure's upsert path key on external_id —
# but does NOT update existing entries' `date` field. So Sure ends
# up with stale V1ID-era dates while the bridge canonical has the
# corrected v2-seq dates.
#
# This script reconciles: for every Sure entry whose external_id
# matches a bridge canonical txn_<hex>, UPDATE Sure's `date` to
# match the bridge's current date. Amount, sign, categorization
# are not touched.
#
# Inputs:
#   /tmp/canon_full.json — output of phase_a_bridge_full_canonical.rb
#                          (or any dump in the same shape).
#
# Usage:
#   docker exec <sure>    bin/rails runner phase_h_sure_date_sync_from_bridge.rb
#   docker exec -e APPLY=1 <sure> bin/rails runner phase_h_sure_date_sync_from_bridge.rb
#
# Env:
#   APPLY=1            → write (default dry-run)
#   CANON=path         → canonical dump path (default /tmp/canon_full.json)
#   CUTOFF=YYYY-MM-DD  → process entries dated >= cutoff (default 2025-01-01)

require "json"
require "set"

APPLY  = ENV["APPLY"] == "1"
CANON  = ENV["CANON"]  || "/tmp/canon_full.json"
CUTOFF = Date.parse(ENV["CUTOFF"] || "2025-01-01")

puts "mode: #{APPLY ? 'APPLY' : 'DRY-RUN'}"
puts "cutoff: #{CUTOFF}"
puts ""

canon = JSON.parse(File.read(CANON))
id_to_bridge = {}
canon.each_value { |txs| txs.each { |t| id_to_bridge[t["id"]] = t } }
puts "indexed #{id_to_bridge.size} bridge canonical entries"
puts ""

needs_update = []
aligned = 0
not_in_bridge = 0
drift_dist = Hash.new(0)
by_account = Hash.new { |h, k| h[k] = { update: 0, aligned: 0, orphan: 0 } }

Entry.where(source: "simplefin").where("date >= ?", CUTOFF).find_each do |e|
  next unless e.external_id&.start_with?("simplefin_")
  bare = e.external_id.sub("simplefin_", "")
  t = id_to_bridge[bare]
  if t.nil?
    not_in_bridge += 1
    by_account[e.account.name][:orphan] += 1
    next
  end
  bridge_date = Date.parse(t["date"])
  drift = (bridge_date - e.date).to_i
  if drift == 0
    aligned += 1
    by_account[e.account.name][:aligned] += 1
  else
    needs_update << { sure_id: e.id, bridge_date: t["date"], sure_date: e.date.to_s, drift: drift }
    by_account[e.account.name][:update] += 1
    drift_dist[drift] += 1
  end
end

puts "needs date update: #{needs_update.size}"
puts "already aligned:    #{aligned}"
puts "orphan (not in bridge — left alone): #{not_in_bridge}"
puts ""
puts "drift distribution (bridge_date - sure_date):"
drift_dist.sort.each { |d, n| puts "  #{d.to_s.rjust(4)}d  #{n}" }
puts ""
puts "by account:"
by_account.sort.each do |acc, h|
  puts "  #{acc.ljust(30)} update=#{h[:update].to_s.rjust(4)}  aligned=#{h[:aligned].to_s.rjust(4)}  orphan=#{h[:orphan].to_s.rjust(4)}"
end

if !APPLY
  puts ""
  puts "DRY-RUN — set APPLY=1 to commit"
  exit 0
end

puts ""
puts "applying… single transaction"
ApplicationRecord.transaction do
  needs_update.each do |row|
    Entry.find_by(id: row[:sure_id])&.update!(date: Date.parse(row[:bridge_date]))
  end
end
puts "updated #{needs_update.size} entries"
