# Phase A — bridge side, multi-source consolidation-aware.
#
# Reads ALL per-source canonicals at #{DATA}/history/*/history.json and
# the consolidation groups config at #{DATA}/consolidation/groups.json,
# then computes — for every (account_id, date, amount) tuple that has
# at least one canonical transaction — which source the bridge ACTUALLY
# serves for that date (per the group's windows). Sure-side entries
# can then be classified against the correct serving source instead of
# being naively matched to a single source.
#
# This replaces the earlier ING-only behavior that mis-classified
# pre-cutoff entries as remappable to ING when bridge actually serves
# them from Fintonic.
#
# Environment:
#   DATA — bridge data root (default: /data)
#   OUT  — output path  (default: /tmp/phase_a_bridge.json)
#
# Run inside the simplefreen-web container.

require "json"
require "date"
require "time"

DATA = ENV["DATA"] || "/data"
OUT  = ENV["OUT"]  || "/tmp/phase_a_bridge.json"

# --- load every source's canonical -------------------------------------
sources = {}   # source_key (e.g. "ING", "fintonic") → parsed history.json
Dir.glob("#{DATA}/history/*/history.json").each do |path|
  source = File.basename(File.dirname(path))
  sources[source] = JSON.parse(File.read(path))
end
abort "no source canonicals found under #{DATA}/history/*/history.json" if sources.empty?

# --- load consolidation group config -----------------------------------
groups_path = "#{DATA}/consolidation/groups.json"
groups = []
if File.exist?(groups_path)
  groups = Array(JSON.parse(File.read(groups_path))["groups"])
end

# account_id → group config (for window lookup)
account_to_group = {}
groups.each do |g|
  Array(g["members"]).each { |acc| account_to_group[acc] = g }
end

# account_id → list of source_keys that physically have this account
# (used as a fallback when no group config exists — e.g. singleton
# accounts that aren't in any consolidation set)
account_to_sources = Hash.new { |h, k| h[k] = [] }
sources.each do |src, hist|
  Array(hist["accounts"]).each { |a| account_to_sources[a["id"]] << src }
end

# account_id → account record (from any source; first wins for
# multi-source accounts. type/name only used for sign-handling and
# diagnostics, so first-source is acceptable.)
account_records = {}
sources.each do |src, hist|
  Array(hist["accounts"]).each do |a|
    account_records[a["id"]] ||= { "name" => a["name"], "type" => a["type"], "source" => src }
  end
end

# --- determine the serving source for (account, date) ------------------
def serving_source(account_id, date_str, account_to_group, account_to_sources)
  group = account_to_group[account_id]
  if group
    primary = group["primary"]
    windows = Hash(group["windows"])
    date    = Date.parse(date_str)
    candidates = windows.each_with_object([]) do |(src, w), arr|
      from = w["from"] && Date.parse(w["from"])
      to   = w["to"]   && Date.parse(w["to"])
      next if from && date < from
      next if to   && date > to
      arr << src
    end
    return primary if primary && candidates.include?(primary)
    return candidates.first
  end

  # No group config — singleton if exactly one source has the account.
  srcs = account_to_sources[account_id]
  srcs.size == 1 ? srcs.first : nil
end

# --- build the indexes Sure side will consume --------------------------
canonical_index = {}                        # txn_<hex> → row info
v2_seq_by_key   = Hash.new { |h, k| h[k] = [] }  # (acc|date|amount) → [{src, txn_id}]

sources.each do |src, hist|
  Array(hist["transactions"]).each do |t|
    txn_id = t["id"]
    canonical_index[txn_id] = {
      "source"         => src,
      "account_id"     => t["account_id"],
      "date"           => t["date"],
      "amount"         => t["amount"].to_s,
      "status"         => t["status"],
      "source_id_kind" => case t["source_id"].to_s
                         when /\Av2-seq:/    then "v2-seq"
                         when /\A___V1ID___/ then "V1ID"
                         else "other"
                         end,
      "description"    => (t["description"] || "")[0, 80]
    }
    next unless t["source_id"].to_s.start_with?("v2-seq:") || sources.size > 1
    key = "#{t["account_id"]}|#{t["date"]}|#{t["amount"]}"
    v2_seq_by_key[key] << { "source" => src, "txn_id" => txn_id }
  end
end

# expected_by_key — what the bridge WILL serve for each (acc, date, amount).
# Filters v2_seq_by_key to the single canonical entry from the serving source.
expected_by_key = {}
v2_seq_by_key.each do |key, entries|
  account_id, date_str, _amount = key.split("|", 3)
  src = serving_source(account_id, date_str, account_to_group, account_to_sources)
  next unless src
  match = entries.find { |e| e["source"].to_s.casecmp(src.to_s).zero? }
  expected_by_key[key] = { "source" => src, "txn_id" => match["txn_id"] } if match
end

# --- summary -----------------------------------------------------------
per_source = sources.transform_values do |hist|
  {
    "total_transactions" => Array(hist["transactions"]).size,
    "total_accounts"     => Array(hist["accounts"]).size
  }
end

out = {
  "generated_at"      => Time.now.utc.iso8601,
  "per_source"        => per_source,
  "consolidation"     => { "groups" => groups },
  "account_records"   => account_records,
  "canonical_index"   => canonical_index,
  "v2_seq_by_key"     => v2_seq_by_key,
  "expected_by_key"   => expected_by_key
}
File.write(OUT, JSON.pretty_generate(out))

puts "wrote #{OUT} (#{File.size(OUT)} bytes)"
puts ""
puts "sources:"
per_source.each { |s, info| puts "  #{s.ljust(15)} transactions=#{info["total_transactions"].to_s.rjust(5)}  accounts=#{info["total_accounts"]}" }
puts ""
puts "consolidation groups: #{groups.size}"
puts "canonical_index entries: #{canonical_index.size}"
puts "v2_seq_by_key buckets:   #{v2_seq_by_key.size}"
puts "expected_by_key entries: #{expected_by_key.size}  (serving-source resolved)"
