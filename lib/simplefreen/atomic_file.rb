# frozen_string_literal: true

require "fileutils"
require "json"

module Simplefreen
  # Atomic read/write helpers for JSON-shaped state. Every writer goes
  # through tmp + flock + fsync + rename so a partially-written file can
  # never be observed. Readers take a shared lock to block during writes.
  #
  # All files are created with mode 0600. Directories are created with
  # mode 0700 on demand.
  module AtomicFile
    module_function

    def write_json(path, hash)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      tmp = "#{path}.tmp.#{Process.pid}.#{rand(1 << 32).to_s(16)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
        f.flock(File::LOCK_EX)
        f.write(JSON.generate(hash))
        f.fsync
      end
      File.rename(tmp, path)
    rescue StandardError
      File.unlink(tmp) if tmp && File.exist?(tmp)
      raise
    end

    # Returns the parsed JSON hash, or `default` if the file doesn't exist.
    # Shared-locks the file for the read so a concurrent rename-in-flight
    # can't be observed half-written (though rename itself is atomic on
    # POSIX filesystems, the lock also pairs with update_json below).
    def read_json(path, default: nil)
      return default unless File.exist?(path)
      File.open(path, File::RDONLY) do |f|
        f.flock(File::LOCK_SH)
        content = f.read
        return default if content.nil? || content.empty?
        JSON.parse(content)
      end
    rescue Errno::ENOENT
      default
    end

    # Read-modify-write under an exclusive advisory lock on a sibling
    # lockfile. The lockfile is kept on disk; readers block while the
    # block runs. The passed-in hash is the current content (or {} if
    # missing); the block returns the new hash to persist.
    def update_json(path)
      lock_path = "#{path}.lock"
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      File.open(lock_path, File::WRONLY | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        current = read_json(path, default: {})
        updated = yield(current)
        write_json(path, updated) unless updated.nil?
      end
    end

    def delete(path)
      File.unlink(path)
    rescue Errno::ENOENT
      nil
    end

    # Read + consume in one atomic operation. Returns the parsed hash and
    # unlinks the file. Returns nil if the file doesn't exist. Used for
    # one-shot reads (e.g. serving the cache once, then resetting state).
    def consume_json(path)
      lock_path = "#{path}.lock"
      return nil unless File.exist?(path) || File.exist?(lock_path)
      File.open(lock_path, File::WRONLY | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        return nil unless File.exist?(path)
        content = File.read(path)
        File.unlink(path)
        return nil if content.nil? || content.empty?
        return JSON.parse(content)
      end
    end
  end
end
