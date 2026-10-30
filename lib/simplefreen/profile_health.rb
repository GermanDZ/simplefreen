# frozen_string_literal: true

require "time"

module Simplefreen
  # Shared staleness / health classification for a profile. Extracted so the
  # /admin/api/metrics scrape, the /healthz body, and the Watchdog all agree
  # on exactly what "stale" means — a profile that looks fresh to one surface
  # and stale to another is the silent-failure class this whole feature exists
  # to close.
  module ProfileHealth
    # Freshness floor. Even a profile that syncs every minute isn't considered
    # stale until its last SUCCESS is older than max(2× interval, this) — the
    # threshold from docs/virtual-profile-design.md.
    MIN_STALE_THRESHOLD_SECONDS = 24 * 3600

    module_function

    # A profile is stale when it is configured to auto-sync (interval set and
    # an access URL provisioned, mirroring Feature#auto_sync_tick's gating)
    # but its last SUCCESSFUL sync is older than max(2× interval, 24h). A
    # profile that has never synced but is configured to counts as stale
    # (it's overdue). A profile that isn't configured to auto-sync is never
    # stale — there's no schedule to fall behind.
    def stale?(profile, state, now = Time.now)
      interval = profile["sync_interval_seconds"].to_i
      return false unless interval > 0
      return false unless profile.dig("access_url", "password_pw")
      threshold = [interval * 2, MIN_STALE_THRESHOLD_SECONDS].max
      last = state["last_synced_at"]
      return true if last.nil?
      (now - Time.parse(last)).to_i > threshold
    rescue ArgumentError
      # Unparseable last_synced_at — treat as broken → stale, so it surfaces
      # rather than silently reading as fresh.
      true
    end

    # The single most actionable alertable condition for a profile, most
    # specific first. Returns one of the CONDITIONS strings.
    #
    #   "needs_reauth" — the bank kicked us out; only the operator can fix it
    #   "error"        — the last sync failed for some other reason
    #   "stale"        — no hard failure, but success is overdue (a quietly
    #                    wedged profile: session expired mid-run, scraper
    #                    silently returning nothing, etc.)
    #   "ok"           — nothing to alert on
    #
    # needs_reauth / error win over stale because they carry a concrete reason
    # and a clear next step; a needs_reauth profile is also stale, but the
    # reauth message is the useful one.
    CONDITIONS = %w[ok stale error needs_reauth].freeze

    def condition(profile, state, now = Time.now)
      case state["state"]
      when "needs_reauth" then "needs_reauth"
      when "error"        then "error"
      else
        stale?(profile, state, now) ? "stale" : "ok"
      end
    end
  end
end
