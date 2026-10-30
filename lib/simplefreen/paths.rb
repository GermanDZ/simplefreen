# frozen_string_literal: true

require "fileutils"

module Simplefreen
  # Filesystem layout + path-validation helpers. Every filename component
  # that originates outside the server (profile keys, claim IDs, run IDs)
  # must be matched against FILENAME_PATTERN before being joined into a
  # path — otherwise a caller could escape the workspace with "../../etc".
  module Paths
    # Same charset as freentonic's InvokeRequest::PROFILE_KEY_PATTERN so a
    # key minted here can be reused as an InvokeRequest.profile_key on
    # the freentonic side without mutation.
    FILENAME_PATTERN = /\A[A-Za-z0-9_.\-]{1,128}\z/

    module_function

    def root
      ENV["SIMPLEFREEN_ROOT"] || "/data"
    end

    def profiles_dir(root_dir = root)      = File.join(root_dir, "profiles")
    def state_dir(root_dir = root)         = File.join(root_dir, "state")
    def cache_dir(root_dir = root)         = File.join(root_dir, "cache")
    def claims_dir(root_dir = root)        = File.join(root_dir, "claims")
    def runs_dir(root_dir = root)          = File.join(root_dir, "runs")
    def history_dir(root_dir = root)       = File.join(root_dir, "history")
    def consolidation_dir(root_dir = root) = File.join(root_dir, "consolidation")

    def consolidation_aliases_path(root_dir = root)
      File.join(consolidation_dir(root_dir), "aliases.json")
    end

    def consolidation_groups_path(root_dir = root)
      File.join(consolidation_dir(root_dir), "groups.json")
    end

    # Ensure the layout exists with owner-only permissions. Safe to call
    # many times (mkdir_p is idempotent).
    def ensure_layout!(root_dir = root)
      FileUtils.mkdir_p(root_dir, mode: 0o700)
      [profiles_dir(root_dir), state_dir(root_dir), cache_dir(root_dir),
       claims_dir(root_dir), runs_dir(root_dir), history_dir(root_dir),
       consolidation_dir(root_dir)].each do |d|
        FileUtils.mkdir_p(d, mode: 0o700)
      end
    end

    # Validate a single filename component. Raises ArgumentError when the
    # input escapes the accepted charset (anything a shell, a filesystem,
    # or a URL might interpret surprisingly).
    def validate_component!(value, label = "name")
      unless value.is_a?(String) && value =~ FILENAME_PATTERN
        raise ArgumentError,
          "simplefin: #{label} must match [A-Za-z0-9_.-]{1,128} (got #{value.inspect})"
      end
      value
    end

    def profile_path(key, root_dir = root)
      validate_component!(key, "profile_key")
      File.join(profiles_dir(root_dir), "#{key}.json")
    end

    def state_path(key, root_dir = root)
      validate_component!(key, "profile_key")
      File.join(state_dir(root_dir), "#{key}.json")
    end

    def cache_path(key, root_dir = root)
      validate_component!(key, "profile_key")
      File.join(cache_dir(root_dir), key, "latest.json")
    end

    def claim_path(claim_id, root_dir = root)
      validate_component!(claim_id, "claim_id")
      File.join(claims_dir(root_dir), "#{claim_id}.json")
    end

    def run_log_path(key, run_id, root_dir = root)
      validate_component!(key, "profile_key")
      validate_component!(run_id, "run_id")
      File.join(runs_dir(root_dir), key, "#{run_id}.json")
    end

    def run_canonical_path(key, run_id, root_dir = root)
      validate_component!(key, "profile_key")
      validate_component!(run_id, "run_id")
      File.join(runs_dir(root_dir), key, "#{run_id}.canonical.json")
    end

    def run_canonical_meta_path(key, run_id, root_dir = root)
      validate_component!(key, "profile_key")
      validate_component!(run_id, "run_id")
      File.join(runs_dir(root_dir), key, "#{run_id}.canonical.meta.json")
    end

    def history_path(key, root_dir = root)
      validate_component!(key, "profile_key")
      File.join(history_dir(root_dir), key, "history.json")
    end

    # Watchdog dedup bookkeeping (last-alerted condition + timestamp per
    # subject). A single small JSON file at the workspace root — not
    # per-profile, since it also tracks non-profile subjects like the
    # scheduler worker.
    def watchdog_path(root_dir = root)
      File.join(root_dir, "watchdog.json")
    end
  end
end
