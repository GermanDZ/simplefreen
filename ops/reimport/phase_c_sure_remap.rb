# Phase C — Sure entry remap. Reads /tmp/phase_a_sure.json (Phase A
# output) and updates each Sure Entry's external_id from the old
# V1ID-based form to the new v2-seq form.
#
# Conflict policy: "keep the entry with the most user data" — preserve
# user categorization, notes, splits, merchant/tag relations on
# whichever entry has them, regardless of which side of the rename it's
# on. Ranking: has-category > has-notes > earliest created_at.
#
#   1. v1id_remappable (1:1, target free) — simple rename
#   2. v1id_remappable, target occupied   — rank the orphan v1id entry
#                                           vs the existing-at-target
#                                           entry; keep richer, delete
#                                           the other. (Cycle-2 bug
#                                           fix 2026-05-23: previous
#                                           "keep old by code path"
#                                           logic deleted categorized
#                                           entries when the orphan
#                                           was a newly-created
#                                           uncategorized phantom.)
#   3. Same target reached by two olds    — same ranking; winner
#      (Sure-side dup ghosts)               renamed (if needed),
#                                           loser(s) deleted.
#
# Ambiguous (multi-candidate by date+amount) resolution: if N Sure
# entries on the same (acc, date, amount) match N v2-seq candidates,
# pair them deterministically (sorted external_id ↔ sorted candidate);
# otherwise abort and require a manual /tmp/phase_c_overrides.json
# mapping {"sure_entry_id" => "simplefin_txn_..."}.
#
# After DB remap, scrubs SimplefinAccount.raw_transactions_payload so
# old external_ids don't resurrect entries on the next sync.
#
# Environment:
#   SURE_DATA       — phase A Sure artifact (default: /tmp/phase_a_sure.json)
#   OVERRIDES       — optional ambiguous-resolution overrides JSON
#                     (default: /tmp/phase_c_overrides.json)
#   APPLY           — set to 1 to actually write; otherwise dry-run
#
# Run inside the sure-web container:
#   docker exec <sure-web> bin/rails runner /path/to/phase_c_sure_remap.rb

require "json"
require "set"

APPLY     = ENV["APPLY"] == "1"
SURE_DATA = ENV["SURE_DATA"] || "/tmp/phase_a_sure.json"
OVERRIDES = ENV["OVERRIDES"] || "/tmp/phase_c_overrides.json"

data = JSON.parse(File.read(SURE_DATA))
cls  = data["classifications"]

mappings = []   # [sure_entry_id, old_external_id, new_external_id]
(cls["v1id_remappable"] || []).each do |r|
  mappings << [r["sure_entry_id"], r["old_external_id"], r["new_external_id"]]
end

# --- ambiguous resolution ------------------------------------------------
amb = cls["ambiguous"] || []
override_map = File.exist?(OVERRIDES) ? JSON.parse(File.read(OVERRIDES)) : {}

