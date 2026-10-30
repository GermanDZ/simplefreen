# Phase B — wipe V1ID transactions from a source's canonical for accounts
# that have v2 coverage (refetchable via /search). Atomic write + backup
# to history.json.phase-b-bak-<timestamp>. The bridge's history store
# re-reads on each request, so no restart is required.
#
# Environment:
#   DATA        — bridge data root (default: /data)
#   SOURCE      — source key under #{DATA}/history/ (default: ING)
#   BRIDGE_DATA — Phase A artifact path (default: /tmp/phase_a_bridge.json)
#   APPLY       — set to 1 to actually write; otherwise dry-run

require "json"
require "fileutils"
require "set"
require "time"

APPLY       = ENV["APPLY"] == "1"
DATA        = ENV["DATA"]        || "/data"
SOURCE      = ENV["SOURCE"]      || "ING"
BRIDGE_DATA = ENV["BRIDGE_DATA"] || "/tmp/phase_a_bridge.json"
HIST        = "#{DATA}/history/#{SOURCE}/history.json"

stamp  = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
backup = "#{HIST}.phase-b-bak-#{stamp}"

bridge   = JSON.parse(File.read(BRIDGE_DATA))
wipe_ids = bridge["wipe_ids"].to_set

hist     = JSON.parse(File.read(HIST))
before   = hist["transactions"].size
new_txns = hist["transactions"].reject { |t| wipe_ids.include?(t["id"]) }
after    = new_txns.size

puts "mode: #{APPLY ? 'APPLY' : 'DRY-RUN (set APPLY=1 to write)'}"
puts "history file:    #{HIST}"
puts "wipe_ids count:  #{wipe_ids.size}"
puts "transactions: #{before} → #{after}  (delta -#{before - after})"

unless before - after == wipe_ids.size
  puts "WARNING: deletion delta (#{before - after}) does not match wipe_ids count (#{wipe_ids.size})"
  puts "  Some wipe_ids may not be in canonical (already cleaned). Continuing if you APPLY."
end

if hist["tx_run_index"].is_a?(Hash)
  before_idx = hist["tx_run_index"].size
  hist["tx_run_index"].reject! { |id, _| wipe_ids.include?(id) }
  puts "tx_run_index: #{before_idx} → #{hist["tx_run_index"].size}"
end

hist["transactions"] = new_txns
hist["updated_at"]   = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")

unless APPLY
  puts ""
  puts "DRY-RUN. set APPLY=1 to write."
  exit 0
end

FileUtils.cp(HIST, backup)
puts "backup: #{backup} (#{File.size(backup)} bytes)"

tmp = "#{HIST}.tmp.#{Process.pid}"
File.open(tmp, "w") { |f| f.write(JSON.pretty_generate(hist)) }
File.chmod(0o600, tmp) rescue nil
File.rename(tmp, HIST)
puts "wrote: #{HIST} (#{File.size(HIST)} bytes)"
puts ""
puts "next:"
puts "  1. trigger #{SOURCE} sync via admin UI (max lookback, approve SCA if applicable)"
puts "  2. wait for sync to complete"
puts "  3. re-run phase A to see remappable counts"
