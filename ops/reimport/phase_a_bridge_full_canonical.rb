# Read-only: dump bridge canonical as a single JSON keyed by
# bridge account_id, with each transaction's (id, date, amount,
# description, src). Used as input by Phase G / Phase H to do
# multi-source orphan and date-drift analysis on Sure.
#
# Output: /tmp/canon_full.json
#
# Usage:
#   docker exec <bridge> ruby phase_a_bridge_full_canonical.rb
#   docker cp <bridge>:/tmp/canon_full.json /tmp/
#   docker cp /tmp/canon_full.json <sure>:/tmp/

require "json"

DATA    = ENV["DATA"]    || "/data"
SOURCES = (ENV["SOURCES"] || abort("set SOURCES to a space-separated list of profile keys")).split

idx = Hash.new { |h, k| h[k] = [] }
total = 0
SOURCES.each do |src|
  path = File.join(DATA, "history", src, "history.json")
  unless File.exist?(path)
    warn "skipping #{src}: no history.json at #{path}"
    next
  end
  h = JSON.parse(File.read(path))
  (h["transactions"] || []).each do |t|
    idx[t["account_id"]] << {
      "id"          => t["id"],
      "date"        => t["date"],
      "amount"      => t["amount"],
      "description" => t["description"],
      "src"         => src,
    }
    total += 1
  end
end

out = "/tmp/canon_full.json"
File.write(out, JSON.generate(idx))
puts "wrote #{out}: #{idx.size} bridge accounts, #{total} txns, #{File.size(out)} bytes"
