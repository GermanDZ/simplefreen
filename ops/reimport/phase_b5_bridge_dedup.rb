# Phase B.5 — dedup canonical v2-seq entries that ING re-emitted under
# two transactionSequences when a charge settled (the "seq-renumber";
# see docs/simplefin-bridge-architecture.md). Two upstream layers now
# prevent these from accumulating: the freentonic-providers ING
# normalizer collapse (collapse_pre_clearing_dups, same-fetch only,
# since 2026-05-23) and HistoryStore's cross-fetch supersession
# promotion (since 2026-05-27). With both in place new dups shouldn't
# appear, but this is NOT guaranteed-zero: it only catches same-(account,
# date, amount) prefix pairs, so it MISSES date-shifted renumbers and
# identical-description ones (filed as "real twins"). Keep it as a
# diagnostic + cleanup for dups that predate the supersession layer.
# NOTE: a delete here must be paired with a Sure-side entry-delete AND
# raw_transactions_payload scrub, or the row resurrects from Sure's cache.
#
# Heuristic: within a (account, date, amount) group of v2-seq entries:
#   - all descriptions identical (whitespace-normalized) → real twins, keep
#   - one description is a strict prefix of the longest → drop shorter
#   - mixed truly-different descriptions → keep all, flag for manual review
#
# Environment:
#   DATA   — bridge data root (default: /data)
#   SOURCE — source key (default: ING)
#   APPLY  — set to 1 to actually write; otherwise dry-run

require "json"
require "fileutils"
require "set"
require "time"

APPLY  = ENV["APPLY"] == "1"
DATA   = ENV["DATA"]   || "/data"
SOURCE = ENV["SOURCE"] || "ING"
HIST   = "#{DATA}/history/#{SOURCE}/history.json"

stamp  = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
backup = "#{HIST}.phase-b5-bak-#{stamp}"

hist = JSON.parse(File.read(HIST))

groups = Hash.new { |h, k| h[k] = [] }
hist["transactions"].each do |t|
  next unless t["source_id"].to_s.start_with?("v2-seq:")
  groups["#{t["account_id"]}|#{t["date"]}|#{t["amount"]}"] << t
end

dup_groups  = groups.select { |_, txs| txs.size > 1 }
real_twins  = []
prefix_dups = []
other_dups  = []
delete_ids  = []

dup_groups.each do |key, txs|
  cleaned = txs.map { |t| t["description"].to_s.strip.gsub(/\s+/, " ") }
  if cleaned.uniq.size == 1
    real_twins << { "key" => key, "count" => txs.size, "description" => cleaned[0][0, 80] }
    next
  end

  longest_idx = (0...cleaned.size).max_by { |i| cleaned[i].length }
  longest     = cleaned[longest_idx]
  prefix_matches = []
  not_prefix     = []
  txs.each_with_index do |t, i|
    next if i == longest_idx
    if longest.start_with?(cleaned[i]) && cleaned[i].length < longest.length
      prefix_matches << t
    else
      not_prefix << t
    end
  end

  if not_prefix.empty?
    prefix_dups << {
      "key"          => key,
      "keep_id"      => txs[longest_idx]["id"],
      "keep_desc"    => longest[0, 80],
      "delete_ids"   => prefix_matches.map { |t| t["id"] },
      "delete_descs" => prefix_matches.map { |t| t["description"].to_s.strip[0, 60] }
    }
    delete_ids.concat(prefix_matches.map { |t| t["id"] })
  else
    other_dups << {
      "key"          => key,
      "count"        => txs.size,
      "descriptions" => cleaned.map { |d| d[0, 60] }
    }
  end
end

puts "mode: #{APPLY ? 'APPLY' : 'DRY-RUN (set APPLY=1 to write)'}"
puts ""
puts "total v2-seq groups with size > 1: #{dup_groups.size}"
puts "  real twins (kept):              #{real_twins.size}"
puts "  prefix-dups (terse → delete):   #{prefix_dups.size}"
puts "  other-dups (review manually):   #{other_dups.size}"
puts ""
puts "transactions to delete: #{delete_ids.size}"

if real_twins.any?
  puts ""
  puts "=== real twins (preserved) ==="
  real_twins.first(20).each { |rt| puts "  #{rt["key"]}  count=#{rt["count"]}  #{rt["description"]}" }
end

if prefix_dups.any?
  puts ""
  puts "=== prefix-dups (terse forms being deleted) ==="
  prefix_dups.each do |pd|
    puts "  #{pd["key"]}"
    puts "    keep: #{pd["keep_id"]}  #{pd["keep_desc"]}"
    pd["delete_ids"].zip(pd["delete_descs"]).each { |id, desc| puts "    drop: #{id}  #{desc}" }
  end
end

if other_dups.any?
  puts ""
  puts "=== other-dups (unresolved — neither real-twin nor prefix-equivalent) ==="
  other_dups.each do |od|
    puts "  #{od["key"]}  count=#{od["count"]}"
    od["descriptions"].each { |d| puts "    #{d}" }
  end
end

unless APPLY
  puts ""
  puts "DRY-RUN. set APPLY=1 to write."
  exit 0
end

delete_set = delete_ids.to_set
new_txns   = hist["transactions"].reject { |t| delete_set.include?(t["id"]) }
puts ""
puts "transactions: #{hist["transactions"].size} → #{new_txns.size}  (delta -#{hist["transactions"].size - new_txns.size})"

if hist["tx_run_index"].is_a?(Hash)
  before_idx = hist["tx_run_index"].size
  hist["tx_run_index"].reject! { |id, _| delete_set.include?(id) }
  puts "tx_run_index: #{before_idx} → #{hist["tx_run_index"].size}"
end

hist["transactions"] = new_txns
hist["updated_at"]   = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")

FileUtils.cp(HIST, backup)
puts "backup: #{backup} (#{File.size(backup)} bytes)"

tmp = "#{HIST}.tmp.#{Process.pid}"
File.open(tmp, "w") { |f| f.write(JSON.pretty_generate(hist)) }
File.chmod(0o600, tmp) rescue nil
File.rename(tmp, HIST)
puts "wrote: #{HIST} (#{File.size(HIST)} bytes)"
