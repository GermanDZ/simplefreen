# frozen_string_literal: true

require "time"

require_relative "atomic_file"
require_relative "paths"
require_relative "profile_health"

module Simplefreen
  # Background health watchdog. Periodically walks every profile plus the
  # scheduler worker and pushes a notification (via Notifier → ntfy) when
  # something needs the operator's attention:
  #
  #   * a profile enters `needs_reauth` or `error`
  #   * a profile goes stale (configured to sync, last success overdue)
  #   * the scheduler worker thread has died (wedges all future syncs)
  #   * — and a low-priority "recovered" note when any of the above clears
  #
  # This closes the review's O-2 / P1 gap: before it, a nightly sync could
  # fail or quietly stop advancing while every pull surface still read green.
  #
  # Edge-triggered with re-reminders. We alert on the transition into a
  # problem (and on a change of problem type), then stay quiet until either
  # the condition clears or `renotify_seconds` elapses — so a chronically
  # broken profile pings once a day, not once per tick. The last-alerted
  # condition per subject is persisted (watchdog.json) so a restart doesn't
  # re-spam every currently-broken profile, and the re-reminder clock
  # survives deploys.
  #
  # Thread shape mirrors FreentonicHealth: one immediate pass on start, then
  # a cooperative sleep loop; #check_once is exposed so tests drive it
  # deterministically without the thread.
  class Watchdog
    DEFAULT_INTERVAL_SECONDS = 5 * 60
    DEFAULT_RENOTIFY_SECONDS = 24 * 3600

    # Non-profile subject key for the scheduler worker. The double underscore
    # can't collide with a profile_key (those match FILENAME_PATTERN but this
    # is only ever a hash key, never a path component).
    SCHEDULER_SUBJECT = "__scheduler__"

    def initialize(feature:, notifier:, interval_seconds: DEFAULT_INTERVAL_SECONDS,
                   renotify_seconds: DEFAULT_RENOTIFY_SECONDS, logger: nil,
                   clock: -> { Time.now })
      @feature          = feature
      @notifier         = notifier
      @interval_seconds = interval_seconds
      @renotify_seconds = renotify_seconds
      @logger           = logger || ->(_msg) {}
      @clock            = clock
      @path             = Paths.watchdog_path(feature.root)
      @notified         = load_state
      @stopping         = false
      @thread           = nil
    end

    def start
      return self if @thread
      # Nothing to deliver to → don't spin a thread. bin/ also guards on
      # this, but keep the class self-contained.
      return self unless @notifier&.configured?
      @stopping = false
      @thread = Thread.new do
        check_once
        until @stopping
          @interval_seconds.times do
            break if @stopping
            sleep 1
          end
          break if @stopping
          check_once
        end
      end
      self
    end

    def stop(timeout: 5)
      @stopping = true
      @thread&.join(timeout)
      @thread = nil
    end

    # One full pass. Returns the list of notifications actually sent this pass
    # (each `{ subject:, condition: }`) so tests can assert without reaching
    # into the notifier. Never raises — a watchdog that crashes the process it
    # watches would be self-defeating.
    def check_once(now: @clock.call)
      return [] unless @notifier&.configured?
      sent = []
      dirty = false

      # Scheduler worker liveness first — a dead worker is the highest-
      # severity condition and independent of any profile.
      s_change = evaluate(SCHEDULER_SUBJECT, scheduler_condition, "scheduler worker", {}, now)
      if s_change
        dirty = true
        sent << s_change if s_change[:delivered]
      end

      @feature.profile_store.list.each do |profile|
        # Virtual profiles aggregate other sources at serve time; they have no
        # workflow of their own and never sync, so they can't be stale/errored.
        next if profile["kind"] == "virtual"
        key   = profile["profile_key"]
        state = @feature.state_store.read(key)
        cond  = ProfileHealth.condition(profile, state, now)
        change = evaluate(key, cond, label_for(profile), state, now)
        if change
          dirty = true
          sent << change if change[:delivered]
        end
      end

      persist if dirty
      sent
    rescue StandardError => e
      log("watchdog pass error: #{e.class}: #{e.message}")
      []
    end

    private

    def scheduler_condition
      sched = @feature.scheduler
      # No scheduler installed (stripped harness) → nothing to assert about.
      return "ok" if sched.nil?
      sched.worker_alive? ? "ok" : "worker_dead"
    end

    def label_for(profile)
      profile["display_name"] || profile["profile_key"]
    end

    # Compare the subject's current condition against what we last alerted on
    # and, when warranted, deliver a notification and update the dedup record.
    #
    # Returns nil when nothing about the subject's tracked state changed, or a
    # `{ subject:, condition:, delivered: }` descriptor when we either sent a
    # notification or mutated the dedup map (recovery clears the entry). The
    # `delivered` flag distinguishes "a notification went out" from "we only
    # cleared bookkeeping" so callers can report the former.
    def evaluate(subject, condition, label, state, now)
      prior = @notified[subject]
      prior_condition = prior && prior["condition"]

      if condition == "ok"
        return nil unless prior_condition # never alerted → nothing to clear
        # Recovered from a previously-alerted problem.
        deliver_recovery(label, prior_condition)
        @notified.delete(subject)
        return { subject: subject, condition: "ok", delivered: true }
      end

      changed = prior_condition != condition
      due = prior.nil? || changed || renotify_elapsed?(prior, now)
      return nil unless due

      deliver_problem(subject, label, condition, state)
      @notified[subject] = { "condition" => condition, "notified_at" => iso(now) }
      { subject: subject, condition: condition, delivered: true }
    end

    def renotify_elapsed?(prior, now)
      at = parse_time(prior["notified_at"])
      return true if at.nil?
      (now - at) >= @renotify_seconds
    end

    # ── delivery ─────────────────────────────────────────────

    def deliver_problem(subject, label, condition, state)
      reason = state["last_error"]
      case condition
      when "worker_dead"
        @notifier.notify(
          title: "simplefreen scheduler worker is dead",
          message: "The sync scheduler thread has died — no profile will " \
                   "sync until the service is restarted.",
          priority: 5, tags: %w[rotating_light]
        )
      when "needs_reauth"
        @notifier.notify(
          title: "#{label}: re-authentication needed",
          message: with_reason("The bank ended the session — re-authenticate " \
                               "from the admin UI (Re-authenticate / VNC).", reason),
          priority: 4, tags: %w[warning lock]
        )
      when "error"
        @notifier.notify(
          title: "#{label}: sync failed",
          message: with_reason("The last sync ended in error.", reason),
          priority: 4, tags: %w[x]
        )
      when "stale"
        @notifier.notify(
          title: "#{label}: sync is stale",
          message: stale_message(label, state),
          priority: 3, tags: %w[hourglass]
        )
      else
        # Defensive: unknown condition — still surface it rather than swallow.
        @notifier.notify(
          title: "#{label}: #{condition}",
          message: with_reason("Watchdog flagged an unexpected condition.", reason),
          priority: 3, tags: %w[grey_question]
        )
      end
    end

    def deliver_recovery(label, prior_condition)
      @notifier.notify(
        title: "#{label}: recovered",
        message: "Back to healthy (was #{human_condition(prior_condition)}).",
        priority: 2, tags: %w[white_check_mark]
      )
    end

    def stale_message(_label, state)
      last = state["last_synced_at"]
      if last
        "No successful sync recently — last success was #{last}. The profile " \
          "may be silently failing (expired session, scraper returning nothing)."
      else
        "This profile is configured to auto-sync but has never synced " \
          "successfully. Check its credentials / workflow."
      end
    end

    def with_reason(text, reason)
      r = reason.to_s.strip
      r.empty? ? text : "#{text}\n\nReason: #{r}"
    end

    def human_condition(condition)
      case condition
      when "worker_dead"  then "a dead scheduler worker"
      when "needs_reauth" then "needs_reauth"
      else condition
      end
    end

    # ── persistence ──────────────────────────────────────────

    def load_state
      data = AtomicFile.read_json(@path, default: {})
      data.is_a?(Hash) ? data : {}
    rescue StandardError => e
      log("watchdog could not read #{@path}: #{e.class}: #{e.message}")
      {}
    end

    def persist
      AtomicFile.write_json(@path, @notified)
    rescue StandardError => e
      # Losing dedup state just means a possible duplicate alert later — never
      # fatal. Log and carry on.
      log("watchdog could not persist #{@path}: #{e.class}: #{e.message}")
    end

    def iso(time)
      time.utc.iso8601
    end

    def parse_time(str)
      Time.parse(str.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def log(msg)
      @logger.call("[simplefreen] #{msg}")
    end
  end
end
