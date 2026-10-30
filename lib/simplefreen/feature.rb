# frozen_string_literal: true

require_relative "crypto"
require_relative "errors"
require_relative "freentonic_client"
require_relative "paths"
require_relative "profile_store"
require_relative "state_store"
require_relative "cache_store"
require_relative "claim_store"
require_relative "consolidation_store"
require_relative "consolidation_groups_store"
require_relative "run_log"
require_relative "history_store"

module Simplefreen
  # Top-level feature container. Owns the long-lived stores, the scheduler
  # worker thread, the freentonic-health monitor, the in-memory push-token
  # mint-table, and the env-derived config. Constructed once per server
  # startup.
  class Feature
    attr_reader :root, :master_key, :admin_password, :public_url,
                :profile_store, :state_store, :cache_store, :claim_store,
                :consolidation_store, :consolidation_groups_store,
                :run_log, :history_store, :scheduler, :freentonic_health, :push_tokens,
                :notifier, :watchdog,
                :freentonic_client, :logger, :cors_allowed_origins,
                :freentonic_url, :freentonic_invoke_token,
                :internal_push_url, :runs_artifacts_dir

    def initialize(
      root:                        Paths.root,
      master_key:,
      admin_password:,
      public_url:,
      freentonic_url:,
      freentonic_invoke_token:,
      internal_push_url:           nil,
      cors_allowed_origins:        [],
      runs_artifacts_dir:          nil,
      logger:                      nil
    )
      @root                    = root
      @master_key              = master_key
      @admin_password          = admin_password
      @public_url              = public_url.sub(/\/+\z/, "")
      @freentonic_url          = freentonic_url.sub(/\/+\z/, "")
      @freentonic_invoke_token = freentonic_invoke_token
      @internal_push_url       = (internal_push_url || @public_url).sub(/\/+\z/, "")
      @cors_allowed_origins    = Array(cors_allowed_origins).compact.map { |o| o.strip }.reject(&:empty?)
      # Read-only path to freentonic's per-run output directory (the same
      # path freentonic writes screenshots and logs to). When set and
      # readable, the admin API surfaces artifacts via /admin/api/.../runs/
      # endpoints; when nil the gallery degrades gracefully.
      @runs_artifacts_dir      = runs_artifacts_dir
      @logger                  = logger || ->(_msg) {}

      Paths.ensure_layout!(@root)

      @profile_store       = ProfileStore.new(root: @root)
      @state_store         = StateStore.new(root: @root)
      @cache_store         = CacheStore.new(root: @root)
      @claim_store         = ClaimStore.new(root: @root)
      @consolidation_store         = ConsolidationStore.new(root: @root)
      @consolidation_groups_store  = ConsolidationGroupsStore.new(root: @root)
      @run_log             = RunLog.new(root: @root)
      @history_store       = HistoryStore.new(root: @root)
      @freentonic_client = FreentonicClient.new(
        base_url:     @freentonic_url,
        invoke_token: @freentonic_invoke_token,
        logger:       @logger
      )
      # Scheduler, freentonic_health, push_tokens are installed after
      # construction (same pattern as the old install_queue) so tests can
      # stub them with fakes.
      @scheduler         = nil
      @freentonic_health = nil
      @push_tokens       = nil
      @notifier          = nil
      @watchdog          = nil
    end

    # Test/injection hook — swap the FreentonicClient with a fake.
    def install_freentonic_client(client)
      @freentonic_client = client
    end

    def install_scheduler(scheduler)
      @scheduler = scheduler
    end

    def install_freentonic_health(health)
      @freentonic_health = health
    end

    def install_push_tokens(table)
      @push_tokens = table
    end

    def install_notifier(notifier)
      @notifier = notifier
    end

    def install_watchdog(watchdog)
      @watchdog = watchdog
    end

    # Back-compat shim — older code path referred to @queue. The Scheduler
    # exposes the same external surface (enqueue, active_key, active_job,
    # pending_keys) so admin_api can reach it via either name.
    def queue
      @scheduler
    end

    # Background sweeper that periodically GCs expired claims and stale
    # cache files. Returns self so the caller can chain .stop later.
    def start_housekeeper(interval_seconds: 3600, cache_max_age_seconds: 14 * 24 * 3600)
      @housekeeper_stopping = false
      @housekeeper_thread = Thread.new do
        until @housekeeper_stopping
          interval_seconds.times do
            break if @housekeeper_stopping
            sleep 1
          end
          break if @housekeeper_stopping
          begin
            removed_claims = @claim_store.gc!
            removed_cache  = @cache_store.gc!(max_age_seconds: cache_max_age_seconds)
            removed_tokens = @push_tokens ? @push_tokens.cleanup_expired : 0
            if removed_claims.positive? || removed_cache.positive? || removed_tokens.positive?
              log("housekeeper: removed #{removed_claims} claim(s), #{removed_cache} stale cache(s), #{removed_tokens} expired token(s)")
            end
          rescue StandardError => e
            log("housekeeper error: #{e.class}: #{e.message}")
          end
        end
      end
      self
    end

    def stop_housekeeper(timeout: 5)
      @housekeeper_stopping = true
      @housekeeper_thread&.join(timeout)
      @housekeeper_thread = nil
    end

    # Auto-sync ticker. Each profile may set sync_interval_seconds in its
    # admin config — when set, the ticker enqueues a sync once that many
    # seconds have elapsed since the last successful sync.
    #
    # Gating:
    #   - never auto-enqueue while state ∈ { running, queued, needs_reauth }.
    #   - skip profiles without access_url_configured (nothing to serve yet).
    #   - always re-read profiles on each tick so admin-UI edits take effect
    #     without a restart.
    def start_auto_sync_ticker(tick_seconds: 60)
      @ticker_stopping = false
      @ticker_thread = Thread.new do
        until @ticker_stopping
          auto_sync_tick
          tick_seconds.times do
            break if @ticker_stopping
            sleep 1
          end
        end
      end
      self
    end

    def stop_auto_sync_ticker(timeout: 5)
      @ticker_stopping = true
      @ticker_thread&.join(timeout)
      @ticker_thread = nil
    end

    # Visible to tests — one pass through every profile.
    def auto_sync_tick
      @profile_store.list.each do |profile|
        key = profile["profile_key"]
        interval = profile["sync_interval_seconds"]
        next if interval.nil? || interval.to_i <= 0
        next unless profile.dig("access_url", "password_pw")

        state = @state_store.read(key)
        next if %w[running queued needs_reauth].include?(state["state"])

        # Pace on the last ATTEMPT, not the last success. Failures no longer
        # bump last_synced_at (so staleness stays honest), so gating on it
        # here would re-enqueue a permanently-failing profile every single
        # tick. Fall back to last_synced_at for profiles written before
        # last_attempt_at existed.
        last_at = state["last_attempt_at"] || state["last_synced_at"]
        last_ts = last_at ? (Time.parse(last_at).to_f rescue 0.0) : 0.0
        next if (Time.now.to_f - last_ts) < interval

        @scheduler&.enqueue(key, headed: false, trigger: "auto")
      end
    rescue StandardError => e
      log("auto_sync_tick error: #{e.class}: #{e.message}")
    end

    # Reset any `queued` / `running` state to `idle` on boot — the in-memory
    # queue is ephemeral and Actual will re-enqueue on the next /accounts
    # call. Also GCs expired claims + stale caches once.
    def recover_on_boot!
      @state_store.all.each do |key, state|
        if %w[queued running].include?(state["state"])
          @state_store.force_state(key, "idle",
            "last_error" => "recovered from restart (previous state: #{state["state"]})")
        end
      end
      @claim_store.gc!
      @cache_store.gc!
    end

    def log(msg)
      @logger.call("[simplefreen] #{msg}")
    end

    # ── config derivation from ENV ──────────────────────────

    MASTER_KEY_ENV   = "SIMPLEFREEN_SECRETS_KEY"
    ADMIN_PW_ENV     = "SIMPLEFREEN_ADMIN_PASSWORD"
    PUBLIC_URL_ENV   = "SIMPLEFREEN_PUBLIC_URL"
    ROOT_ENV         = "SIMPLEFREEN_ROOT"
    CORS_ENV         = "SIMPLEFREEN_CORS_ALLOWED_ORIGINS"
    INTERNAL_URL_ENV = "SIMPLEFREEN_INTERNAL_PUSH_URL"
    RUNS_ARTIFACTS_DIR_ENV = "SIMPLEFREEN_RUNS_ARTIFACTS_DIR"
    FREENTONIC_URL_ENV   = "FREENTONIC_URL"
    FREENTONIC_TOKEN_ENV = "FREENTONIC_INVOKE_TOKEN"

    # Build a Feature from ENV. Raises ConfigError listing every missing
    # piece of config so operators can fix them in one pass.
    def self.from_env(logger: nil)
      required = {
        MASTER_KEY_ENV       => ENV[MASTER_KEY_ENV],
        ADMIN_PW_ENV         => ENV[ADMIN_PW_ENV],
        PUBLIC_URL_ENV       => ENV[PUBLIC_URL_ENV],
        FREENTONIC_URL_ENV   => ENV[FREENTONIC_URL_ENV],
        FREENTONIC_TOKEN_ENV => ENV[FREENTONIC_TOKEN_ENV]
      }
      missing = required.select { |_, v| v.to_s.empty? }.keys
      unless missing.empty?
        raise ConfigError,
          "simplefreen: missing required env vars: #{missing.join(", ")}"
      end

      master_key = begin
        Crypto.decode_master_key(ENV.fetch(MASTER_KEY_ENV))
      rescue ArgumentError => e
        raise ConfigError, "simplefreen: #{MASTER_KEY_ENV} invalid: #{e.message}"
      end

      new(
        root:                    ENV[ROOT_ENV] || Paths.root,
        master_key:              master_key,
        admin_password:          ENV.fetch(ADMIN_PW_ENV),
        public_url:              ENV.fetch(PUBLIC_URL_ENV),
        freentonic_url:          ENV.fetch(FREENTONIC_URL_ENV),
        freentonic_invoke_token: ENV.fetch(FREENTONIC_TOKEN_ENV),
        internal_push_url:       ENV[INTERNAL_URL_ENV],
        cors_allowed_origins:    (ENV[CORS_ENV] || "").split(",").map(&:strip).reject(&:empty?),
        runs_artifacts_dir:      (ENV[RUNS_ARTIFACTS_DIR_ENV] || "/workspace/runs"),
        logger:                  logger
      )
    end
  end
end
