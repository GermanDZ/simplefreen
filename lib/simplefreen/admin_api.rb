# frozen_string_literal: true

require "base64"
require "json"
require "time"
require "yaml"

require_relative "atomic_file"
require_relative "crypto"
require_relative "http"
require_relative "paths"
require_relative "profile_health"

module Simplefreen
  # Admin REST API (Bearer `SIMPLEFREEN_ADMIN_PASSWORD`). Every handler
  # returns JSON. Charset-validates every user-supplied id before
  # touching disk. Never returns plaintext credentials on reads.
  class AdminApi
    MAX_LOG_BYTES = 256 * 1024

    # Host port the example compose publishes for freentonic's noVNC
    # surface. Picked away from the noVNC-default 6080 to avoid
    # collisions with other dev-box services. Operators who reach
    # noVNC through their own reverse-proxy / port mapping can ignore
    # the URL the admin UI builds — it's just a click hint.
    NOVNC_HOST_PORT = 17080

    def initialize(feature:, workflows_dir:)
      @feature       = feature
      @workflows_dir = workflows_dir
    end

    def dispatch(client, method, path, request)
      pathname, params = Http.split_query(path)
      return unauthorized(client) unless bearer_authenticated?(request)

      case
      when pathname == "/admin/api/status" && method == "GET"
        handle_status(client)
      when pathname == "/admin/api/metrics" && method == "GET"
        handle_metrics(client)
      when pathname == "/admin/api/workflows" && method == "GET"
        handle_workflows(client)
      when pathname == "/admin/api/workflows/refresh" && method == "POST"
        handle_workflows_refresh(client, request)
      when pathname == "/admin/api/profiles" && method == "GET"
        handle_list(client)
      when pathname == "/admin/api/profiles" && method == "POST"
        handle_create(client, request)
      when pathname == "/admin/api/sync-all" && method == "POST"
        handle_sync_all(client)
      when (match = pathname.match(%r{\A/admin/api/profiles/([^/]+)\z}))
        handle_profile(client, match[1], method, request)
      when (match = pathname.match(%r{\A/admin/api/profiles/([^/]+)/credentials\z}))
        handle_credentials(client, match[1], method, request)
      when (match = pathname.match(%r{\A/admin/api/profiles/([^/]+)/sync\z}))
        handle_sync(client, match[1], method, request)
      when (match = pathname.match(%r{\A/admin/api/profiles/([^/]+)/clear-session\z}))
        return method_not_allowed(client) unless method == "POST"
        handle_clear_session(client, match[1])
      when (match = pathname.match(%r{\A/admin/api/profiles/([^/]+)/browse\z}))
        return method_not_allowed(client) unless method == "POST"
        handle_browse(client, match[1], request)
      when (match = pathname.match(%r{\A/admin/api/profiles/([^/]+)/record\z}))
        return method_not_allowed(client) unless method == "POST"
        handle_record(client, match[1])
      when (match = pathname.match(%r{\A/admin/api/runs/([^/]+)/cancel\z}))
        return method_not_allowed(client) unless method == "POST"
        handle_cancel_run(client, match[1])
      when (match = pathname.match(%r{\A/admin/api/profiles/([^/]+)/setup-token\z}))
        handle_setup_token(client, match[1], method)
      when (match = pathname.match(%r{\A/admin/api/profiles/([^/]+)/rotate-access-url\z}))
        handle_rotate(client, match[1], method)
      when (match = pathname.match(%r{\A/admin/api/profiles/([^/]+)/runs\z}))
        return method_not_allowed(client) unless method == "GET"
        handle_runs(client, match[1])
      when (match = pathname.match(%r{\A/admin/api/profiles/([^/]+)/history\z}))
        case method
        when "DELETE" then handle_history_reset(client, match[1])
        else method_not_allowed(client)
        end
      when (match = pathname.match(%r{\A/admin/api/profiles/([^/]+)/history/rebuild\z}))
        return method_not_allowed(client) unless method == "POST"
        handle_history_rebuild(client, match[1])
      when (match = pathname.match(%r{\A/admin/api/profiles/([^/]+)/runs/([^/]+)/log\z}))
        return method_not_allowed(client) unless method == "GET"
        handle_run_log(client, match[1], match[2], params)
      when (match = pathname.match(%r{\A/admin/api/profiles/([^/]+)/runs/([^/]+)/artifacts\z}))
        return method_not_allowed(client) unless method == "GET"
        handle_run_artifacts(client, match[1], match[2])
      when (match = pathname.match(%r{\A/admin/api/profiles/([^/]+)/runs/([^/]+)/artifacts/(\d+)\z}))
        return method_not_allowed(client) unless method == "GET"
        handle_run_artifact(client, match[1], match[2], match[3].to_i)
      when (match = pathname.match(%r{\A/admin/api/profiles/([^/]+)/runs/([^/]+)/canonical\z}))
        return method_not_allowed(client) unless method == "GET"
        handle_run_canonical(client, match[1], match[2])
      when (match = pathname.match(%r{\A/admin/api/profiles/([^/]+)/runs/([^/]+)/recording\z}))
        return method_not_allowed(client) unless method == "GET"
        handle_run_recording(client, match[1], match[2])
      when (match = pathname.match(%r{\A/admin/api/profiles/([^/]+)/runs/([^/]+)/prompts\z}))
        return method_not_allowed(client) unless method == "GET"
        handle_run_prompts(client, match[1], match[2])
      when (match = pathname.match(%r{\A/admin/api/profiles/([^/]+)/runs/([^/]+)/prompts/([^/]+)\z}))
        return method_not_allowed(client) unless method == "POST"
        handle_run_prompt_submit(client, match[1], match[2], match[3], request)
      when pathname == "/admin/api/freentonic/health/probe" && method == "POST"
        handle_freentonic_health_probe(client)
      when pathname == "/admin/api/consolidation/groups" && method == "GET"
        handle_consolidation_groups(client)
      when pathname == "/admin/api/consolidation/aliases" && method == "GET"
        handle_consolidation_aliases_list(client)
      when pathname == "/admin/api/consolidation/aliases" && method == "PUT"
        handle_consolidation_aliases_replace(client, request)
      when pathname == "/admin/api/consolidation/virtual-profile" && method == "POST"
        handle_consolidation_virtual_profile_create(client)
      when pathname == "/admin/api/consolidation/groups-config" && method == "GET"
        handle_consolidation_groups_config_list(client)
      when pathname == "/admin/api/consolidation/groups-config" && method == "PUT"
        handle_consolidation_groups_config_upsert(client, request)
      when pathname == "/admin/api/consolidation/preview" && method == "GET"
        handle_consolidation_preview(client)
      when pathname == "/admin/api/consolidation/export-preview" && method == "GET"
        handle_consolidation_export_preview(client)
      when pathname == "/admin/api/consolidation/groups-config/preview" && method == "POST"
        handle_consolidation_group_preview(client, request)
      else
        Http.write_json(client, 404, { "error" => "not found" })
      end
    rescue StandardError => e
      @feature.log("admin api error: #{e.class}: #{e.message}")
      Http.write_json(client, 500, { "error" => "internal server error" })
    end

    private

    def bearer_authenticated?(request)
      token = Http.bearer_token(request.headers["authorization"])
      return false if token.nil?
      Crypto.secure_compare(token, @feature.admin_password)
    end

    # ── handlers ────────────────────────────────────────────

    def handle_status(client)
      profiles = @feature.profile_store.list
      entries = profiles.map { |p| profile_summary(p) }
      active_job = @feature.queue&.active_job
      active_payload = nil
      if active_job
        active_payload = {
          "profile_key" => active_job[:profile_key],
          "run_id"      => active_job[:run_id],
          "headed"      => active_job[:headed],
          "interactive" => !!active_job[:interactive],
          "recording"   => !!active_job[:recording],
          "trigger"     => active_job[:trigger],
          "started_at"  => active_job[:started_at]
        }
        # Every job carries a VNC password now (see Scheduler#enqueue);
        # surface the URL so the inline iframe always shows up while a
        # sync is in flight, regardless of how it was triggered.
        if active_job[:vnc_password]
          active_payload["vnc_url"] = build_vnc_url(active_job[:vnc_password])
        end
      end
      Http.write_json(client, 200, {
        "profiles"   => entries,
        "active"     => @feature.queue&.active_key,
        "active_job" => active_payload,
        "pending"    => @feature.queue&.pending_keys || [],
        "server_ts"  => Time.now.utc.iso8601
      })
    end

    # Aggregate metrics across all profiles. Intended for a scrape by a
    # lightweight uptime monitor / dashboard. Not Prometheus-formatted —
    # plain JSON keeps the whole feature single-dependency.
    def handle_metrics(client)
      profiles = @feature.profile_store.list
      states   = Hash.new(0)
      last_ages = []
      error_count = 0
      stale_count = 0
      merge_failure_count = 0
      now = Time.now

      profiles.each do |profile|
        state = @feature.state_store.read(profile["profile_key"])
        states[state["state"]] += 1
        error_count += 1 if state["last_error"]
        merge_failure_count += 1 if state["history_merge_failed_at"]
        if state["last_synced_at"]
          last_ages << (now - Time.parse(state["last_synced_at"])).to_i rescue nil
        end
        stale_count += 1 if profile_stale?(profile, state, now)
      end

      runs_today = 0
      cutoff = (now - 24 * 3600).utc.iso8601
      profiles.each do |profile|
        @feature.run_log.recent(profile["profile_key"], limit: 100).each do |r|
          runs_today += 1 if r["started_at"] && r["started_at"] >= cutoff
        end
      end

      last_ages.compact!
      Http.write_json(client, 200, {
        "profiles_total"       => profiles.size,
        "profiles_by_state"    => states,
        "profiles_with_error"  => error_count,
        # Configured-to-sync profiles whose last SUCCESSFUL sync is overdue.
        # This is the number an uptime monitor should alarm on — it stays 0
        # when everything is fresh and rises the moment a bank quietly stops
        # syncing (expired session, scraper breakage), which no other single
        # metric here catches on its own.
        "profiles_stale"       => stale_count,
        # Profiles whose history union has stopped advancing even though the
        # push itself succeeded (data still served from the per-run envelope).
        "history_merge_failures" => merge_failure_count,
        # A dead worker wedges all future syncs; surface it here and in
        # /healthz so it can't fail silently.
        "scheduler_worker_alive" => @feature.scheduler.nil? || @feature.scheduler.worker_alive?,
        "runs_last_24h"        => runs_today,
        "queue" => {
          "active"  => @feature.queue&.active_key,
          "pending" => (@feature.queue&.pending_keys || []).size
        },
        "last_sync_age_seconds" => {
          "min"    => last_ages.min,
          "max"    => last_ages.max,
          "median" => median(last_ages)
        },
        "server_ts" => now.utc.iso8601
      })
    end

    # Delegates to the shared ProfileHealth classifier so the metrics scrape,
    # /healthz, and the Watchdog can never disagree on what "stale" means.
    def profile_stale?(profile, state, now)
      ProfileHealth.stale?(profile, state, now)
    end

    def median(arr)
      return nil if arr.nil? || arr.empty?
      sorted = arr.sort
      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : ((sorted[mid - 1] + sorted[mid]) / 2)
    end

    def handle_workflows(client)
      list = list_workflows.map do |rel|
        secrets = declared_secrets(rel)
        { "workflow" => rel, "secrets" => secrets }
      end
      Http.write_json(client, 200, {
        "workflows" => list,
        # Include the last refresh metadata so the admin UI can show
        # "ing @ v0.4.1 (abc1234)" without a second request.
        "meta"      => WorkflowsRefresher.read_meta(@workflows_dir)
      })
    end

    # Pull a fresh tarball of provider workflow YAMLs from a GitHub
    # repo and lay them down under @workflows_dir. The dropdown re-
    # populates on the next /workflows GET. Body params:
    #   ref:  branch / tag / commit SHA — anything GitHub's tarball API
    #         resolves. Defaults to "main".
    # Source repo is overridable via SIMPLEFREEN_WORKFLOWS_SOURCE_REPO
    # ("owner/name") for forks / private mirrors.
    def handle_workflows_refresh(client, request)
      body = parse_json(request) || {}
      ref  = (body["ref"] || "").to_s.strip
      ref  = WorkflowsRefresher::DEFAULT_REF if ref.empty?

      refresher = WorkflowsRefresher.new(
        workflows_dir: @workflows_dir,
        repo:          ENV["SIMPLEFREEN_WORKFLOWS_SOURCE_REPO"] ||
                       WorkflowsRefresher::DEFAULT_REPO,
        logger:        ->(msg) { @feature.log("workflows-refresh: #{msg}") }
      )
      result = refresher.refresh!(ref: ref)
      Http.write_json(client, 200, {
        "ok"         => true,
        "providers"  => result[:providers],
        "ref"        => result[:ref],
        "commit"     => result[:commit],
        "repo"       => result[:repo],
        "source"     => result[:source],
        "fetched_at" => result[:fetched_at]
      })
    rescue WorkflowsRefresher::Error => e
      Http.write_json(client, 502, { "error" => "workflows refresh failed", "details" => e.message })
    rescue StandardError => e
      @feature.log("workflows refresh crashed: #{e.class}: #{e.message}")
      Http.write_json(client, 500, { "error" => "internal server error" })
    end

    def handle_list(client)
      summaries = @feature.profile_store.list.map { |p| profile_summary(p) }
      Http.write_json(client, 200, { "profiles" => summaries })
    end

    def handle_create(client, request)
      body = parse_json(request) or return bad_request(client, "invalid JSON body")
      key      = body["profile_key"]
      workflow = body["workflow"]
      unless key.is_a?(String) && key =~ Paths::FILENAME_PATTERN
        return bad_request(client, "profile_key must match [A-Za-z0-9_.-]{1,128}")
      end
      unless workflow.is_a?(String) && !workflow.empty?
        return bad_request(client, "workflow is required")
      end
      unless File.file?(File.join(@workflows_dir, workflow))
        return bad_request(client, "workflow #{workflow.inspect} not found under workflows root")
      end

      create_args = {
        key: key,
        workflow: workflow,
        display_name: body["display_name"],
        lookback_days: body["lookback_days"] || 30,
        max_lookback_days: body["max_lookback_days"] || 365,
        sync_interval_seconds: body["sync_interval_seconds"],
        hidden_accounts: body["hidden_accounts"] || [],
        serve_max_days: body["serve_max_days"]
      }
      create_args[:lookback_mode]         = body["lookback_mode"]         if body.key?("lookback_mode")
      create_args[:lookback_overlap_days] = body["lookback_overlap_days"] if body.key?("lookback_overlap_days")
      profile = @feature.profile_store.create(**create_args)
      Http.write_json(client, 200, { "profile" => profile_summary(profile) })
    rescue ArgumentError => e
      bad_request(client, e.message)
    end

    def handle_profile(client, key, method, request)
      return not_found(client) unless key =~ Paths::FILENAME_PATTERN
      case method
      when "GET"
        profile = @feature.profile_store.read(key) or return not_found(client)
        Http.write_json(client, 200, { "profile" => profile_summary(profile) })
      when "PATCH"
        body = parse_json(request) or return bad_request(client, "invalid JSON body")
        return not_found(client) unless @feature.profile_store.exists?(key)
        updated = @feature.profile_store.update(key) do |current|
          current["display_name"] = body["display_name"] if body.key?("display_name")
          if body.key?("workflow")
            wf = body["workflow"]
            unless wf.is_a?(String) && !wf.empty? && File.file?(File.join(@workflows_dir, wf))
              raise ArgumentError, "workflow #{wf.inspect} not found"
            end
            current["workflow"] = wf
          end
          if body.key?("lookback_days")
            current["lookback_days"] = coerce_positive(body["lookback_days"], "lookback_days")
          end
          if body.key?("max_lookback_days")
            current["max_lookback_days"] = coerce_positive(body["max_lookback_days"], "max_lookback_days")
          end
          if body.key?("lookback_mode")
            mode = body["lookback_mode"].to_s
            unless ProfileStore::LOOKBACK_MODES.include?(mode)
              raise ArgumentError,
                "lookback_mode must be one of #{ProfileStore::LOOKBACK_MODES.inspect}"
            end
            current["lookback_mode"] = mode
          end
          if body.key?("lookback_overlap_days")
            current["lookback_overlap_days"] = coerce_positive(body["lookback_overlap_days"], "lookback_overlap_days")
          end
          if body.key?("sync_interval_seconds")
            raw = body["sync_interval_seconds"]
            current["sync_interval_seconds"] =
              (raw.nil? || raw == 0 || raw == "" || raw == "0") ? nil : coerce_interval(raw)
          end
          if body.key?("hidden_accounts")
            unless body["hidden_accounts"].is_a?(Array) && body["hidden_accounts"].all? { |v| v.is_a?(String) }
              raise ArgumentError, "hidden_accounts must be an array of strings"
            end
            current["hidden_accounts"] = body["hidden_accounts"].uniq
          end
          if body.key?("serve_max_days")
            raw = body["serve_max_days"]
            current["serve_max_days"] =
              (raw.nil? || raw == 0 || raw == "" || raw == "0") ? nil : coerce_positive(raw, "serve_max_days")
          end
          current
        end
        Http.write_json(client, 200, { "profile" => profile_summary(updated) })
      when "DELETE"
        return not_found(client) unless @feature.profile_store.exists?(key)
        @feature.profile_store.delete(key)
        @feature.cache_store.delete(key)
        Http.write_json(client, 200, { "deleted" => key })
      else
        method_not_allowed(client)
      end
    rescue ArgumentError => e
      bad_request(client, e.message)
    end

    def handle_credentials(client, key, method, request)
      return method_not_allowed(client) unless method == "POST"
      return not_found(client) unless @feature.profile_store.exists?(key)
      body = parse_json(request) or return bad_request(client, "invalid JSON body")
      secrets = body["secrets"]
      unless secrets.is_a?(Hash) && !secrets.empty?
        return bad_request(client, "secrets must be a non-empty object")
      end
      @feature.profile_store.write_credentials(key, secrets, master_key: @feature.master_key)
      Http.write_json(client, 200, { "ok" => true, "names" => secrets.keys.sort })
    rescue ArgumentError => e
      bad_request(client, e.message)
    end

    def handle_sync(client, key, method, request)
      return method_not_allowed(client) unless method == "POST"
      return not_found(client) unless @feature.profile_store.exists?(key)

      profile = @feature.profile_store.read(key)
      unless profile_has_credentials?(profile)
        return Http.write_json(client, 422, {
          "error" => "no credentials configured for #{key} — click \"Credentials\" and fill in the bank login fields before syncing."
        })
      end

      body = parse_json(request) || {}
      headed = body["headed"] == true

      # Optional per-sync lookback override. The UI's "Sync now" button
      # collects this so an operator can ask Unicaja for 180 days
      # without mutating the profile's standing default. Cap at the
      # profile's max_lookback_days so an accidental "1800" doesn't
      # smoke an upstream 1-year API window.
      lookback = nil
      if body.key?("lookback") && !body["lookback"].nil? && body["lookback"] != ""
        begin
          lookback = coerce_positive(body["lookback"], "lookback")
        rescue ArgumentError => e
          return bad_request(client, e.message)
        end
        ceiling = profile["max_lookback_days"] || 365
        if lookback > ceiling
          return bad_request(client, "lookback exceeds profile max_lookback_days (#{ceiling})")
        end
      end

      # Mint a per-run VNC password for every sync. Chrome is always
      # windowed (banks block headless), so noVNC is always usable —
      # the operator may want to watch any sync. The `headed` flag
      # only controls the UI's prominent re-auth styling; the
      # backend behavior is identical.
      vnc_password = random_vnc_password
      result = @feature.queue&.enqueue(
        key, headed: headed, trigger: "admin", vnc_password: vnc_password, lookback: lookback
      ) || :disabled

      payload = {
        "enqueued"     => result.to_s,
        "profile_key"  => key,
        "headed"       => headed,
        "lookback"     => lookback || profile["lookback_days"],
        "vnc_password" => vnc_password,
        "vnc_url"      => build_vnc_url(vnc_password)
      }
      Http.write_json(client, 200, payload)
    end

    # Bulk-enqueue every eligible source profile. The scheduler already
    # serializes outbound /invoke calls — this just stuffs the queue so
    # the operator can kick off a sweep without click-syncing each row.
    # Skips: virtual profiles, anything missing credentials, anything
    # without an access URL (no consumer to serve), and anything the
    # queue refuses (already active or already queued, idempotent by
    # design).
    def handle_sync_all(client)
      enqueued = []
      skipped  = []
      @feature.profile_store.list.each do |profile|
        key = profile["profile_key"]
        if profile["kind"] == "virtual"
          skipped << { "profile_key" => key, "reason" => "virtual" }
          next
        end
        unless profile_has_credentials?(profile)
          skipped << { "profile_key" => key, "reason" => "no_credentials" }
          next
        end
        unless profile.dig("access_url", "password_pw")
          skipped << { "profile_key" => key, "reason" => "no_access_url" }
          next
        end
        result = @feature.queue&.enqueue(
          key, headed: false, trigger: "admin-sync-all",
          vnc_password: random_vnc_password
        )
        case result
        when :enqueued        then enqueued << key
        when :already_active  then skipped << { "profile_key" => key, "reason" => "already_active" }
        when :already_queued  then skipped << { "profile_key" => key, "reason" => "already_queued" }
        else                       skipped << { "profile_key" => key, "reason" => result.to_s }
        end
      end
      Http.write_json(client, 200, {
        "enqueued" => enqueued,
        "skipped"  => skipped,
        "pending"  => @feature.queue&.pending_keys || [],
        "active"   => @feature.queue&.active_key
      })
    end

    # True iff at least one secret has been encrypted-and-stored for
    # this profile. Used as a precheck on sync/browse so the operator
    # gets a friendly "fill in Credentials first" message instead of
    # freentonic's raw `credentials.inline must be a non-empty object`
    # 422 leaking up the stack.
    def profile_has_credentials?(profile)
      envelopes = profile && profile["secrets_envelopes"]
      envelopes.is_a?(Hash) && !envelopes.empty?
    end

    # 8 alphanumeric chars. VNC's DES-based auth truncates at 8 chars, so
    # anything longer is wasted entropy; 8 chars of [A-Za-z0-9] is ~48 bits
    # of entropy, plenty for a throwaway per-invoke password.
    def random_vnc_password
      alphabet = (("A".."Z").to_a + ("a".."z").to_a + ("0".."9").to_a)
      Array.new(8) { alphabet.sample(random: SecureRandom) }.join
    end

    def build_vnc_url(password)
      return nil unless @feature.public_url
      # noVNC is reverse-proxied through the same TLS surface at
      # /novnc/ (see the Caddyfile). Same-origin so the inline iframe
      # in the active-job banner works under HTTPS — no mixed-content
      # blocking. The `path` URL parameter tells noVNC which path to
      # open the WebSocket on; we point it at our proxied
      # /novnc/websockify, which Caddy auto-upgrades to ws:// against
      # freentonic:6080 inside the Docker network.
      #
      # Use vnc.html (the full viewer) instead of vnc_lite.html so the
      # operator gets a hamburger menu with: scaling toggle, fullscreen,
      # clipboard sync, ctrl-alt-del, on-screen keyboard, and the
      # ability to switch between scale / clip / scroll modes at
      # runtime. vnc_lite is a fixed bare canvas with none of those.
      #
      # `resize=scale` scales the (now fixed-size) X display canvas to
      # fit the iframe with aspect-preserving letterbox. Pairs with the
      # freentonic-side guarantee that Chrome fills the X display:
      # Chrome maximized → desktop fully populated → scaled to iframe →
      # operator sees the bank UI clean, no clipping.
      # `autoconnect=true` (not `=1`): older noVNC honored `1`, newer
      # versions only auto-connect on the literal string `true` —
      # without this, opening the noVNC URL in a new tab lands on the
      # manual "Connect" landing instead of going straight to the bank
      # UI. The inline iframe with autoconnect=1 sometimes still works
      # by accident depending on parsing order, but `true` is the form
      # that survives every noVNC release.
      # `reconnect=true` retries a flapping WebSocket instead of
      # falling back to the manual Connect screen.
      #
      # All parameters go in the URL FRAGMENT, not the query string: a
      # fragment is never sent to a server, so the VNC password stays
      # out of edge-proxy access logs and Referer headers. noVNC reads
      # settings via WebUtil.getConfigVar, which checks the fragment
      # first and falls back to the query (verified for v1.5.0, the
      # version freentonic pins).
      "#{@feature.public_url}/novnc/vnc.html#path=novnc/websockify&password=#{URI.encode_www_form_component(password)}&autoconnect=true&reconnect=true&resize=scale&show_dot=1"
    end

    def handle_setup_token(client, key, method)
      return method_not_allowed(client) unless method == "POST"
      return not_found(client) unless @feature.profile_store.exists?(key)
      claim = @feature.claim_store.mint(key)
      url = "#{@feature.public_url}/simplefin/claim/#{claim["claim_id"]}"
      setup_token = Base64.strict_encode64(url)
      Http.write_json(client, 200, {
        "setup_token" => setup_token,
        "claim_url"   => url,
        "expires_at"  => claim["expires_at"]
      })
    end

    def handle_rotate(client, key, method)
      return method_not_allowed(client) unless method == "POST"
      return not_found(client) unless @feature.profile_store.exists?(key)
      @feature.profile_store.clear_access_url(key)
      Http.write_json(client, 200, {
        "ok" => true,
        "next_step" => "mint a new setup token and re-link in Actual"
      })
    end

    def handle_runs(client, key)
      return not_found(client) unless @feature.profile_store.exists?(key)
      runs = @feature.run_log.recent(key, limit: 20).map do |entry|
        run_id = entry["run_id"]
        artifacts = run_id ? list_run_artifacts(run_id) : []
        canonical = run_id ? read_canonical_meta(key, run_id) : nil
        merged = entry.merge("artifacts" => artifacts)
        merged["canonical"] = canonical if canonical
        # Flag runs that captured a recorder transcript so the UI can
        # surface a "Recording" button per row without polling the
        # recording proxy endpoint for every run on the list.
        merged["has_recording"] = true if run_id && run_has_recording?(run_id)
        merged
      end
      Http.write_json(client, 200, { "runs" => runs })
    end

    def run_has_recording?(run_id)
      run_dir = resolve_run_dir(run_id)
      return false unless run_dir
      File.file?(File.join(run_dir, "recording.jsonl"))
    end

    # Return the full canonical envelope freentonic pushed for this run.
    # The payload was persisted by PushReceiver alongside the run-log
    # entry; this handler is read-only and validates the run_id charset
    # before touching disk.
    def handle_run_canonical(client, profile_key, run_id)
      return not_found(client) unless @feature.profile_store.exists?(profile_key)
      return not_found(client) unless run_id =~ Paths::FILENAME_PATTERN
      path = Paths.run_canonical_path(profile_key, run_id, @feature.root)
      return not_found(client) unless File.file?(path)
      body = AtomicFile.read_json(path)
      return not_found(client) unless body
      Http.write_json(client, 200, body)
    end

    def read_canonical_meta(profile_key, run_id)
      return nil unless run_id =~ Paths::FILENAME_PATTERN
      path = Paths.run_canonical_meta_path(profile_key, run_id, @feature.root)
      AtomicFile.read_json(path)
    rescue StandardError
      nil
    end

    # Proxy to freentonic's own `/runs/<run_id>/log` endpoint. simplefreen
    # doesn't hold the raw Chrome log bytes — those stay on freentonic's
    # filesystem. We authenticate to freentonic with the same
    # FREENTONIC_INVOKE_TOKEN the scheduler uses, pull the log body,
    # return it (tail-trimmed at MAX_LOG_BYTES) as JSON for the admin UI.
    def handle_run_log(client, profile_key, run_id, params = {})
      return not_found(client) unless @feature.profile_store.exists?(profile_key)
      return not_found(client) unless run_id =~ Paths::FILENAME_PATTERN

      client_obj = @feature.freentonic_client
      return Http.write_json(client, 503, { "error" => "freentonic client not installed" }) unless client_obj

      # Incremental tail: `?offset=<byte>` streams only the bytes appended
      # since the last poll — the steady-state path for the live active-job
      # log. Without it we fall through to the full-suffix fetch below (used
      # by the finished-run log viewer and the very first live poll).
      if params.key?("offset")
        return handle_run_log_tail(client, run_id, client_obj, params["offset"])
      end

      begin
        body, size, truncated = client_obj.fetch_run_log(run_id, max_bytes: MAX_LOG_BYTES)
      rescue StandardError => e
        return Http.write_json(client, 502, {
          "error"   => "freentonic log fetch failed",
          "details" => "#{e.class}: #{e.message}"
        })
      end

      if body.nil?
        return Http.write_json(client, 404, { "error" => "log not found on freentonic" })
      end

      Http.write_json(client, 200, {
        "run_id"    => run_id,
        "truncated" => truncated,
        "size"      => size,
        "log"       => body
      })
    end

    # Incremental-tail branch of handle_run_log. `raw_offset` is the
    # `?offset=` query value: a byte position to stream from. Returns only
    # the bytes appended since then plus the next offset to poll with.
    def handle_run_log_tail(client, run_id, client_obj, raw_offset)
      unless raw_offset.to_s =~ /\A\d+\z/
        return Http.write_json(client, 400, { "error" => "offset must be a non-negative integer" })
      end

      begin
        data = client_obj.tail_run_log(run_id, offset: raw_offset.to_i, max_bytes: MAX_LOG_BYTES)
      rescue StandardError => e
        return Http.write_json(client, 502, {
          "error"   => "freentonic log fetch failed",
          "details" => "#{e.class}: #{e.message}"
        })
      end

      if data.nil?
        return Http.write_json(client, 404, { "error" => "log not found on freentonic" })
      end

      Http.write_json(client, 200, {
        "run_id" => run_id,
        "chunk"  => data[:chunk],
        "offset" => data[:next_offset],
        "size"   => data[:size]
      })
    end

    # List the interactive prompts a paused freentonic workflow is waiting
    # on (typically an SMS/OTP code, occasionally a "tap to approve"
    # confirmation after the operator interacts with a 3rd-party app).
    # Polled by the active-job banner every 2 s; rendered as a small form
    # inside the banner the moment a prompt appears.
    def handle_run_prompts(client, profile_key, run_id)
      return not_found(client) unless @feature.profile_store.exists?(profile_key)
      return not_found(client) unless run_id =~ Paths::FILENAME_PATTERN

      client_obj = @feature.freentonic_client
      return Http.write_json(client, 503, { "error" => "freentonic client not installed" }) unless client_obj

      begin
        prompts = client_obj.fetch_run_prompts(run_id)
      rescue FreentonicClient::ConnectionError => e
        return Http.write_json(client, 502, { "error" => "freentonic unreachable", "details" => e.message })
      rescue StandardError => e
        @feature.log("fetch_run_prompts failed for #{profile_key}/#{run_id}: #{e.class}: #{e.message}")
        return Http.write_json(client, 502, { "error" => "freentonic prompts fetch failed" })
      end

      # 404 from freentonic (run unknown) is not an error from our side —
      # the run may have just finished. Surface as an empty list so the
      # UI's poll loop quietly stops rendering the prompt card.
      Http.write_json(client, 200, { "run_id" => run_id, "prompts" => prompts || [] })
    end

    # Forward a prompt answer to freentonic. Body must be one of
    # `{ "kind": "input", "value": "<otp>" }`, `{ "kind": "confirm" }`, or
    # `{ "kind": "await" }` (the fallback button on a self-resolving wait).
    # We pass freentonic's status code through unchanged (200 / 400 /
    # 404 / 409 / 410) so the UI can branch on the same codes the runner
    # uses internally.
    def handle_run_prompt_submit(client, profile_key, run_id, prompt_id, request)
      return not_found(client) unless @feature.profile_store.exists?(profile_key)
      return not_found(client) unless run_id =~ Paths::FILENAME_PATTERN
      return not_found(client) unless prompt_id =~ Paths::FILENAME_PATTERN

      client_obj = @feature.freentonic_client
      return Http.write_json(client, 503, { "error" => "freentonic client not installed" }) unless client_obj

      body  = parse_json(request) || {}
      kind  = body["kind"]
      value = body["value"]
      unless ["input", "confirm", "await"].include?(kind)
        return bad_request(client, "kind must be \"input\", \"confirm\", or \"await\"")
      end
      if kind == "input" && !(value.is_a?(String) && !value.empty?)
        return bad_request(client, "value must be a non-empty string for input prompts")
      end

      begin
        result = client_obj.submit_prompt_answer(run_id, prompt_id, kind: kind, value: value)
      rescue FreentonicClient::ConnectionError => e
        return Http.write_json(client, 502, { "error" => "freentonic unreachable", "details" => e.message })
      rescue ArgumentError => e
        return bad_request(client, e.message)
      rescue StandardError => e
        @feature.log("submit_prompt_answer failed for #{profile_key}/#{run_id}/#{prompt_id}: #{e.class}: #{e.message}")
        return Http.write_json(client, 502, { "error" => "freentonic prompt submit failed" })
      end

      if result[:ok]
        Http.write_json(client, 200, { "ok" => true, "run_id" => run_id, "prompt_id" => prompt_id })
      else
        # Map freentonic's contract to a stable JSON shape; the UI keys
        # off `error` and `status` to surface inline messages.
        reason = case result[:status]
                 when 404 then "prompt not found"
                 when 409 then "prompt already answered"
                 when 410 then "prompt expired"
                 when 400 then "invalid prompt answer"
                 else "freentonic rejected the answer"
                 end
        Http.write_json(client, result[:status], { "error" => reason })
      end
    end

    # Browse mode: enqueue a freentonic invoke that runs only the
    # workflow's `connect` phase (URL navigation), then idles until
    # the operator clicks "Stop browsing" (which POSTs the cancel
    # endpoint below). Lets the operator interact with the bank
    # manually via VNC — typical use cases are warming a fresh
    # Chrome profile after `clear-session`, or solving a bank-
    # initiated 2FA / "verify it's you" prompt.
    def handle_browse(client, key, request = nil)
      return not_found(client) unless @feature.profile_store.exists?(key)

      # Browse mode runs only the workflow's `connect` phase (URL
      # navigation), so the operator's bank credentials aren't strictly
      # needed — Chrome opens at the login page and the user types
      # their password manually. But freentonic's /invoke schema
      # requires credentials.inline to be a non-empty Hash, so until
      # that gets relaxed upstream we still need at least one secret
      # configured. Surface a clear message rather than freentonic's
      # raw 422.
      profile = @feature.profile_store.read(key)
      unless profile_has_credentials?(profile)
        return Http.write_json(client, 422, {
          "error" => "no credentials configured for #{key} — click \"Credentials\" and save at least one field before browsing. (Browse runs only the navigation step; the values you enter aren't used to log in automatically.)"
        })
      end

      vnc_password = random_vnc_password
      result = @feature.queue&.enqueue(
        key,
        headed:       true,
        trigger:      "browse",
        vnc_password: vnc_password,
        interactive:  true
      ) || :disabled
      Http.write_json(client, 200, {
        "enqueued"     => result.to_s,
        "profile_key"  => key,
        "interactive"  => true,
        "vnc_password" => vnc_password,
        "vnc_url"      => build_vnc_url(vnc_password)
      })
    end

    # Recording mode: like Browse but freentonic launches CDP Chrome
    # and injects a probe script that captures the operator's clicks /
    # fills / submits / navigations to <run_dir>/recording.jsonl. The
    # operator stops the session via /admin/api/runs/<run_id>/cancel
    # (same as Stop browsing); the captured events are then served via
    # /admin/api/profiles/<key>/runs/<run_id>/recording for the UI to
    # render as a step-by-step transcript.
    def handle_record(client, key)
      return not_found(client) unless @feature.profile_store.exists?(key)

      profile = @feature.profile_store.read(key)
      unless profile_has_credentials?(profile)
        return Http.write_json(client, 422, {
          "error" => "no credentials configured for #{key} — click \"Credentials\" and save at least one field before recording. (Recording navigates the workflow's initial URL; the values you enter aren't used to log in automatically.)"
        })
      end

      vnc_password = random_vnc_password
      result = @feature.queue&.enqueue(
        key,
        headed:       true,
        trigger:      "record",
        vnc_password: vnc_password,
        # Recording is its own freentonic mode (CDP path + probe). Do
        # NOT also set interactive — they're mutually exclusive on the
        # freentonic side and recording wins.
        interactive:  false,
        recording:    true
      ) || :disabled
      Http.write_json(client, 200, {
        "enqueued"     => result.to_s,
        "profile_key"  => key,
        "recording"    => true,
        "vnc_password" => vnc_password,
        "vnc_url"      => build_vnc_url(vnc_password)
      })
    end

    # Proxy freentonic's /runs/<run_id>/recording. Returns the raw
    # JSONL body verbatim plus a parsed `events` array so the UI
    # doesn't have to split-and-parse on the client. 404 if the run
    # produced no recording (run wasn't in recording mode, or it ended
    # before any events were captured).
    def handle_run_recording(client, profile_key, run_id)
      return not_found(client) unless @feature.profile_store.exists?(profile_key)
      return not_found(client) unless run_id =~ Paths::FILENAME_PATTERN

      client_obj = @feature.freentonic_client
      return Http.write_json(client, 503, { "error" => "freentonic client not installed" }) unless client_obj

      begin
        body = client_obj.fetch_run_recording(run_id)
      rescue FreentonicClient::ConnectionError => e
        return Http.write_json(client, 502, { "error" => "freentonic unreachable", "details" => e.message })
      rescue StandardError => e
        @feature.log("fetch_run_recording failed for #{profile_key}/#{run_id}: #{e.class}: #{e.message}")
        return Http.write_json(client, 502, { "error" => "freentonic recording fetch failed" })
      end

      return Http.write_json(client, 404, { "error" => "no recording for run_id" }) if body.nil?

      events = body.each_line.filter_map do |line|
        line = line.strip
        next if line.empty?
        begin
          JSON.parse(line)
        rescue JSON::ParserError
          # malformed line — skip; the JSONL itself is still served raw
          nil
        end
      end
      Http.write_json(client, 200, {
        "run_id" => run_id,
        "events" => events,
        "size"   => body.bytesize
      })
    end

    # Cancel an in-flight freentonic run by id. Used by the "Stop
    # browsing" button in the admin UI to end an interactive session
    # cleanly (freentonic SIGTERMs the child, Chrome closes
    # gracefully, profile state is preserved).
    def handle_cancel_run(client, run_id)
      return not_found(client) unless run_id =~ Paths::FILENAME_PATTERN
      client_obj = @feature.freentonic_client
      return Http.write_json(client, 503, { "error" => "freentonic client not installed" }) unless client_obj
      begin
        result = client_obj.cancel(run_id)
      rescue FreentonicClient::ConnectionError => e
        return Http.write_json(client, 502, { "error" => "freentonic unreachable", "details" => e.message })
      rescue StandardError => e
        @feature.log("cancel_run failed for #{run_id}: #{e.class}: #{e.message}")
        return Http.write_json(client, 500, { "error" => "internal server error" })
      end
      Http.write_json(client, 200, { "ok" => true, "run_id" => run_id, "freentonic" => result })
    end

    # Wipe freentonic's per-profile Chrome user-data so the next sync
    # starts from a clean profile (no cookies, no device-trust). Useful
    # before a manual VNC warm-up: anti-bot heuristics often trigger on
    # the first run of a stale fingerprint, and a fresh-then-headed
    # walkthrough usually establishes a "good" fingerprint that
    # subsequent headless syncs can ride on.
    # POST /admin/api/profiles/:key/history/rebuild
    # Drop the on-disk history and replay every immutable per-run
    # canonical to reconstruct it. Used after a corruption or to seed
    # history from runs that pre-date the HistoryStore.
    def handle_history_rebuild(client, key)
      return not_found(client) unless @feature.profile_store.exists?(key)
      result = @feature.history_store.rebuild_from_runs!(key)
      if result.nil?
        return Http.write_json(client, 422, {
          "ok"    => false,
          "error" => "no canonical runs on disk to rebuild from"
        })
      end
      Http.write_json(client, 200, {
        "ok"           => true,
        "profile_key"  => key,
        "txn_count"    => Array(result["transactions"]).size,
        "last_run_id"  => result["last_run_id"],
        "stats"        => @feature.history_store.stats(key)
      })
    rescue StandardError => e
      @feature.log("history rebuild failed for #{key}: #{e.class}: #{e.message}")
      Http.write_json(client, 500, { "error" => "internal server error" })
    end

    # DELETE /admin/api/profiles/:key/history
    # Wipe the durable history. The next sync will see no last_tx_date
    # and cold-start to max_lookback_days. Per-run canonicals on disk
    # are untouched (use /history/rebuild to recover from them).
    def handle_history_reset(client, key)
      return not_found(client) unless @feature.profile_store.exists?(key)
      existed = @feature.history_store.exists?(key)
      @feature.history_store.delete!(key)
      Http.write_json(client, 200, {
        "ok"          => true,
        "profile_key" => key,
        "existed"     => existed
      })
    rescue StandardError => e
      @feature.log("history reset failed for #{key}: #{e.class}: #{e.message}")
      Http.write_json(client, 500, { "error" => "internal server error" })
    end

    def handle_clear_session(client, key)
      return not_found(client) unless @feature.profile_store.exists?(key)
      client_obj = @feature.freentonic_client
      return Http.write_json(client, 503, { "error" => "freentonic client not installed" }) unless client_obj

      begin
        result = client_obj.prune_profile(key)
      rescue FreentonicClient::ConnectionError => e
        return Http.write_json(client, 502, { "error" => "freentonic unreachable", "details" => e.message })
      rescue FreentonicClient::HttpError => e
        return Http.write_json(client, e.status, { "error" => "freentonic prune failed", "details" => e.body.to_s.slice(0, 300) })
      rescue StandardError => e
        @feature.log("clear_session failed for #{key}: #{e.class}: #{e.message}")
        return Http.write_json(client, 500, { "error" => "internal server error" })
      end

      Http.write_json(client, 200, { "ok" => true, "profile_key" => key, "deleted" => result["deleted"] || [] })
    end

    # ── consolidation ───────────────────────────────────────
    #
    # Read-only inspector over linked accounts across all profiles. A
    # group represents one physical bank account observed by one or
    # more sources (direct provider + aggregator). Groups form via:
    #   - automatic links: identical acc_<hex> across profiles (the
    #     freentonic-side portable_ref makes this happen for accounts
    #     with portable identifiers like Spanish IBANs);
    #   - manual aliases: operator-supplied entries for accounts whose
    #     upstream cannot expose enough info to derive a portable_ref
    #     (e.g. Fintonic accounts with opaque resourceId hashes).
    #
    # The inspector does NOT yet alter the SimpleFIN serve path — it
    # surfaces what would be merged so the operator can review and
    # add aliases before the merged-serve flag is enabled.
    def handle_consolidation_groups(client)
      canonicals  = Consolidation.load_canonicals(@feature)
      aliases     = @feature.consolidation_store.list
      groups      = Consolidation.build_groups(canonicals, aliases: aliases)
      suggestions = Consolidation.suggest_matches(canonicals, groups)
      Http.write_json(client, 200, {
        "groups"        => groups.map { |g| serialize_group(g) },
        "suggestions"   => suggestions.map { |s| serialize_suggestion(s) },
        "alias_count"   => aliases.size,
        "profile_count" => canonicals.size,
        "generated_at"  => Time.now.utc.iso8601
      })
    end

    def handle_consolidation_aliases_list(client)
      Http.write_json(client, 200, { "aliases" => @feature.consolidation_store.list })
    end

    # Replace the alias list wholesale. Body shape:
    #   { "aliases": [ { "members": ["acc_aaaa…", "acc_bbbb…"], "note": "…" } ] }
    # Validation lives in ConsolidationStore#replace; ArgumentError
    # surfaces as 422 with the underlying message so the UI can show it.
    def handle_consolidation_aliases_replace(client, request)
      body = parse_json(request)
      return Http.write_json(client, 400, { "error" => "body must be a JSON object" }) unless body.is_a?(Hash)
      begin
        written = @feature.consolidation_store.replace(body["aliases"] || [])
      rescue ArgumentError => e
        return Http.write_json(client, 422, { "error" => e.message })
      end
      Http.write_json(client, 200, { "aliases" => written })
    end

    def serialize_group(group)
      {
        "id"                => group.id,
        "linked_via"        => group.linked_via.to_s,
        "members"           => group.members,
        "suggested_primary" => group.suggested_primary && {
          "profile_key" => group.suggested_primary.profile_key,
          "account_id"  => group.suggested_primary.account["id"]
        },
        "sources"           => group.sources.map { |s| serialize_source(s) }
      }
    end

    def serialize_source(source)
      a = source.account
      {
        "profile_key"  => source.profile_key,
        "account_id"   => a["id"],
        "name"         => a["name"],
        "institution"  => a["institution"],
        "iban"         => a["iban"],
        "currency"     => a["currency"],
        "source_id"    => a["source_id"],
        "txn_count"    => source.txn_count,
        "balance"      => a.dig("balance", "current")
      }
    end

    def serialize_suggestion(s)
      {
        "profile_a"   => s.profile_a,
        "account_a"   => serialize_suggestion_account(s.account_a),
        "profile_b"   => s.profile_b,
        "account_b"   => serialize_suggestion_account(s.account_b),
        "overlap"     => s.overlap,
        "a_total"     => s.a_total,
        "b_total"     => s.b_total,
        "confidence"  => s.confidence,
        "samples"     => s.samples
      }
    end

    # Create the singleton virtual profile (key: "consolidated") if it
    # doesn't exist yet. Idempotent: returns the existing profile if
    # already created. The operator then mints a setup token via the
    # standard /setup-token endpoint and pastes it into Sure.am / Actual.
    def handle_consolidation_virtual_profile_create(client)
      key = ProfileStore::VIRTUAL_PROFILE_KEY
      existing = @feature.profile_store.read(key)
      if existing
        return Http.write_json(client, 200, { "profile" => profile_summary(existing), "created" => false })
      end
      profile = @feature.profile_store.create(
        key:          key,
        workflow:     nil,
        kind:         "virtual",
        display_name: "Consolidated",
        lookback_days:     365,
        max_lookback_days: 3650
      )
      Http.write_json(client, 200, { "profile" => profile_summary(profile), "created" => true })
    rescue ArgumentError => e
      bad_request(client, e.message)
    end

    # GET full per-group config plus the same group/suggestion data the
    # Linked-accounts panel renders, so the editor UI gets one round-trip
    # per refresh. Warnings are computed from the live canonicals.
    def handle_consolidation_groups_config_list(client)
      Http.write_json(client, 200, build_groups_config_payload)
    end

    # PUT one group config entry. Body shape: a single config object.
    # Use this for both create (no existing entry) and update.
    def handle_consolidation_groups_config_upsert(client, request)
      body = parse_json(request)
      return Http.write_json(client, 400, { "error" => "body must be a JSON object" }) unless body.is_a?(Hash)
      begin
        written = @feature.consolidation_groups_store.upsert(body)
      rescue ArgumentError => e
        return Http.write_json(client, 422, { "error" => e.message })
      end
      Http.write_json(client, 200, { "config" => written, **build_groups_config_payload })
    end

    # Preview what the virtual /accounts endpoint would emit right
    # now. Same code path as the real serve, minus auth and CORS.
    # Returns the merged envelope plus warnings so the operator can
    # eyeball changes before the consolidated URL is hit by Actual.
    def handle_consolidation_preview(client)
      canonicals = Consolidation.load_canonicals(@feature)
      aliases    = @feature.consolidation_store.list
      configs    = @feature.consolidation_groups_store.list
      result     = ConsolidatedReshape.call(
        canonicals_by_profile: canonicals,
        aliases:               aliases,
        group_configs:         configs
      )
      Http.write_json(client, 200, {
        "envelope" => result.envelope,
        "warnings" => result.warnings.map { |w| serialize_warning(w) }
      })
    end

    # Operator-facing summary of what the virtual /accounts endpoint
    # will actually emit to downstream apps (Sure.am, Actual). Differs
    # from /preview by collapsing the heavy SimpleFIN envelope down to
    # a per-account summary plus visibility into:
    #   - hidden_accounts being respected at the source level (a hide
    #     in one source profile suppresses that account from the
    #     consolidated stream — see Protocol#filter_source_hidden)
    #   - cross-profile lookalike pairs (singletons with overlapping
    #     transaction signatures that the operator should consider
    #     aliasing so they collapse into one merged account).
    def handle_consolidation_export_preview(client)
      # Load raw canonicals (un-filtered) so we can compute the
      # hidden_suppressions section using account names from the original
      # envelope. We then apply the filter ourselves before handing them
      # to ConsolidatedReshape, mirroring what load_canonicals does by
      # default for every other caller.
      raw_canonicals  = Consolidation.load_canonicals(@feature, apply_source_hidden: false)
      profile_records = source_profile_records
      hidden_lists    = profile_records.transform_values { |p| Array(p["hidden_accounts"]) }

      # Build hidden_suppressions BEFORE filtering — the un-filtered
      # canonical is the only place we can look up the hidden account's
      # display name to show the operator what was suppressed.
      suppressions = hidden_lists.flat_map do |pk, hidden|
        next [] if hidden.empty?
        canonical = raw_canonicals[pk]
        next [] unless canonical.is_a?(Hash)
        accs_by_id = Array(canonical["accounts"]).each_with_object({}) { |a, h| h[a["id"]] = a if a.is_a?(Hash) }
        hidden.map do |acc_id|
          a = accs_by_id[acc_id] || {}
          {
            "profile_key" => pk,
            "account_id"  => acc_id,
            "name"        => a["name"],
            "institution" => a["institution"]
          }
        end
      end

      filtered_canonicals = raw_canonicals.each_with_object({}) do |(pk, canonical), out|
        out[pk] = Consolidation.filter_canonical_hidden(canonical, hidden_lists[pk] || [])
      end

      virtual_key   = ProfileStore::VIRTUAL_PROFILE_KEY
      virtual       = @feature.profile_store.read(virtual_key)
      virtual_hide  = Array(virtual && virtual["hidden_accounts"])

      aliases       = @feature.consolidation_store.list
      group_configs = @feature.consolidation_groups_store.list

      groups = Consolidation.build_groups(filtered_canonicals, aliases: aliases)
      result = ConsolidatedReshape.call(
        canonicals_by_profile: filtered_canonicals,
        aliases:               aliases,
        group_configs:         group_configs,
        profile_records:       profile_records
      )
      envelope_accounts = Array(result.envelope["accounts"]).reject { |a| virtual_hide.include?(a["id"]) }

      group_by_member = groups.each_with_object({}) do |g, h|
        g.members.each { |m| h[m] = g }
      end
      configs_by_key = group_configs.each_with_object({}) do |c, h|
        members = Array(c["members"]).map(&:to_s).sort
        h[members] = c
      end

      accounts_payload = envelope_accounts.map do |acc|
        group = group_by_member[acc["id"]]
        sources_payload =
          if group
            config  = configs_by_key[group.members.sort]
            windows = ConsolidatedReshape.send(:resolve_windows, group, config)
            pairs   = ConsolidatedReshape.send(:collect_filtered, group, filtered_canonicals, windows)
            counts  = pairs.each_with_object(Hash.new(0)) { |(pk, _), h| h[pk] += 1 }
            group.sources.map do |s|
              pk  = s.profile_key.to_s
              win = windows[pk] || {}
              {
                "profile_key" => pk,
                "txn_count"   => counts[pk] || 0,
                "from"        => win["from"],
                "to"          => win["to"],
                "skipped"     => win["default_empty"] ? true : false
              }
            end
          else
            []
          end

        {
          "id"              => acc["id"],
          "name"            => acc["name"],
          "currency"        => acc["currency"],
          "linked_via"      => group&.linked_via.to_s,
          "primary_source"  => acc.dig("extra", "consolidated_primary_source"),
          "member_count"    => group&.members&.size || 0,
          "txn_count_total" => Array(acc["transactions"]).size,
          "sources"         => sources_payload
        }
      end

      lookalikes = Consolidation.suggest_matches(filtered_canonicals, groups).map { |s| serialize_suggestion(s) }

      Http.write_json(client, 200, {
        "virtual_key"          => virtual_key,
        "accounts"             => accounts_payload,
        "hidden_suppressions"  => suppressions,
        "lookalike_pairs"      => lookalikes,
        "warnings"             => result.warnings.map { |w| serialize_warning(w) }
      })
    end

    def source_profile_records
      out = {}
      @feature.profile_store.list.each do |p|
        next if p["kind"] == "virtual"
        out[p["profile_key"]] = p
      end
      out
    end

    def build_groups_config_payload
      canonicals = Consolidation.load_canonicals(@feature)
      aliases    = @feature.consolidation_store.list
      configs    = @feature.consolidation_groups_store.list
      groups     = Consolidation.build_groups(canonicals, aliases: aliases)
      result     = ConsolidatedReshape.call(
        canonicals_by_profile: canonicals,
        aliases:               aliases,
        group_configs:         configs
      )

      virtual_profile = @feature.profile_store.read(ProfileStore::VIRTUAL_PROFILE_KEY)
      {
        "virtual_profile" => virtual_profile && profile_summary(virtual_profile),
        "configs"         => configs,
        "groups"          => groups.map { |g|
          serialize_group(g).merge(
            "config"     => configs.find { |c|
              Array(c["members"]).map(&:to_s).sort == g.members.sort
            },
            "earliest_dates" => g.sources.each_with_object({}) { |s, h|
              h[s.profile_key.to_s] = ConsolidatedReshape.send(:earliest_tx_date, canonicals, s.profile_key.to_s, g.sources)
            }
          )
        },
        "warnings"        => result.warnings.map { |w| serialize_warning(w) }
      }
    end

    def serialize_warning(w)
      { "kind" => w.kind.to_s, "members" => w.group_members, "message" => w.message }
    end

    # POST a candidate {members, primary, windows} payload and get back
    # the merge stats that *would* result if you saved it. Doesn't
    # touch the store. Used by the "Preview" button next to the
    # editor's Save so the operator can sanity-check window choices
    # before persisting.
    def handle_consolidation_group_preview(client, request)
      body = parse_json(request)
      return Http.write_json(client, 400, { "error" => "body must be a JSON object" }) unless body.is_a?(Hash)

      canonicals = Consolidation.load_canonicals(@feature)
      aliases    = @feature.consolidation_store.list
      preview    = ConsolidatedReshape.preview_group(
        canonicals_by_profile: canonicals,
        aliases:               aliases,
        members:               body["members"] || [],
        primary_pk:            body["primary"],
        windows:               body["windows"] || {}
      )
      if preview.nil?
        return Http.write_json(client, 404, { "error" => "no group with those members" })
      end

      Http.write_json(client, 200, {
        "primary_pk"           => preview.primary_pk,
        "sources"              => preview.sources,
        "bucket_stats"         => preview.bucket_stats,
        "estimated_emit_count" => preview.estimated_emit_count,
        "sample_collisions"    => preview.sample_collisions,
        "warnings"             => preview.warnings
      })
    end

    def serialize_suggestion_account(a)
      {
        "id"          => a["id"],
        "name"        => a["name"],
        "institution" => a["institution"],
        "iban"        => a["iban"],
        "source_id"   => a["source_id"],
        "currency"    => a["currency"]
      }
    end

    # On-demand freentonic health probe. Same call the background
    # monitor makes every SIMPLEFREEN_FREENTONIC_HEALTH_INTERVAL_SECONDS;
    # the admin can invoke it manually so the dead window after a
    # `docker compose restart freentonic` is closed to ~zero instead
    # of waiting for the next cadence tick.
    def handle_freentonic_health_probe(client)
      health = @feature.freentonic_health
      return Http.write_json(client, 503, { "error" => "freentonic_health not installed" }) unless health
      health.probe_once
      Http.write_json(client, 200, health.snapshot)
    end

    # List the on-disk artifacts (screenshots, logs, exports) freentonic
    # produced for a given run. Read-only, classified by extension. The
    # full path is never returned — clients address files by index.
    def handle_run_artifacts(client, profile_key, run_id)
      return not_found(client) unless @feature.profile_store.exists?(profile_key)
      return not_found(client) unless run_id =~ Paths::FILENAME_PATTERN
      Http.write_json(client, 200, { "artifacts" => list_run_artifacts(run_id) })
    end

    # Serve a single artifact by index (the same index returned by
    # #list_run_artifacts). All path joins flow through realpath escape
    # checks so a malicious symlink in the run dir cannot leak files
    # outside the artifacts root.
    def handle_run_artifact(client, profile_key, run_id, idx)
      return not_found(client) unless @feature.profile_store.exists?(profile_key)
      return not_found(client) unless run_id =~ Paths::FILENAME_PATTERN

      entries = list_run_artifacts(run_id)
      entry = entries[idx]
      return not_found(client) unless entry

      path = resolve_run_artifact_path(run_id, entry["name"])
      return not_found(client) unless path && File.file?(path)

      Http.write_binary(client, 200, content_type_for(path), File.binread(path))
    rescue StandardError => e
      @feature.log("serve_run_artifact failed for #{profile_key}/#{run_id}/#{idx}: #{e.class}: #{e.message}")
      Http.write_json(client, 500, { "error" => "internal server error" })
    end

    # ── helpers ─────────────────────────────────────────────

    def profile_summary(profile)
      state = @feature.state_store.read(profile["profile_key"])
      {
        "profile_key"           => profile["profile_key"],
        "kind"                  => profile["kind"] || "source",
        "display_name"          => profile["display_name"],
        "workflow"              => profile["workflow"],
        "lookback_days"         => profile["lookback_days"],
        "max_lookback_days"     => profile["max_lookback_days"],
        "lookback_mode"         => profile["lookback_mode"] || "incremental",
        "lookback_overlap_days" => profile["lookback_overlap_days"] || 10,
        "sync_interval_seconds" => profile["sync_interval_seconds"],
        "hidden_accounts"       => profile["hidden_accounts"] || [],
        "serve_max_days"        => profile["serve_max_days"],
        "created_at"            => profile["created_at"],
        "updated_at"            => profile["updated_at"],
        "credential_names"      => (profile["secrets_envelopes"] || {}).keys.sort,
        "access_url_configured" => !(profile.dig("access_url", "password_pw").nil?),
        "state"                 => state["state"],
        "last_error"            => state["last_error"],
        "last_run_id"           => state["last_run_id"],
        "last_synced_at"        => state["last_synced_at"],
        "last_run"              => last_run_summary(profile["profile_key"]),
        "history"               => @feature.history_store.stats(profile["profile_key"])
      }
    end

    # Compact summary of the most recent run (regardless of outcome) so
    # the manage-list row can show "last run: ready · 2h ago (12s)"
    # without each consumer N+1-ing /runs. Returns nil when there are
    # no runs on disk yet (fresh profile).
    def last_run_summary(profile_key)
      entry = @feature.run_log.recent(profile_key, limit: 1).first
      return nil unless entry
      {
        "run_id"      => entry["run_id"],
        "started_at"  => entry["started_at"],
        "finished_at" => entry["finished_at"],
        "duration_ms" => entry["duration_ms"],
        "outcome"     => entry["outcome"],
        "exit_code"   => entry["exit_code"],
        "message"     => entry["message"],
        "trigger"     => entry["trigger"]
      }
    end

    # ── run artifacts ───────────────────────────────────────

    # Map of file extensions to artifact "kind" labels surfaced in the
    # API. Anything unmatched is dropped from the listing entirely
    # (don't surface arbitrary files freentonic might leave behind).
    RUN_ARTIFACT_KINDS = {
      ".png"  => "screenshot",
      ".jpg"  => "screenshot",
      ".jpeg" => "screenshot",
      ".log"  => "log",
      ".txt"  => "log",
      ".json" => "export",
      ".jsonl"=> "export",
      ".csv"  => "export",
      ".html" => "report"
    }.freeze

    RUN_ARTIFACT_CONTENT_TYPES = {
      ".png"  => "image/png",
      ".jpg"  => "image/jpeg",
      ".jpeg" => "image/jpeg",
      ".log"  => "text/plain; charset=utf-8",
      ".txt"  => "text/plain; charset=utf-8",
      ".json" => "application/json",
      ".jsonl"=> "application/x-ndjson",
      ".csv"  => "text/csv; charset=utf-8",
      ".html" => "text/html; charset=utf-8"
    }.freeze

    # List the artifacts freentonic wrote for the given run, sorted by
    # mtime ascending so screenshots appear in capture order. Returns
    # `[]` when the artifacts dir is unconfigured or the per-run dir
    # doesn't exist (e.g. failed before any output was written).
    def list_run_artifacts(run_id)
      run_dir = resolve_run_dir(run_id)
      return [] unless run_dir
      entries = Dir.children(run_dir).select do |name|
        ext = File.extname(name).downcase
        RUN_ARTIFACT_KINDS.key?(ext) && File.file?(File.join(run_dir, name))
      end
      entries.sort_by! { |n| File.mtime(File.join(run_dir, n)).to_f rescue 0.0 }
      entries.map.with_index do |name, i|
        full = File.join(run_dir, name)
        ext  = File.extname(name).downcase
        {
          "index" => i,
          "name"  => name,
          "kind"  => RUN_ARTIFACT_KINDS.fetch(ext, "other"),
          "size"  => (File.size(full) rescue 0),
          "mtime" => (File.mtime(full).utc.iso8601 rescue nil)
        }
      end
    end

    # Resolve the per-run directory under the artifacts root, with a
    # realpath escape check so symlinks can't reach outside. Returns
    # nil for any failure mode (unconfigured, missing, escapes).
    def resolve_run_dir(run_id)
      return nil unless run_id =~ Paths::FILENAME_PATTERN
      base = @feature.runs_artifacts_dir
      return nil if base.nil? || base.empty?
      return nil unless Dir.exist?(base)
      base_real = File.realpath(base) rescue (return nil)
      candidate = File.join(base_real, run_id)
      return nil unless Dir.exist?(candidate)
      run_real = File.realpath(candidate) rescue (return nil)
      return nil unless run_real == File.join(base_real, run_id) ||
                        run_real.start_with?(File.join(base_real, run_id) + "/")
      run_real
    end

    # Resolve a single artifact path, re-checking realpath against the
    # per-run dir so a symlink inside the run dir cannot escape.
    def resolve_run_artifact_path(run_id, name)
      run_dir = resolve_run_dir(run_id)
      return nil unless run_dir
      return nil unless name.is_a?(String) && !name.empty?
      candidate = File.join(run_dir, name)
      real = File.realpath(candidate) rescue (return nil)
      return nil unless real.start_with?(run_dir + "/")
      real
    end

    def content_type_for(path)
      RUN_ARTIFACT_CONTENT_TYPES.fetch(File.extname(path).downcase, "application/octet-stream")
    end

    # Convention: each provider lives in a directory named after its
    # slug (e.g. `ing/`, `revolut/`) and ships a `workflow.yml`. Other
    # YAMLs in the same directory (`config.yml`, fixtures, etc.) are
    # not user-selectable; only `<slug>/workflow.yml` is.
    def list_workflows
      return [] unless @workflows_dir && Dir.exist?(@workflows_dir)
      Dir.glob(File.join(@workflows_dir, "*", "workflow.yml"))
        .map { |p| p.sub(@workflows_dir.chomp("/") + "/", "") }
        .sort
    end

    # Declared secrets for a workflow, used by the admin UI to render
    # credential-entry form fields. Reads the workflow YAML's top-level
    # `secrets:` hash directly — same canonical list freentonic's own
    # runtime asks for. YAML.safe_load with no permitted_classes and no
    # aliases, matching freentonic's invariant 1 on safe parsing.
    def declared_secrets(workflow_rel)
      full = File.join(@workflows_dir, workflow_rel)
      return [] unless File.file?(full)
      doc = YAML.safe_load(File.read(full), permitted_classes: [], aliases: false) || {}
      secrets = doc["secrets"]
      return [] unless secrets.is_a?(Hash)
      secrets.keys.map(&:to_s)
    rescue StandardError => e
      @feature.log("declared_secrets failed for #{workflow_rel}: #{e.class}: #{e.message}")
      []
    end

    def parse_json(request)
      body = request.body
      return nil if body.nil?
      # The HTTP server hands us the raw request bytes tagged BINARY.
      # JSON.parse propagates that encoding into every parsed String;
      # JSON 3.0 then warns/raises if those strings are passed back
      # through JSON.generate (e.g. when persisted to disk). Re-tag as
      # UTF-8 — the application/json wire encoding is UTF-8 by spec.
      JSON.parse(body.dup.force_encoding(Encoding::UTF_8))
    rescue ::JSON::ParserError, TypeError
      nil
    end

    def coerce_positive(value, name)
      int = Integer(value)
      raise ArgumentError, "#{name} must be positive" unless int.positive?
      int
    end

    def coerce_interval(value)
      int = Integer(value)
      raise ArgumentError, "sync_interval_seconds must be >= 300 (5 min)" if int < 300
      int
    end

    def unauthorized(client)
      Http.write_json(client, 401, { "error" => "missing or invalid bearer token" })
    end

    def not_found(client)
      Http.write_json(client, 404, { "error" => "not found" })
    end

    def bad_request(client, msg)
      Http.write_json(client, 400, { "error" => msg })
    end

    def method_not_allowed(client)
      Http.write_json(client, 405, { "error" => "method not allowed" })
    end
  end
end
