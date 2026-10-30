# Phase A — Sure side, multi-source aware.
#
# Reads /tmp/phase_a_bridge.json (multi-source artifact) and classifies
# every Sure simplefin Entry against the SERVING source for its
# (bridge_account, date) — not just against a single source.
#
# Classifications:
#   v2_seq                    external_id matches expected (serving-source) txn_id
#   v1id_remappable           expected exists, external_id differs → rename target
#   ambiguous                 multiple candidates (date+amount collision within serving source)
#   historical_no_bridge_link no serving entry for this (acc, date, amount)
#   malformed_external_id     external_id doesn't start with simplefin_

require "json"
require "time"

BRIDGE_DATA = ENV["BRIDGE_DATA"] || "/tmp/phase_a_bridge.json"
OUT         = ENV["OUT"]         || "/tmp/phase_a_sure.json"
abort "missing #{BRIDGE_DATA}" unless File.exist?(BRIDGE_DATA)

bridge          = JSON.parse(File.read(BRIDGE_DATA))
canonical_index = bridge["canonical_index"]
v2_seq_by_key   = bridge["v2_seq_by_key"]
expected_by_key = bridge["expected_by_key"]
account_records = bridge["account_records"]

# Find all bridge account_ids referenced by Sure SimplefinAccount records.
sure_account_to_bridge = {}
SimplefinAccount.includes(:account).find_each do |sfa|
  next unless account_records.key?(sfa.account_id)
  next unless sfa.account
  sure_account_to_bridge[sfa.account.id] = sfa.account_id
end

puts "bridge-mapped Sure accounts: #{sure_account_to_bridge.size}"
sure_account_to_bridge.each do |acc_uuid, bridge_id|
  rec = account_records[bridge_id]
  puts "  app_account=#{acc_uuid[0, 8]}  bridge_id=#{bridge_id}  name=#{rec["name"].to_s[0, 30]}  type=#{rec["type"]}  src=#{rec["source"]}"
end

sure_entries = Entry.where(source: "simplefin", account_id: sure_account_to_bridge.keys).to_a
puts "\nentries to classify: #{sure_entries.size}"

cls = Hash.new { |h, k| h[k] = [] }

sure_entries.each do |e|
  external_id = e.external_id.to_s
  unless external_id.start_with?("simplefin_")
    cls["malformed_external_id"] << { "sure_entry_id" => e.id, "external_id" => external_id }
    next
  end

  bridge_account_id = sure_account_to_bridge[e.account_id]
  rec               = account_records[bridge_account_id]
  is_liability      = rec["type"] == "credit_card"

  # Bridge stores liability charges with bank sign (negative); Sure
  # stores them with liability convention (positive). Flip for the
  # lookup; assets pass through.
  sure_amount   = e.amount.to_f
  bridge_target = is_liability ? -sure_amount : sure_amount
  amount_candidates = [
    format("%.2f", bridge_target),
    bridge_target.to_s,
    format("%g", bridge_target)
  ].uniq

  expected = nil
  all_matches = []
  amount_candidates.each do |amt|
    key = "#{bridge_account_id}|#{e.date}|#{amt}"
    expected ||= expected_by_key[key]
    all_matches.concat(v2_seq_by_key[key] || [])
  end
  all_matches.uniq! { |m| [m["source"], m["txn_id"]] }

  if expected.nil?
    cls["historical_no_bridge_link"] << {
      "sure_entry_id" => e.id, "external_id" => external_id,
      "bridge_account" => bridge_account_id, "date" => e.date.to_s,
      "amount" => format("%.2f", e.amount), "name" => e.name.to_s[0, 60]
    }
    next
  end

  expected_external_id = "simplefin_#{expected["txn_id"]}"

  if external_id == expected_external_id
    cls["v2_seq"] << { "sure_entry_id" => e.id, "external_id" => external_id, "date" => e.date.to_s }
    next
  end

  # external_id differs from expected. Could be: needs remap (1
  # serving candidate) or ambiguous (multiple serving candidates).
  serving_matches = all_matches.select { |m| m["source"].casecmp(expected["source"]).zero? }
  if serving_matches.size > 1
    cls["ambiguous"] << {
      "sure_entry_id" => e.id, "external_id" => external_id,
      "bridge_account" => bridge_account_id, "date" => e.date.to_s,
      "amount" => format("%.2f", e.amount), "name" => e.name.to_s[0, 60],
      "candidate_new_ids" => serving_matches.map { |m| "simplefin_#{m["txn_id"]}" }
    }
  else
    cls["v1id_remappable"] << {
      "sure_entry_id"   => e.id,
      "old_external_id" => external_id,
      "new_external_id" => expected_external_id,
      "bridge_account"  => bridge_account_id,
      "date"            => e.date.to_s,
      "amount"          => format("%.2f", e.amount),
      "name"            => e.name.to_s[0, 60],
      "serving_source"  => expected["source"]
    }
  end
end

summary = cls.transform_values(&:size)
File.write(OUT, JSON.pretty_generate({
  "generated_at"           => Time.now.utc.iso8601,
  "summary"                => summary,
  "sure_account_to_bridge" => sure_account_to_bridge,
  "classifications"        => cls
}))

puts "\nwrote #{OUT} (#{File.size(OUT)} bytes)"
puts ""
puts "classifications:"
summary.sort.each { |k, v| puts "  #{k.ljust(30)} #{v}" }

if cls["v1id_remappable"].any?
  by_source = cls["v1id_remappable"].group_by { |r| r["serving_source"] }
  puts ""
  puts "v1id_remappable by serving source:"
  by_source.sort.each { |s, rs| puts "  #{s.to_s.ljust(15)} #{rs.size}" }
  puts ""
  puts "sample v1id_remappable (first 10):"
  cls["v1id_remappable"].first(10).each do |r|
    puts "  #{r["date"]} #{r["amount"].rjust(10)}  → #{r["serving_source"]}  #{r["name"]}"
    puts "    old: #{r["old_external_id"]}"
    puts "    new: #{r["new_external_id"]}"
  end
end

if cls["ambiguous"].any?
  puts ""
  puts "ambiguous (first 10):"
  cls["ambiguous"].first(10).each do |r|
    puts "  #{r["date"]} #{r["amount"].rjust(10)}  #{r["name"]}  candidates=#{r["candidate_new_ids"].size}"
  end
end
