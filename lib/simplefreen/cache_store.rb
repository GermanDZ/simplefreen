# frozen_string_literal: true

require "fileutils"
require "json"

require_relative "atomic_file"
require_relative "paths"

module Simplefreen
  # Ephemeral cache of the latest ready SimpleFIN payload per profile.
  # Populated by the SimpleFIN exporter running inside a child freentonic.
  # Consumed (read + unlinked) by GET /simplefin/accounts/:key when the
  # profile is in state `ready`.
  class CacheStore
    def initialize(root: Paths.root)
      @root = root
    end

    def path_for(key)
      Paths.cache_path(key, @root)
    end

    def exists?(key)
      File.exist?(path_for(key))
    end

    # Write the reshaped SimpleFIN envelope atomically (via tmp + rename).
    # Creates the per-profile cache dir with 0700 perms if needed.
    def write(key, envelope)
      AtomicFile.write_json(path_for(key), envelope)
    end

    # Read-and-unlink. Returns nil if missing. Previously used for the
    # one-shot-serve model; kept for tests and for admin-triggered
    # resets. GET /simplefin/accounts now uses #read (non-destructive).
    def consume(key)
      AtomicFile.consume_json(path_for(key))
    end

    # Non-destructive read. Returns the cached envelope hash or nil.
    # GET /simplefin/accounts calls this on every request — Actual polls
    # the endpoint repeatedly (post-link transaction fetches, periodic
    # background syncs, etc.) and expects the payload to stay available
    # between scrapes. Fresh sync runs overwrite the file atomically.
    def read(key)
      AtomicFile.read_json(path_for(key))
    end

    # Mtime of the current cache file in seconds since epoch, or nil.
    def mtime(key)
      File.mtime(path_for(key)).to_i
    rescue Errno::ENOENT
      nil
    end

    def delete(key)
      AtomicFile.delete(path_for(key))
    end

    # Garbage-collect caches older than `max_age_seconds`. Returns the
    # number of files removed. No-op if the cache dir doesn't exist.
    def gc!(max_age_seconds: 14 * 24 * 3600)
      root = Paths.cache_dir(@root)
      return 0 unless Dir.exist?(root)
      now = Time.now
      removed = 0
      Dir.each_child(root) do |sub|
        next unless sub =~ Paths::FILENAME_PATTERN
        file = File.join(root, sub, "latest.json")
        next unless File.file?(file)
        mtime = File.mtime(file) rescue nil
        next unless mtime
        if now - mtime > max_age_seconds
          File.unlink(file) rescue nil
          removed += 1
        end
      end
      removed
    end
  end
end
