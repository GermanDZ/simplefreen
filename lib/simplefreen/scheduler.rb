# frozen_string_literal: true

require "date"
require "securerandom"
require "time"

require_relative "freentonic_client"
require_relative "paths"

module Simplefreen
  # In-memory sync dispatcher. A single worker thread pops profile keys
  # and drives FreentonicClient#invoke for each. External surface
  # matches the old SyncQueue (enqueue / active_key / active_job /
  # pending_keys) so existing admin_api / protocol / UI code reuses it.
  #
  # Serialization: only one /invoke call in flight at a time. Freentonic
  # itself enforces one Chrome at a time, but we also serialize on our
  # side so we don't pile up outbound HTTP calls.
  class Scheduler
    # Freentonic maps ReauthRequired (the `kind: reauth` error_signal) to
    # exit code 3. Translated here to the `needs_reauth` state.
    NEEDS_REAUTH_EXIT_CODE = 3

    Job = Struct.new(:profile_key, :headed, :trigger, :vnc_password, :interactive, :lookback, :recording, keyword_init: true)

    def initialize(feature:, default_timeout_sec: 1800)
      @feature             = feature
      @default_timeout_sec = default_timeout_sec
      @queue_mutex = Mutex.new
      @queue_cv    = ConditionVariable.new
      @invoke_mutex = Mutex.new
      @queue        = []
      @stopping     = false
      @thread       = nil
      @active_key   = nil
      @active_job   = nil
    end

    def start
      @thread ||= Thread.new { run_loop }
      self
    end

    def stop(timeout: 30)
      @queue_mutex.synchronize do
        @stopping = true
        @queue_cv.broadcast
      end
      @thread&.join(timeout)
      @thread = nil
    end

    # Liveness probe for /healthz and /admin/api/metrics. A dead worker
    # silently wedges every future sync (the queue keeps filling, nothing
    # drains it), so the operator needs to be able to see it. Reports false
    # once #stop has cleared the thread, which is expected during shutdown.
    def worker_alive?
      t = @thread
      !!(t&.alive?)
    end

    # Enqueue a sync for a profile. Idempotent — no-op when the profile
    # is already queued or running — matches the old SyncQueue contract.
    #
    # Every job gets a one-shot VNC password whether or not the caller
    # supplied one. Chrome is always windowed (banks block headless),
    # noVNC + websockify are always running in the freentonic
    # container, and the operator may want to watch any sync — there's
    # no reason to gate VNC behind a flag. The `headed` parameter
    # stays for the prominent "Re-authenticate (VNC)" button styling
    # when state == needs_reauth, but the underlying behavior is now
    # identical to a normal sync.
    def enqueue(profile_key, headed: false, trigger: "auto", vnc_password: nil, interactive: false, lookback: nil, recording: false)
      Paths.validate_component!(profile_key, "profile_key")
      # Virtual profiles aggregate other sources' canonicals at serve
      # time and have no workflow of their own — refuse to enqueue
      # rather than fail late inside the freentonic invoke.
      profile = @feature.profile_store.read(profile_key)
      if profile && profile["kind"] == "virtual"
        return :virtual_profile_not_syncable
      end
      vnc_password ||= mint_vnc_password
      @queue_mutex.synchronize do
        return :already_active if @active_key == profile_key
        return :already_queued if @queue.any? { |j| j.profile_key == profile_key }
        @queue << Job.new(profile_key: profile_key, headed: headed,
                          trigger: trigger, vnc_password: vnc_password,
                          interactive: interactive, lookback: lookback,
                          recording: recording)
        @queue_cv.signal
      end
      @feature.state_store.update(profile_key) do |state|
        next :abort if state["state"] == "running"
        state.merge("state" => "queued", "last_error" => nil)
      end
      :enqueued
    end

    # 8 alphanumeric chars. VNC's DES-based auth truncates at 8 chars,
    # so anything longer is wasted entropy; 8 chars of [A-Za-z0-9] is
    # ~48 bits of entropy, plenty for a per-run throwaway. Mirrors the
    # AdminApi#random_vnc_password helper used by manual triggers.
    def mint_vnc_password
      alphabet = (("A".."Z").to_a + ("a".."z").to_a + ("0".."9").to_a)
      Array.new(8) { alphabet.sample(random: SecureRandom) }.join
    end

    def pending_keys
      @queue_mutex.synchronize { @queue.map(&:profile_key) }
    end

    def active_key
      @queue_mutex.synchronize { @active_key.dup }
    end

    def active_job
      @queue_mutex.synchronize { @active_job ? @active_job.dup : nil }
    end

    # ── worker ───────────────────────────────────────────────

    private

    def run_loop
      loop do
        job = dequeue
        break unless job

        begin
          if freentonic_degraded?
            reenqueue_and_back_off(job)
          else
            process_job(job)
          end
        rescue StandardError => e
          # A store / run-log / IO failure (e.g. ENOSPC while writing the
          # "running" state, or run_log.record blowing up) escaped
          # process_job's inner rescues. Historically this re-raised and
          # KILLED the worker thread — after which every enqueue silently
          # piled up in a queue nobody drained, with /healthz still green.
          # Log it, best-effort-mark the profile errored, and keep looping.
          @feature.log("scheduler worker error on #{job.profile_key}: #{e.class}: #{e.message}")
          mark_worker_error(job, e)
        ensure
          @queue_mutex.synchronize do
            @active_key = nil
            @active_job = nil
          end
        end
      end
    rescue StandardError => e
      # Only reached if dequeue itself (the mutex / condition variable)
      # explodes — genuinely unrecoverable. Everything per-job is caught above.
      @feature.log("scheduler worker crashed in dequeue: #{e.class}: #{e.message}")
      raise
    end

    # Best-effort transition to `error` when an unexpected exception escapes
    # process_job. Guarded because the original failure was very likely a
    # store-write error, in which case this write will fail too — we must
    # not let that re-raise out of the worker loop.
    def mark_worker_error(job, error)
      @feature.state_store.force_state(job.profile_key, "error",
        "last_error"      => "internal scheduler error: #{error.class}",
        "last_attempt_at" => Time.now.utc.iso8601)
    rescue StandardError => e
      @feature.log("scheduler could not persist error state for #{job.profile_key}: #{e.class}: #{e.message}")
    end

    def dequeue
      @queue_mutex.synchronize do
        @queue_cv.wait(@queue_mutex) while @queue.empty? && !@stopping
        return nil if @stopping && @queue.empty?
        popped = @queue.shift
        @active_key = popped&.profile_key
        popped
      end
    end

    # If freentonic is down, drop the job's "running" state back to
    # "error" with a clear reason and sleep a bit so the caller isn't
    # hammered. Next tick of the health monitor will hopefully restore.
    def reenqueue_and_back_off(job)
      @feature.state_store.force_state(job.profile_key, "error",
        "last_error" => "freentonic upstream is degraded — sync deferred")
      @feature.log("scheduler deferred #{job.profile_key}: freentonic health = degraded")
      sleep 10
    end

    def freentonic_degraded?
      health = @feature.freentonic_health
      return false unless health # tests without the health monitor installed
      health.state == :degraded
    end

    def process_job(job)
      profile = @feature.profile_store.read(job.profile_key)
      unless profile
        @feature.log("job skipped: profile #{job.profile_key} missing")
        return
      end

      run_id = mint_run_id(job.profile_key)

      @queue_mutex.synchronize do
        @active_job = {
          profile_key:  job.profile_key,
          run_id:       run_id,
          headed:       !!job.headed,
          interactive: !!job.interactive,
          recording:    !!job.recording,
          # Always expose the VNC password — every job gets one (see
          # #enqueue) and the inline iframe uses it. Bearer-auth
          # protects this surface; the password is per-run and dies
          # with Chrome anyway.
          vnc_password: job.vnc_password,
          trigger:      job.trigger,
          started_at:   Time.now.utc.iso8601
        }
      end

      @feature.state_store.force_state(job.profile_key, "running",
        "last_error" => nil, "started_at" => Time.now.utc.iso8601)

      # TTL must outlive the sync itself: freentonic pushes at the very end
      # of the run, so a token that expired mid-run would 401 the push and
      # silently lose the data. Bind it to this run's configured timeout
      # (plus a small buffer) rather than PushTokens' fixed default.
      push_token = @feature.push_tokens&.mint(run_id, ttl_seconds: @default_timeout_sec + 60)

      body = begin
        build_invoke_body(profile, job, run_id: run_id, push_token: push_token)
      rescue OperatorError => e
        # Operator-facing reason — surface verbatim with no class
        # prefix, since the message was authored to be read by a human.
        finalize_failure(job, run_id, outcome: "error",
          message: e.message,
          exit_code: nil, duration_ms: 0)
        return
      rescue StandardError => e
        finalize_failure(job, run_id, outcome: "error",
          message: "invoke setup failed: #{e.class}: #{e.message}",
          exit_code: nil, duration_ms: 0)
        return
      end

      started_at = Time.now
      result = nil
      begin
        @invoke_mutex.synchronize do
          result = @feature.freentonic_client.invoke(body)
        end
      rescue FreentonicClient::TimeoutError => e
        @feature.push_tokens&.discard_for_run(run_id)
        finalize_failure(job, run_id, outcome: "error",
          message: "freentonic invoke timed out: #{e.message}",
          exit_code: nil, duration_ms: ((Time.now - started_at) * 1000).to_i)
        return
      rescue FreentonicClient::ConnectionError, FreentonicClient::HttpError,
             FreentonicClient::Error => e
        @feature.push_tokens&.discard_for_run(run_id)
        finalize_failure(job, run_id, outcome: "error",
          message: "freentonic invoke failed: #{e.class}: #{e.message}",
          exit_code: nil, duration_ms: ((Time.now - started_at) * 1000).to_i)
        return
      rescue StandardError => e
        @feature.push_tokens&.discard_for_run(run_id)
        @feature.log("scheduler #{run_id} crashed: #{e.class}: #{e.message}")
        finalize_failure(job, run_id, outcome: "error",
          message: "#{e.class}: #{e.message}",
          exit_code: nil, duration_ms: ((Time.now - started_at) * 1000).to_i)
        return
      end

      finished_at = Time.now
      duration_ms = ((finished_at - started_at) * 1000).to_i
      exit_code = result.exit_code.to_i

      # Always clear the mint-table entry when /invoke returns, regardless
      # of outcome — it's either been consumed by a push or it's now
      # useless (no further push will arrive for this run).
      @feature.push_tokens&.discard_for_run(run_id)

      # Browse mode never produces sync output and shouldn't move the
      # profile's sync state — the operator was just interacting with
      # Chrome. Reset to `idle` regardless of how the run ended (clean
      # cancel returns non-zero exit, but that's expected here).
      if job.interactive
        finalize_browse(job, run_id,
          exit_code: exit_code, duration_ms: duration_ms,
          error_kind: result.error_kind,
          started_at: started_at, finished_at: finished_at)
        return
      end

      if exit_code.zero?
        # Did THIS run's push actually land? The push receiver stamps
        # state.last_run_id with the run it merged, so that's the
        # authoritative signal. The old check — cache_store.exists? — was
        # satisfied by ANY prior run's cache file (caches live 14 days),
        # so a restart mid-invoke that dropped the push token (→ 401 push,
        # exit 0) would read a stale cache as success and log "sync ok"
        # while history never advanced. Trust last_run_id, not file presence.
        if push_landed?(job.profile_key, run_id)
          finalize_success(job, run_id,
            exit_code: exit_code, duration_ms: duration_ms,
            error_kind: result.error_kind,
            started_at: started_at, finished_at: finished_at)
        else
          @feature.log("sync #{run_id} succeeded but no push arrived — state marked error")
          finalize_failure(job, run_id, outcome: "error",
            message: "freentonic completed but no payload was pushed",
            exit_code: exit_code, duration_ms: duration_ms,
            error_kind: result.error_kind,
            started_at: started_at, finished_at: finished_at)
        end
      elsif exit_code == NEEDS_REAUTH_EXIT_CODE
        finalize_failure(job, run_id, outcome: "needs_reauth",
          message: "workflow emitted needs_reauth signal",
          exit_code: exit_code, duration_ms: duration_ms,
          error_kind: result.error_kind,
          started_at: started_at, finished_at: finished_at)
      else
        suffix = result.error_kind ? " (#{result.error_kind})" : ""
        finalize_failure(job, run_id, outcome: "error",
          message: "exit #{exit_code}#{suffix}",
          exit_code: exit_code, duration_ms: duration_ms,
          error_kind: result.error_kind,
          started_at: started_at, finished_at: finished_at)
      end
    end

    # Did the push for this specific run land? The push receiver sets
    # state.last_run_id = run_id after it writes the cache (even on the
    # merge-failure fallback path, where the per-run envelope is still
    # served), so this is true iff this run's data is actually being served.
    def push_landed?(profile_key, run_id)
      @feature.state_store.read(profile_key)["last_run_id"] == run_id
    end

    # Terminal success handling. The push receiver already flipped the
    # profile to :ready when the payload arrived; re-affirm the terminal
    # fields so last_synced_at / last_attempt_at reflect this run, and
    # record the run-log entry. last_synced_at means "last SUCCESS" — it is
    # deliberately NOT written by finalize_failure, so staleness metrics and
    # the auto-sync ticker can tell a stuck profile from a fresh one.
    def finalize_success(job, run_id, exit_code:, duration_ms:, error_kind:,
                         started_at:, finished_at:)
      now = finished_at || Time.now
      @feature.state_store.force_state(job.profile_key, "ready",
        "last_run_id"     => run_id,
        "last_error"      => nil,
        "last_synced_at"  => now.utc.iso8601,
        "last_attempt_at" => now.utc.iso8601)
      @feature.run_log.record(job.profile_key,
        run_id: run_id,
        started_at:  (started_at || now).utc.iso8601,
        finished_at: now.utc.iso8601,
        duration_ms: duration_ms,
        exit_code: exit_code,
        error_kind: error_kind,
        outcome: "ready",
        message: "sync ok",
        headed: job.headed,
        trigger: job.trigger)
    end

    def finalize_failure(job, run_id, outcome:, message:, exit_code:, duration_ms:,
                         error_kind: "scheduler", started_at: nil, finished_at: nil)
      now = Time.now
      # Record the attempt time, but do NOT touch last_synced_at — a failed
      # sync must not look "fresh". last_attempt_at is what paces retries.
      @feature.state_store.force_state(job.profile_key, outcome,
        "last_run_id"     => run_id,
        "last_error"      => message,
        "last_attempt_at" => now.utc.iso8601)
      @feature.run_log.record(job.profile_key,
        run_id: run_id,
        started_at:  (started_at || now).utc.iso8601,
        finished_at: (finished_at || now).utc.iso8601,
        duration_ms: duration_ms,
        exit_code: exit_code,
        error_kind: error_kind,
        outcome: outcome,
        message: message,
        headed: job.headed,
        trigger: job.trigger)
    end

    # Browse-mode end-of-run handling. Resets the profile state to
    # `idle` (browsing didn't change the bank cache) and records a
    # `browsed` run log entry so the operator can see when they last
    # interacted manually. Cancel-driven non-zero exits are normal in
    # this mode — the SIGTERM from `POST /cancel/<run_id>` is how we
    # tell freentonic the operator is done.
    def finalize_browse(job, run_id, exit_code:, duration_ms:,
                        error_kind: nil, started_at: nil, finished_at: nil)
      now = Time.now
      # Browsing didn't fetch bank data, so it must not advance
      # last_synced_at (that would falsely reset the staleness clock). It's
      # still an attempt for retry-pacing purposes.
      @feature.state_store.force_state(job.profile_key, "idle",
        "last_run_id"     => run_id,
        "last_error"      => nil,
        "last_attempt_at" => now.utc.iso8601)
      @feature.run_log.record(job.profile_key,
        run_id: run_id,
        started_at:  (started_at || now).utc.iso8601,
        finished_at: (finished_at || now).utc.iso8601,
        duration_ms: duration_ms,
        exit_code: exit_code,
        error_kind: error_kind,
        outcome: "browsed",
        message: "interactive browse session ended",
        headed: job.headed,
        trigger: job.trigger)
    end

    def mint_run_id(profile_key)
      "simplefreen-#{profile_key}-#{SecureRandom.hex(6)}"
    end

    def build_invoke_body(profile, job, run_id:, push_token:)
      creds = decrypted_credentials(profile)
      # freentonic rejects the request with 422 if credentials.inline
      # is empty, but the resulting state.last_error message ("invoke
      # failed: HTTP 422: …") is opaque. Surface a clean operator-
      # facing reason here. This also catches the race where the
      # operator deletes credentials after enqueue but before the
      # worker picks the job up — admin_api precheck wouldn't catch
      # that one.
      if creds.nil? || creds.empty?
        raise OperatorError, "no credentials configured — open the Credentials panel and save at least one field"
      end
      push_url = "#{@feature.internal_push_url}/push/#{run_id}"

      body = {
        "run_id"      => run_id,
        "workflow"    => profile.fetch("workflow"),
        "profile_key" => profile.fetch("profile_key"),
        "credentials" => { "inline" => creds },
        "export" => {
          "mode"  => "http",
          "url"   => push_url,
          "token" => push_token.to_s
        },
        # Always run Chrome windowed (against freentonic's Xvfb display),
        # never headless — banks fingerprint the headless Chromium build
        # and outright block it. The container's virtual display is fine
        # whether or not anyone is actually watching via VNC. The
        # `job.headed` flag stays meaningful: it controls whether we
        # mint a VNC password and surface the noVNC URL to the operator.
        "chrome" => { "headless" => false },
        "timeout_sec" => @default_timeout_sec
      }
      # Per-sync lookback override wins over everything else. Useful when
      # a provider needs a one-off long backfill — the operator dials in
      # 180 from "Sync now" without mutating the profile.
      lookback = resolve_lookback(profile, job)
      body["lookback"] = lookback if lookback
      # Always send the per-run VNC password — Chrome runs windowed for
      # every sync (see chrome.headless = false above), so noVNC needs
      # the password regardless of whether anyone is currently watching.
      body["vnc_password"] = job.vnc_password if job.vnc_password
      # Browse mode: freentonic short-circuits the engine at the
      # `connect` phase and idles until cancelled. The export block
      # is sent for consistency with normal syncs but freentonic
      # ignores it under interactive=true.
      body["interactive"] = true if job.interactive
      # Recording mode: same idle semantics as interactive but Chrome
      # is launched on the CDP path and a probe captures click /
      # change / submit / navigate events to <run_dir>/recording.jsonl
      # for the operator to read after stopping.
      body["recording"] = true if job.recording
      body
    end

    def decrypted_credentials(profile)
      @feature.profile_store.read_credentials(profile.fetch("profile_key"),
        master_key: @feature.master_key)
    end

    # Pick the lookback (in days) we'll send to freentonic for this sync.
    #
    # Precedence:
    #   1. job.lookback                — explicit operator override
    #   2. lookback_mode == "incremental" (default) + history available
    #      → days_since_last_tx + overlap, clamped to [overlap, max_lookback]
    #   3. lookback_mode == "incremental" without history (cold start)
    #      → max_lookback_days (deep backfill so the durable base is seeded
    #        before subsequent runs go incremental)
    #   4. lookback_mode == "fixed" → lookback_days
    #
    # Profiles created before lookback_mode existed have a nil/missing
    # mode field and are treated as "incremental" — the new default. To
    # keep a profile on a fixed-window schedule, set lookback_mode
    # explicitly to "fixed".
    #
    # The clamp matters in two directions: a freshly-installed Actual that
    # syncs every few minutes shouldn't request 0-day windows (freentonic
    # would silently scrape nothing and we'd never catch a late posting);
    # and an account that's been idle for a year shouldn't drag the
    # scraper through a 1000-day window — max_lookback_days is the ceiling
    # the operator already configured for that profile.
    def resolve_lookback(profile, job, today: Date.today)
      return job.lookback if job&.lookback

      mode = profile["lookback_mode"].to_s
      mode = "incremental" if mode.empty?
      return profile["lookback_days"] if mode == "fixed"

      max_lb  = (profile["max_lookback_days"] || 365).to_i
      overlap = (profile["lookback_overlap_days"] || 10).to_i

      last_seen = last_tx_date_for(profile)
      return max_lb if last_seen.nil?

      days = (today - last_seen).to_i + overlap
      days = overlap if days < overlap
      days = max_lb if days > max_lb
      days
    end

    def last_tx_date_for(profile)
      store = @feature.history_store
      return nil unless store
      raw = store.last_tx_date(profile.fetch("profile_key"))
      return nil unless raw.is_a?(String)
      Date.parse(raw)
    rescue ArgumentError
      nil
    end
  end
end