if amb.any?
  by_key = amb.group_by { |r| [r["bridge_account"], r["date"], r["amount"]] }
  by_key.each do |key, sure_rows|
    candidate_sets = sure_rows.map { |r| r["candidate_new_ids"].sort }.uniq
    if override_map.size > 0 && sure_rows.all? { |r| override_map.key?(r["sure_entry_id"]) }
      sure_rows.each { |r| mappings << [r["sure_entry_id"], r["external_id"], override_map[r["sure_entry_id"]]] }
    elsif candidate_sets.size == 1 && sure_rows.size == candidate_sets.first.size
      sorted_sure = sure_rows.sort_by { |r| r["external_id"] }
      sorted_cand = candidate_sets.first
      sorted_sure.zip(sorted_cand).each do |sure_row, new_ext|
        mappings << [sure_row["sure_entry_id"], sure_row["external_id"], new_ext]
      end
    else
      abort <<~MSG
        ambiguous group at #{key.inspect} cannot be auto-paired
        (#{sure_rows.size} Sure entries vs #{candidate_sets.first&.size || 0} candidates,
        candidate_sets.size=#{candidate_sets.size}).
        Provide manual overrides at #{OVERRIDES} as JSON:
          { "<sure_entry_id>": "simplefin_txn_<hex>", ... }
        covering every entry in this group, then re-run.
      MSG
    end
  end
end

puts "mode: #{APPLY ? 'APPLY' : 'DRY-RUN (set APPLY=1 to write)'}"
puts "mappings to apply: #{mappings.size}"
puts ""

# --- richness ranking ---------------------------------------------------
# Rank two Entry rows by how much user-data they carry. Lower sort key
# = better; sort ascending and take .first to get the winner. Same key
# is used for both collision groups (two olds → same target) and the
# orphan-vs-existing case (rename target already taken).
def richness_key(e)
  cat       = e.entryable.respond_to?(:category_id) ? e.entryable.category_id : nil
  has_notes = e.notes.to_s.strip.empty? ? 1 : 0
  [cat ? 0 : 1, has_notes, e.created_at.to_i]
end

# --- collision detection (intra-mapping) --------------------------------
# Multiple OLD entries targeting the same NEW external_id (Sure-side
# dup ghosts). Rank, keep richest, delete rest.
by_target = mappings.group_by { |_, _, new_ext| new_ext }
collision_losers  = []
collision_winners = {}

by_target.each do |_, rows|
  next if rows.size == 1
  entries = rows.map { |sure_id, _, _| [sure_id, Entry.find_by(id: sure_id, source: "simplefin")] }.reject { |_, e| e.nil? }
  next if entries.size < 2

  ranked = entries.sort_by { |_, e| richness_key(e) }
  collision_winners[ranked.first[0]] = true
  ranked.drop(1).each { |_, e| collision_losers << e }
end

puts "collision groups (intra-mapping, two olds → one target): #{by_target.count { |_, r| r.size > 1 }}"
puts "  winners (kept and remapped): #{collision_winners.size}"
puts "  losers (deleted as Sure-side dups): #{collision_losers.size}"
puts ""

# --- build plan ----------------------------------------------------------
target_externals = mappings.map { |_, _, new_ext| new_ext }.to_set
existing_targets = Entry.where(source: "simplefin", external_id: target_externals.to_a).index_by(&:external_id)
loser_ids        = collision_losers.map(&:id).to_set
puts "of #{target_externals.size} target external_ids, #{existing_targets.size} are already occupied"
puts ""

stats     = Hash.new(0)
to_update = []
to_delete = collision_losers.dup

mappings.each do |sure_id, old_ext, new_ext|
  if loser_ids.include?(sure_id)
    stats[:collision_loser_deleted] += 1
    next
  end
  if by_target[new_ext].size > 1 && !collision_winners[sure_id]
    stats[:collision_loser_skipped] += 1
    next
  end

  orphan = Entry.find_by(id: sure_id, source: "simplefin")
  unless orphan
    stats[:missing_orphan] += 1
    next
  end
  unless orphan.external_id == old_ext
    stats[:orphan_external_id_drifted] += 1
    next
  end

  conflict = existing_targets[new_ext]
  if conflict.nil? || conflict.id == orphan.id || loser_ids.include?(conflict.id)
    # Target free (or occupied only by a collision-loser slated for delete).
    to_update << [orphan, new_ext]
    stats[:no_conflict_simple_rename] += 1
    next
  end

  # Target occupied by another Entry. Rank both, keep the richer one.
  winner, loser = [orphan, conflict].sort_by { |e| richness_key(e) }
  if winner.id == orphan.id
    # Orphan wins (typically: orphan is categorized, conflict is auto-created).
    to_update << [orphan, new_ext]
    to_delete << conflict
    stats[:conflict_keep_orphan_rename] += 1
  else
    # Existing-at-target wins (typically: conflict is categorized, orphan is
    # a newly-imported uncategorized dup from a recent re-sync). Just delete
    # the orphan; conflict already holds the right external_id.
    to_delete << orphan
    stats[:conflict_keep_existing_delete_orphan] += 1
  end
end

puts "plan:"
stats.sort.each { |k, v| puts "  #{k.to_s.ljust(28)} #{v}" }
puts "  updates queued: #{to_update.size}"
puts "  deletes queued: #{to_delete.size}"
puts ""

puts "sample mappings (first 10):"
to_update.first(10).each do |entry, new_ext|
  puts "  Entry #{entry.id}  #{entry.date} #{entry.amount.to_s.rjust(10)}  #{entry.name.to_s[0, 40]}"
  puts "    #{entry.external_id} → #{new_ext}#{existing_targets[new_ext] ? "  (DEL conflict #{existing_targets[new_ext].id})" : ""}"
end
puts ""

if stats[:missing_orphan] > 0 || stats[:orphan_external_id_drifted] > 0
  puts "STOP: pre-apply checks failed (missing_orphan=#{stats[:missing_orphan]}, drifted=#{stats[:orphan_external_id_drifted]})."
  puts "  Re-run Phase A and Phase C — Sure DB has drifted since classification."
  exit 1
end

unless APPLY
  puts "DRY-RUN. set APPLY=1 to write changes."
  exit 0
end

puts "applying…"
ApplicationRecord.transaction do
  to_delete.each(&:destroy!)
  to_update.each { |entry, new_ext| entry.update!(external_id: new_ext) }
end
puts "DB remap complete."
puts ""

# --- snapshot scrub ------------------------------------------------------
# Strip old external_ids from per-account raw_transactions_payload so
# the next SimpleFIN sync doesn't recreate the renamed entries.
#
# IMPORTANT: Sure stores this column in TWO shapes depending on the
# SimpleFIN version that wrote it:
#   - flat Array of transaction Hashes (older / direct wire format)
#   - Hash wrapper {"transactions" => [...]}
# Both must be handled, or array-shaped payloads silently bypass the
# scrub and the next sync replays stale transactions. (Bug discovered
# 2026-05-24 — array shape was skipped, leaking V1ID-era phantoms back
# into Sure as new Entry rows.)
old_ids_set = mappings.map { |_, old_ext, _| old_ext.sub(/^simplefin_/, "") }.to_set
puts "scrubbing per-account snapshot cache: #{old_ids_set.size} stale txn ids to remove"

scrub_stats = Hash.new(0)
SimplefinAccount.find_each do |sfa|
  payload = sfa.raw_transactions_payload
  next if payload.blank?

  if payload.is_a?(Array)
    txns = payload
    wrap = ->(filtered) { filtered }
  elsif payload.is_a?(Hash) && payload["transactions"].is_a?(Array)
    txns = payload["transactions"]
    wrap = ->(filtered) { payload.merge("transactions" => filtered) }
  else
    scrub_stats[:accounts_skipped_unknown_shape] += 1
    puts "  #{sfa.id}: SKIP (payload class=#{payload.class}, keys=#{payload.respond_to?(:keys) ? payload.keys.inspect : "n/a"})"
    next
  end

  before = txns.size
  filtered = txns.reject { |t| old_ids_set.include?(t["id"].to_s) }
  next if filtered.size == before

  sfa.update!(raw_transactions_payload: wrap.call(filtered))
  scrub_stats[:accounts_scrubbed] += 1
  scrub_stats[:txns_removed] += (before - filtered.size)
  puts "  #{sfa.id}: #{before} → #{filtered.size}  (-#{before - filtered.size})"
end

puts ""
puts "snapshot scrub:"
scrub_stats.sort.each { |k, v| puts "  #{k.to_s.ljust(34)} #{v}" }
puts ""
puts "done."
