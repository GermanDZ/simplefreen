# frozen_string_literal: true

require "time"

require_relative "atomic_file"
require_relative "paths"

module Simplefreen
  # Per-profile history of recent sync runs. One JSON file per run:
  #   {
  #     "run_id":      "...",
  #     "profile_key": "...",
  #     "started_at":  "...",
  #     "finished_at": "...",
  #     "duration_ms": 12345,
  #     "exit_code":   0,
  #     "error_kind":  nil | "user_error" | ...,
  #     "outcome":     "ready" | "error" | "needs_reauth",
  #     "message":     "short human description",
  #     "headed":      false,
  #     "log_path":    "runs/<run_id>/log"
  #   }
  class RunLog
    MAX_RETAINED = 100

    def initialize(root: Paths.root)
      @root = root
      Paths.ensure_layout!(@root)
    end

    def record(profile_key, entry)
      Paths.validate_component!(profile_key, "profile_key")
      run_id = entry.fetch(:run_id) { entry.fetch("run_id") }
      Paths.validate_component!(run_id, "run_id")
      dir = File.join(Paths.runs_dir(@root), profile_key)
      FileUtils.mkdir_p(dir, mode: 0o700)
      normalized = entry.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
      normalized["profile_key"] ||= profile_key
      AtomicFile.write_json(Paths.run_log_path(profile_key, run_id, @root), normalized)
      prune!(profile_key)
      normalized
    end

    # Most-recent-first list of recorded runs. Each entry is the hash
    # previously written by #record.
    def recent(profile_key, limit: 20)
      Paths.validate_component!(profile_key, "profile_key")
      dir = File.join(Paths.runs_dir(@root), profile_key)
      return [] unless Dir.exist?(dir)
      entries = Dir.children(dir).select do |n|
        n.end_with?(".json") &&
          !n.end_with?(".canonical.json") &&
          !n.end_with?(".canonical.meta.json")
      end
      entries = entries.sort_by do |name|
        path = File.join(dir, name)
        -(File.mtime(path).to_f rescue 0.0)
      end
      entries.first(limit).map do |name|
        AtomicFile.read_json(File.join(dir, name))
      end.compact
    end

    # Run-id of the most recently received canonical payload for this
    # profile. Resolves by mtime of <run_id>.canonical.json — the file is
    # written by PushReceiver right after it accepts a freentonic push,
    # so "newest mtime" tracks "newest data" without consulting the
    # run-log entry (which the scheduler writes later, asynchronously).
    def latest_canonical_run_id(profile_key)
      Paths.validate_component!(profile_key, "profile_key")
      dir = File.join(Paths.runs_dir(@root), profile_key)
      return nil unless Dir.exist?(dir)
      newest = nil
      newest_mtime = -Float::INFINITY
      Dir.children(dir).each do |name|
        next unless name.end_with?(".canonical.json")
        next if name.end_with?(".canonical.meta.json")
        mtime = File.mtime(File.join(dir, name)).to_f rescue 0.0
        if mtime > newest_mtime
          newest = name
          newest_mtime = mtime
        end
      end
      newest&.sub(/\.canonical\.json\z/, "")
    end

    # Load the canonical envelope from the most recent successful push,
    # or nil if no canonical has ever been recorded for this profile
    # (e.g. a fresh install, or a profile that pre-dates canonical
    # persistence).
    def latest_canonical(profile_key)
      run_id = latest_canonical_run_id(profile_key)
      return nil unless run_id
      AtomicFile.read_json(Paths.run_canonical_path(profile_key, run_id, @root))
    end

    private

    def prune!(profile_key)
      dir = File.join(Paths.runs_dir(@root), profile_key)
      return unless Dir.exist?(dir)
      # Group every file by the run_id derived from its basename so the
      # canonical sidecars (<run_id>.canonical.json,
      # <run_id>.canonical.meta.json) are pruned in lockstep with the
      # run-log entry (<run_id>.json).
      groups = Hash.new { |h, k| h[k] = [] }
      Dir.children(dir).each do |name|
        next unless name.end_with?(".json")
        path = File.join(dir, name)
        run_id = run_id_for_filename(name)
        next unless run_id
        groups[run_id] << path
      end
      return if groups.size <= MAX_RETAINED
      groups
        .map { |run_id, paths| [run_id, paths, paths.map { |p| File.mtime(p).to_f rescue 0.0 }.max] }
        .sort_by { |_, _, m| -m }
        .drop(MAX_RETAINED)
        .each do |_, paths, _|
          paths.each { |p| File.unlink(p) rescue nil }
        end
    end

    def run_id_for_filename(name)
      stripped =
        if name.end_with?(".canonical.meta.json")
          name.sub(/\.canonical\.meta\.json\z/, "")
        elsif name.end_with?(".canonical.json")
          name.sub(/\.canonical\.json\z/, "")
        else
          name.sub(/\.json\z/, "")
        end
      stripped.empty? ? nil : stripped
    end
  end
end
