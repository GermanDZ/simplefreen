# Phase F — Sure-side dedup by external_id.
#
# Finds Sure Entry rows where multiple entries on the same account
# share the same non-null external_id (which means the same canonical
# transaction got imported into Sure more than once — accidentally,
# e.g. through interim cleanup churn).
#
# For each duplicate cluster, keep the RICHEST entry (category > has
# notes > earliest created_at) and delete the rest. Entries with NULL
# external_id are excluded — those are manual or non-bridge imports
# that can't be safely consolidated by id alone.
#
# Real bank-side twins (e.g. two identical fees on the same day, same
# description) survive because they have DIFFERENT external_ids (each
# is its own canonical transaction).
#
# Run inside the sure-web container:
#   docker exec -e APPLY=1 <sure-web> bin/rails runner /path/to/phase_f...

require "json"
require "set"

APPLY = ENV["APPLY"] == "1"
OUT   = ENV["OUT"] || "/tmp/phase_f_dedup_report.json"

puts "mode: #{APPLY ? 'APPLY' : 'DRY-RUN (set APPLY=1 to write)'}"
puts ""

# Find every (account_id, external_id) group with > 1 entries.
# Group SQL across all Sure entries (every source, every account).
groups = Entry
  .where.not(external_id: nil)
  .group(:account_id, :external_id)
  .having("COUNT(*) > 1")
  .count

puts "duplicate (account, external_id) groups: #{groups.size}"
exit 0 if groups.empty?

# Pull all members of these groups
group_keys = groups.keys
total_entries_in_groups = groups.values.sum
puts "total entries inside dup groups: #{total_entries_in_groups}"
puts "entries that will be deleted: #{total_entries_in_groups - groups.size}"
puts ""

def richness_key(e)
  cat       = e.entryable.respond_to?(:category_id) ? e.entryable.category_id : nil
  has_notes = e.notes.to_s.strip.empty? ? 1 : 0
  has_tags  = e.respond_to?(:tags) && e.tags.any? ? 0 : 1
  [cat ? 0 : 1, has_notes, has_tags, e.created_at.to_i]
end

deletes = []   # entries to delete
report  = []   # for diagnostic output

group_keys.each do |account_id, external_id|
  members = Entry.where(account_id: account_id, external_id: external_id).to_a
  next if members.size <= 1

  ranked = members.sort_by { |e| richness_key(e) }
  winner = ranked.first
  losers = ranked.drop(1)
  deletes.concat(losers)

  report << {
    "account_id"  => account_id,
    "external_id" => external_id,
    "size"        => members.size,
    "winner"      => { "id" => winner.id, "name" => winner.name.to_s[0, 60], "date" => winner.date.to_s, "amount" => winner.amount.to_s, "categorized" => !!winner.entryable&.try(:category_id), "notes" => !winner.notes.to_s.strip.empty? },
    "losers"      => losers.map { |e| { "id" => e.id, "name" => e.name.to_s[0, 60], "date" => e.date.to_s, "amount" => e.amount.to_s, "categorized" => !!e.entryable&.try(:category_id), "notes" => !e.notes.to_s.strip.empty? } }
  }
end

# Source distribution among deletes
by_source = Hash.new(0)
deletes.each { |e| by_source[e.source.to_s] += 1 }

puts "deletes by source:"
by_source.sort.each { |s, n| puts "  #{s.ljust(16)} #{n}" }
puts ""

# Account distribution
by_account = Hash.new(0)
deletes.each { |e| by_account[e.account_id] += 1 }
puts "deletes by account (top 20):"
by_account.sort_by { |_, n| -n }.first(20).each do |acc_id, n|
  acc = Account.find_by(id: acc_id)
  puts "  #{acc&.name.to_s[0, 30].ljust(30)} #{acc_id[0, 8]}  #{n}"
end
puts ""

puts "sample dup groups (first 15):"
report.first(15).each do |r|
  puts "  external_id=#{r["external_id"]}  account=#{r["account_id"][0, 8]}  size=#{r["size"]}"
  puts "    keep:   #{r["winner"]["id"]}  date=#{r["winner"]["date"]}  amount=#{r["winner"]["amount"]}  cat=#{r["winner"]["categorized"] ? 'Y' : 'n'}  notes=#{r["winner"]["notes"] ? 'Y' : 'n'}  #{r["winner"]["name"]}"
  r["losers"].each do |l|
    puts "    drop:   #{l["id"]}  date=#{l["date"]}  amount=#{l["amount"]}  cat=#{l["categorized"] ? 'Y' : 'n'}  notes=#{l["notes"] ? 'Y' : 'n'}  #{l["name"]}"
  end
end

File.write(OUT, JSON.pretty_generate({
  "generated_at"        => Time.now.utc.iso8601,
  "apply"               => APPLY,
  "duplicate_groups"    => groups.size,
  "entries_inside"      => total_entries_in_groups,
  "deletes_planned"     => deletes.size,
  "deletes_by_source"   => by_source,
  "deletes_by_account"  => by_account,
  "report"              => report
}))
puts ""
puts "wrote #{OUT} (#{File.size(OUT)} bytes)"

unless APPLY
  puts ""
  puts "DRY-RUN. set APPLY=1 to actually delete."
  exit 0
end

puts ""
puts "applying… (deletes wrapped in a transaction)"
ApplicationRecord.transaction do
  deletes.each(&:destroy!)
end
puts "deleted #{deletes.size} entries"
