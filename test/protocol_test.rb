# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "net/http"
require "json"
require "base64"
require "socket"

require "simplefreen"

module Simplefreen
  # End-to-end protocol tests. Spins up the real Simplefreen::Server and
  # router, but stubs the scheduler with a recorder so we never call
  # freentonic.
  class ProtocolTest < Minitest::Test
    # Stand-in for the real Scheduler. Records every enqueue call and
    # exposes the list for assertions. Matches the #enqueue /
    # #pending_keys / #active_key / #active_job surface the router +
    # admin_api expect.
    class RecordingQueue
      attr_reader :enqueued
      def initialize; @enqueued = []; end
      def enqueue(key, headed: false, trigger: "auto", vnc_password: nil, interactive: false, lookback: nil, recording: false)
        @enqueued << [key, headed, trigger, vnc_password, interactive, lookback, recording]; :enqueued
      end
      def pending_keys; @enqueued.map(&:first); end
      def active_key; nil; end
      def active_job; nil; end
      def worker_alive?; true; end
    end

    def setup
      @root          = Dir.mktmpdir("simplefreen-proto-")
      @workflows_dir = Dir.mktmpdir("simplefreen-wf-")
      @artifacts_dir = Dir.mktmpdir("simplefreen-art-")
      # Create a minimal fake workflow so create-profile validation passes.
      @workflow_name = "acme/workflow.yml"
      FileUtils.mkdir_p(File.join(@workflows_dir, "acme"))
      File.write(File.join(@workflows_dir, @workflow_name), <<~YAML)
        version: 1
        config:
          key: acme
        secrets:
          USER_DNI:
            prompt: "Acme user DNI"
          USER_PIN:
            prompt: "Acme user PIN"
        phases:
          connect: []
        pipeline: []
      YAML

      @master_key_b64 = Crypto.generate_master_key_b64
      ENV["SIMPLEFREEN_SECRETS_KEY"]    = @master_key_b64
      ENV["SIMPLEFREEN_ADMIN_PASSWORD"] = "admin-pw"
      ENV["SIMPLEFREEN_PUBLIC_URL"]     = "http://freentonic.example"
      ENV["SIMPLEFREEN_ROOT"]           = @root
      ENV["FREENTONIC_URL"]             = "http://fake-freentonic:7878"
      ENV["FREENTONIC_INVOKE_TOKEN"]    = "fake-invoke-token"
      ENV["SIMPLEFREEN_RUNS_ARTIFACTS_DIR"] = @artifacts_dir

      @feature = Feature.from_env
      @feature.recover_on_boot!
      @queue = RecordingQueue.new
      @feature.install_scheduler(@queue)
      @feature.install_push_tokens(PushTokens.new)

      ui_dir = File.expand_path("../lib/simplefreen/ui", __dir__)
      @router = Router.new(feature: @feature,
                           workflows_dir: @workflows_dir,
                           asset_dir: ui_dir)

      @port   = find_free_port
      @server = Server.new(
        router:      @router,
        listen_addr: "127.0.0.1",
        listen_port: @port,
        logger:      nil
      )
      @thread = Thread.new { @server.start }
      wait_for_server_up
    end

    def teardown
      @server&.shutdown
      @thread&.join(3)
      FileUtils.rm_rf(@root)
      FileUtils.rm_rf(@workflows_dir)
      FileUtils.rm_rf(@artifacts_dir)
      %w[SIMPLEFREEN_SECRETS_KEY SIMPLEFREEN_ADMIN_PASSWORD SIMPLEFREEN_PUBLIC_URL
         SIMPLEFREEN_ROOT FREENTONIC_URL FREENTONIC_INVOKE_TOKEN
         SIMPLEFREEN_RUNS_ARTIFACTS_DIR].each { |k| ENV.delete(k) }
    end

    # ── helpers ────────────────────────────────────────────

    def find_free_port
      s = TCPServer.new("127.0.0.1", 0); port = s.addr[1]; s.close; port
    end

    def wait_for_server_up(timeout: 5)
      deadline = Time.now + timeout
      while Time.now < deadline
        begin
          TCPSocket.new("127.0.0.1", @port).close
          return
        rescue StandardError
          sleep 0.02
        end
      end
      raise "server did not come up"
    end

    def req(method, path, body: nil, headers: {})
      uri = URI("http://127.0.0.1:#{@port}#{path}")
      klass = { "GET" => Net::HTTP::Get, "POST" => Net::HTTP::Post,
                "PATCH" => Net::HTTP::Patch, "DELETE" => Net::HTTP::Delete }[method]
      r = klass.new(uri.request_uri)
      headers.each { |k, v| r[k] = v }
      if body
        r["Content-Type"] = "application/json" unless r["Content-Type"]
        r.body = body.is_a?(String) ? body : JSON.generate(body)
      end
      Net::HTTP.start(uri.host, uri.port) { |h| h.request(r) }
    end

    def admin(headers = {})
      { "Authorization" => "Bearer admin-pw" }.merge(headers)
    end

    # ── Admin API: profile lifecycle ────────────────────────

    def test_admin_create_profile
      res = req("POST", "/admin/api/profiles", body: {
        profile_key: "acme",
        workflow:    @workflow_name,
        display_name: "Acme"
      }, headers: admin)
      assert_equal "200", res.code
      body = JSON.parse(res.body)
      assert_equal "acme", body["profile"]["profile_key"]
    end

    def test_admin_api_requires_bearer
      res = req("GET", "/admin/api/profiles")
      assert_equal "401", res.code
    end

    def test_admin_workflows_lists_declared_secrets
      res = req("GET", "/admin/api/workflows", headers: admin)
      assert_equal "200", res.code
      body = JSON.parse(res.body)
      wf = body["workflows"].find { |w| w["workflow"] == @workflow_name }
      assert wf
      assert_equal %w[USER_DNI USER_PIN], wf["secrets"]
    end

    def test_admin_credentials_encrypted_on_disk
      req("POST", "/admin/api/profiles", body: { profile_key: "acme", workflow: @workflow_name }, headers: admin)
      req("POST", "/admin/api/profiles/acme/credentials",
          body: { secrets: { "USER_DNI" => "12345", "USER_PIN" => "9999" } },
          headers: admin)
      raw = File.read(Paths.profile_path("acme", @root))
      refute_includes raw, "12345"
      refute_includes raw, "9999"
    end

    # ── Protocol: claim + access URL + accounts ─────────────

    def test_admin_sync_headed_returns_one_shot_vnc_password
      provision_profile_with_credentials("acme")
      res = req("POST", "/admin/api/profiles/acme/sync",
                body: { headed: true }, headers: admin)
      assert_equal "200", res.code
      body = JSON.parse(res.body)
      assert_equal true, body["headed"]
      assert_match(/\A[A-Za-z0-9]{8}\z/, body["vnc_password"])
      # The password rides in the fragment, which browsers never send to
      # a server, so it can't land in proxy access logs or Referer.
      before_fragment, fragment = body["vnc_url"].split("#", 2)
      refute_includes before_fragment, body["vnc_password"]
      assert_includes fragment, "password=#{body["vnc_password"]}"
    end

    def test_admin_sync_returns_vnc_password_and_url_for_every_run
      # Every sync gets a VNC password — Chrome is always windowed
      # and the operator may want to watch any sync. The `headed`
      # flag only controls UX styling, not whether VNC is enabled.
      provision_profile_with_credentials("acme")

      res = req("POST", "/admin/api/profiles/acme/sync",
                body: { headed: false }, headers: admin)
      body = JSON.parse(res.body)
      assert_match(/\A[A-Za-z0-9]{8}\z/, body["vnc_password"])
      assert_match(%r{/novnc/vnc\.html#path=novnc/websockify}, body["vnc_url"])
    end

    def test_admin_sync_without_credentials_rejected_with_clear_message
      # Profile created with no credentials — sync should 422 with a
      # human-actionable message, not the raw freentonic error.
      req("POST", "/admin/api/profiles",
          body: { profile_key: "acme", workflow: @workflow_name }, headers: admin)
      res = req("POST", "/admin/api/profiles/acme/sync",
                body: { headed: false }, headers: admin)
      assert_equal "422", res.code
      assert_match(/no credentials configured/, JSON.parse(res.body)["error"])
    end

    def test_setup_token_can_be_claimed_once
      req("POST", "/admin/api/profiles", body: { profile_key: "acme", workflow: @workflow_name }, headers: admin)
      res = req("POST", "/admin/api/profiles/acme/setup-token", headers: admin)
      token = JSON.parse(res.body)["setup_token"]
      claim_url = Base64.strict_decode64(token)
      path = URI(claim_url).path

      first = req("POST", path)
      assert_equal "200", first.code
      assert_match(%r{http://[^@]+@freentonic.example/simplefin/acme\z}, first.body)

      # Second attempt is rejected.
      second = req("POST", path)
      assert_equal "403", second.code
    end

    def test_accounts_enqueues_when_idle_and_returns_empty_notice
      provision_profile_with_access_url("acme")

      url, user, password = current_access_url("acme")
      res = req("GET", url, headers: basic_auth(user, password))

      assert_equal "200", res.code
      body = JSON.parse(res.body)
      assert_equal [], body["accounts"]
      assert_match(/scheduled/i, body["errors"].first)
      assert_equal ["acme"], @queue.enqueued.map(&:first)
    end

    def test_accounts_rejects_bad_password
      provision_profile_with_access_url("acme")
      url, user, _ = current_access_url("acme")
      res = req("GET", url, headers: basic_auth(user, "wrong"))
      # SimpleFIN spec: auth failure is 403, not the conventional 401 —
      # so clients (Actual's sync-server in particular) can branch on
      # it to trigger their reconnect flow.
      assert_equal "403", res.code
    end

    def test_accounts_reshapes_from_history
      # HistoryStore is the source of truth: when a history entry has
      # been merged for the profile, /accounts must reshape from it at
      # read time (so reshape changes apply without a fresh sync) and
      # ignore any older prebuilt cache_store entry.
      provision_profile_with_access_url("acme")

      # Stale legacy cache (would-be served if history fallback fired).
      stale = {
        "accounts" => [{
          "id" => "stale", "name" => "Stale", "currency" => "EUR",
          "balance" => "0.00", "balance-date" => 0,
          "org" => { "name" => "Stale", "domain" => "stale.local", "id" => "stale" },
          "transactions" => []
        }],
        "errors" => []
      }
      @feature.cache_store.write("acme", stale)

      # Fresh run merged into HistoryStore.
      payload = {
        "schema_version" => "0.1",
        "summary" => {}, "meta" => {},
        "accounts" => [
          { "id" => "acc_aaaaaaaaaaaaaaaa", "institution" => "ing",
            "name" => "Fresh", "currency" => "EUR",
            "balance" => { "current" => "42.42",
                           "timestamp" => "2026-04-27T10:00:00Z" } }
        ],
        "transactions" => []
      }
      @feature.history_store.merge_run!("acme",
        run_id: "simplefreen-acme-canon", payload: payload)
      @feature.state_store.force_state("acme", "ready")

      url, user, password = current_access_url("acme")
      res = req("GET", url, headers: basic_auth(user, password))
      body = JSON.parse(res.body)

      assert_equal 1, body["accounts"].size
      assert_equal "acc_aaaaaaaaaaaaaaaa", body["accounts"].first["id"], "must serve history, not stale cache"
      assert_equal "42.42", body["accounts"].first["balance"]
    end

    def test_accounts_serves_full_history_after_incremental_run
      # Regression: a short-lookback incremental run must not shrink the
      # served view to just its window. HistoryStore accumulates every
      # run's txns; /accounts must reshape from that union, not from
      # whichever canonical happens to be newest on disk.
      provision_profile_with_access_url("acme")

      acct = { "id" => "acc_aaaaaaaaaaaaaaaa", "institution" => "ing",
               "name" => "Acme", "currency" => "EUR",
               "balance" => { "current" => "100.00",
                              "timestamp" => "2026-05-14T00:00:00Z" } }

      # First run: large full-pull payload — 50 txns.
      full = {
        "schema_version" => "0.1", "summary" => {}, "meta" => {},
        "accounts" => [acct],
        "transactions" => (1..50).map { |i|
          { "id"          => "txn_full_%04d" % i,
            "source_id"   => "v2-seq:acme:#{i}",
            "account_id"  => "acc_aaaaaaaaaaaaaaaa",
            "date"        => "2026-03-#{format('%02d', (i % 28) + 1)}",
            "amount"      => "-1.00",
            "currency"    => "EUR",
            "description" => "Full pull tx #{i}",
            "status"      => "posted" }
        }
      }
      @feature.history_store.merge_run!("acme",
        run_id: "simplefreen-acme-full", payload: full)

      # Second run: a short incremental — just 3 new txns. Persist its
      # canonical so RunLog#latest_canonical (newest mtime) points at it,
      # mimicking a real post-incremental on-disk state.
      incr_run = "simplefreen-acme-incr"
      incr = {
        "schema_version" => "0.1", "summary" => {}, "meta" => {},
        "accounts" => [acct],
        "transactions" => (1..3).map { |i|
          { "id"          => "txn_incr_%04d" % i,
            "source_id"   => "v2-seq:acme:#{500 + i}",
            "account_id"  => "acc_aaaaaaaaaaaaaaaa",
            "date"        => "2026-05-1#{i}",
            "amount"      => "-2.00",
            "currency"    => "EUR",
            "description" => "Incremental tx #{i}",
            "status"      => "posted" }
        }
      }
      AtomicFile.write_json(Paths.run_canonical_path("acme", incr_run, @root), incr)
      @feature.history_store.merge_run!("acme", run_id: incr_run, payload: incr)
      @feature.state_store.force_state("acme", "ready")

      url, user, password = current_access_url("acme")
      res = req("GET", url, headers: basic_auth(user, password))
      body = JSON.parse(res.body)

      acc = body["accounts"].find { |a| a["id"] == "acc_aaaaaaaaaaaaaaaa" }
      refute_nil acc, "account must be present in serve payload"
      assert_equal 53, acc["transactions"].size,
        "must serve full union (50 full + 3 incremental), not just the latest canonical's 3"
    end

    def test_accounts_serves_cache_without_consuming_it
      # SimpleFIN clients (Actual sync-server, reference CLI) poll the
      # endpoint repeatedly and expect the most recent cached envelope
      # to keep being returned until a fresh scrape replaces it.
      provision_profile_with_access_url("acme")
      envelope = {
        "accounts" => [{
          "id" => "x", "name" => "Acme", "currency" => "EUR",
          "balance" => "10.00", "balance-date" => Time.now.to_i,
          "org" => { "name" => "Acme", "domain" => "acme.local", "id" => "acme" },
          "transactions" => []
        }],
        "errors" => []
      }
      @feature.cache_store.write("acme", envelope)
      @feature.state_store.force_state("acme", "ready")

      url, user, password = current_access_url("acme")

      # Three back-to-back polls must all return the same payload.
      3.times do
        res = req("GET", url, headers: basic_auth(user, password))
        body = JSON.parse(res.body)
        assert_equal 1, body["accounts"].size, "cache must survive repeated reads"
        assert_equal "x", body["accounts"].first["id"]
      end

      # State stays `ready` — it represents the last sync outcome, not
      # cache availability. Cache file is still on disk.
      assert_equal "ready", @feature.state_store.read("acme")["state"]
      assert @feature.cache_store.exists?("acme")
    end

    def test_accounts_error_state_with_cache_serves_stale_data_and_retries
      provision_profile_with_access_url("acme")
      envelope = {
        "accounts" => [{
          "id" => "y", "name" => "Acme", "currency" => "EUR",
          "balance" => "99.00", "balance-date" => Time.now.to_i - 3600,
          "org" => { "name" => "Acme", "domain" => "acme.local", "id" => "acme" },
          "transactions" => []
        }],
        "errors" => []
      }
      @feature.cache_store.write("acme", envelope)
      @feature.state_store.force_state("acme", "error", "last_error" => "exit 1")

      url, user, password = current_access_url("acme")
      res = req("GET", url, headers: basic_auth(user, password))
      body = JSON.parse(res.body)
      assert_equal 1, body["accounts"].size, "stale cache must be served when last sync failed"
      assert_match(/Background refresh failed/i, body["errors"].first)
      # Retry was scheduled.
      assert_includes @queue.enqueued.map(&:first), "acme"
    end

    def test_accounts_rate_limits_auto_enqueue
      provision_profile_with_access_url("acme")
      url, user, password = current_access_url("acme")
      headers = basic_auth(user, password)

      3.times { req("GET", url, headers: headers) }
      assert_equal 1, @queue.enqueued.size,
        "repeated GET /accounts within the rate-limit window must enqueue only once"
    end

    def test_accounts_needs_reauth_does_not_enqueue
      provision_profile_with_access_url("acme")
      @feature.state_store.force_state("acme", "needs_reauth", "last_error" => "session expired")

      url, user, password = current_access_url("acme")
      res = req("GET", url, headers: basic_auth(user, password))
      body = JSON.parse(res.body)
      assert_match(/re-authentication required/i, body["errors"].first)
      assert_empty @queue.enqueued
    end

    # ── Run log proxy ──────────────────────────────────────

    # Admin UI's log panel hits /admin/api/profiles/:k/runs/:id/log which
    # now proxies to freentonic. Swap in a fake client that serves canned
    # bytes and confirm the handler relays them through.
    class FakeFreentonicClient
      def initialize(responses = {}); @responses = responses; end
      def fetch_run_log(run_id, max_bytes: nil)
        data = @responses[run_id]
        return nil unless data
        [data, data.bytesize, false]
      end
      def healthz(*); { "ok" => true }; end
    end

    def test_admin_api_serves_run_log
      req("POST", "/admin/api/profiles", body: { profile_key: "acme", workflow: @workflow_name }, headers: admin)
      @feature.run_log.record("acme", run_id: "run_1", outcome: "ready",
                              exit_code: 0, message: "ok")
      @feature.install_freentonic_client(
        FakeFreentonicClient.new("run_1" => "hello from the invoke child\n")
      )

      res = req("GET", "/admin/api/profiles/acme/runs/run_1/log", headers: admin)
      assert_equal "200", res.code
      body = JSON.parse(res.body)
      assert_equal "run_1", body["run_id"]
      assert_equal "hello from the invoke child\n", body["log"]
    end

    def test_admin_api_run_log_rejects_bad_run_id
      req("POST", "/admin/api/profiles", body: { profile_key: "acme", workflow: @workflow_name }, headers: admin)
      res = req("GET", "/admin/api/profiles/acme/runs/..%2Fescape/log", headers: admin)
      assert_equal "404", res.code
    end

    def test_admin_api_run_log_404_when_missing
      req("POST", "/admin/api/profiles", body: { profile_key: "acme", workflow: @workflow_name }, headers: admin)
      @feature.install_freentonic_client(FakeFreentonicClient.new)  # returns nil for every run_id
      res = req("GET", "/admin/api/profiles/acme/runs/never/log", headers: admin)
      assert_equal "404", res.code
    end

    # ── Admin UI: login cookie drives the API ───────────────

    def test_admin_login_sets_session_cookie
      res = req("POST", "/admin/login", body: "password=admin-pw",
                headers: { "Content-Type" => "application/x-www-form-urlencoded" })
      assert_equal "303", res.code
      assert_match(/freentonic_simplefin_session=/, res["set-cookie"])
    end

    def test_admin_api_accepts_valid_session_cookie
      login = req("POST", "/admin/login", body: "password=admin-pw",
                  headers: { "Content-Type" => "application/x-www-form-urlencoded" })
      cookie = login["set-cookie"].split(";").first
      res = req("GET", "/admin/api/profiles", headers: { "Cookie" => cookie })
      assert_equal "200", res.code
    end

    def test_session_cookie_is_secure_and_httponly
      login = req("POST", "/admin/login", body: "password=admin-pw",
                  headers: { "Content-Type" => "application/x-www-form-urlencoded" })
      set_cookie = login["set-cookie"]
      assert_match(/;\s*Secure/i, set_cookie)
      assert_match(/;\s*HttpOnly/i, set_cookie)
      assert_match(/;\s*SameSite=Strict/i, set_cookie)
    end

    def login_cookie
      login = req("POST", "/admin/login", body: "password=admin-pw",
                  headers: { "Content-Type" => "application/x-www-form-urlencoded" })
      login["set-cookie"].split(";").first
    end

    def test_cookie_mutation_without_origin_is_refused
      # CSRF: a cookie-authenticated mutation with no matching Origin/Referer
      # is refused (S-M3). Real Bearer clients stay exempt.
      cookie = login_cookie
      res = req("POST", "/admin/api/sync-all", headers: { "Cookie" => cookie })
      assert_equal "403", res.code
    end

    def test_cookie_mutation_with_foreign_origin_is_refused
      cookie = login_cookie
      res = req("POST", "/admin/api/sync-all",
                headers: { "Cookie" => cookie, "Origin" => "https://evil.example.com" })
      assert_equal "403", res.code
    end

    def test_cookie_mutation_with_matching_origin_is_allowed
      cookie = login_cookie
      res = req("POST", "/admin/api/sync-all",
                headers: { "Cookie" => cookie, "Origin" => "http://freentonic.example" })
      assert_equal "200", res.code
    end

    def test_cookie_mutation_from_cors_allowed_origin_is_refused
      # CORS origins may read /simplefin/*; they must not pass the admin
      # CSRF gate with the operator's session cookie.
      @feature.define_singleton_method(:cors_allowed_origins) { ["https://actual.example.com"] }
      cookie = login_cookie
      res = req("POST", "/admin/api/sync-all",
                headers: { "Cookie" => cookie, "Origin" => "https://actual.example.com" })
      assert_equal "403", res.code
    end

    def test_cookie_get_without_origin_still_allowed
      # GETs are not mutations — the CSRF gate must not touch them.
      cookie = login_cookie
      res = req("GET", "/admin/api/status", headers: { "Cookie" => cookie })
      assert_equal "200", res.code
    end

    def test_bearer_mutation_without_origin_still_allowed
      # Bearer auth is not CSRF-able, so it bypasses the Origin gate.
      res = req("POST", "/admin/api/sync-all", headers: admin)
      assert_equal "200", res.code
    end

    def test_login_locks_out_after_repeated_failures
      # S-M1: after LOGIN_MAX_FAILURES bad attempts the endpoint returns 429.
      last = nil
      12.times do
        last = req("POST", "/admin/login", body: "password=wrong",
                   headers: { "Content-Type" => "application/x-www-form-urlencoded" })
      end
      assert_equal "429", last.code
    end

    # ── Metrics + scheduling + hidden accounts ──────────────

    def test_metrics_endpoint_aggregates
      provision_profile_with_access_url("acme")
      @feature.state_store.force_state("acme", "ready",
        "last_synced_at" => Time.now.utc.iso8601, "last_error" => nil)

      res = req("GET", "/admin/api/metrics", headers: admin)
      assert_equal "200", res.code
      body = JSON.parse(res.body)
      assert_equal 1, body["profiles_total"]
      assert_equal 1, body["profiles_by_state"]["ready"]
      assert body["last_sync_age_seconds"]["min"].is_a?(Integer)
    end

    def test_sync_all_enqueues_only_profiles_with_creds_and_access_url
      # `ready_for_sync` has both credentials and a claimed access URL —
      # should be enqueued.
      provision_profile_for_sync_all("ready_for_sync")
      # `no_creds_yet` was created but never had credentials saved —
      # should be skipped with reason no_credentials.
      req("POST", "/admin/api/profiles",
          body: { profile_key: "no_creds_yet", workflow: @workflow_name }, headers: admin)
      # `no_access_url` has credentials but no claimed access URL —
      # should be skipped with reason no_access_url.
      provision_profile_with_credentials("no_access_url")

      res = req("POST", "/admin/api/sync-all", headers: admin)
      assert_equal "200", res.code
      body = JSON.parse(res.body)

      assert_equal ["ready_for_sync"], body["enqueued"]
      skipped = body["skipped"].each_with_object({}) { |s, h| h[s["profile_key"]] = s["reason"] }
      assert_equal "no_credentials", skipped["no_creds_yet"]
      assert_equal "no_access_url",  skipped["no_access_url"]
      assert_includes @queue.enqueued.map(&:first), "ready_for_sync"
    end

    def test_sync_all_uses_admin_sync_all_trigger
      provision_profile_for_sync_all("ready_for_sync")
      req("POST", "/admin/api/sync-all", headers: admin)
      job = @queue.enqueued.find { |j| j.first == "ready_for_sync" }
      # [key, headed, trigger, vnc_password, interactive, lookback, recording]
      assert_equal "admin-sync-all", job[2]
    end

    def test_sync_all_requires_bearer
      res = req("POST", "/admin/api/sync-all")
      assert_equal "401", res.code
    end

    def test_patch_sets_sync_interval
      req("POST", "/admin/api/profiles", body: { profile_key: "acme", workflow: @workflow_name }, headers: admin)
      res = req("PATCH", "/admin/api/profiles/acme",
        body: { sync_interval_seconds: 3600 }, headers: admin)
      assert_equal "200", res.code
      body = JSON.parse(res.body)
      assert_equal 3600, body["profile"]["sync_interval_seconds"]
    end

    def test_patch_rejects_too_small_interval
      req("POST", "/admin/api/profiles", body: { profile_key: "acme", workflow: @workflow_name }, headers: admin)
      res = req("PATCH", "/admin/api/profiles/acme",
        body: { sync_interval_seconds: 60 }, headers: admin)
      assert_equal "400", res.code
    end

    def test_export_preview_returns_well_shaped_empty_response_when_no_data
      res = req("GET", "/admin/api/consolidation/export-preview", headers: admin)
      assert_equal "200", res.code
      body = JSON.parse(res.body)
      # Even with no profiles configured the contract is stable: every
      # section is present so the UI can render its skeleton without
      # null-checking each key.
      assert_equal "consolidated", body["virtual_key"]
      assert_equal [], body["accounts"]
      assert_equal [], body["hidden_suppressions"]
      assert_equal [], body["lookalike_pairs"]
      assert_equal [], body["warnings"]
    end

    def test_export_preview_lists_hidden_suppressions_for_source_profiles
      provision_profile_with_access_url("acme")
      req("PATCH", "/admin/api/profiles/acme",
        body: { hidden_accounts: ["acc_hidden"] }, headers: admin)

      payload = {
        "schema_version" => "0.1", "summary" => {}, "meta" => {},
        "accounts" => [
          { "id" => "acc_visible", "institution" => "acme",
            "name" => "Visible", "currency" => "EUR",
            "balance" => { "current" => "10.00", "timestamp" => "2026-04-27T10:00:00Z" } },
          { "id" => "acc_hidden", "institution" => "acme",
            "name" => "Hidden Card", "currency" => "EUR",
            "balance" => { "current" => "5.00", "timestamp" => "2026-04-27T10:00:00Z" } }
        ],
        "transactions" => [
          { "id" => "txn_v", "account_id" => "acc_visible", "amount" => "-1.00",
            "currency" => "EUR", "date" => "2026-04-27", "description" => "X" },
          { "id" => "txn_h", "account_id" => "acc_hidden", "amount" => "-2.00",
            "currency" => "EUR", "date" => "2026-04-27", "description" => "Y" }
        ]
      }
      @feature.history_store.merge_run!("acme",
        run_id: "simplefreen-acme-canon", payload: payload)

      res = req("GET", "/admin/api/consolidation/export-preview", headers: admin)
      assert_equal "200", res.code
      body = JSON.parse(res.body)
      account_ids = body["accounts"].map { |a| a["id"] }
      refute_includes account_ids, "acc_hidden", "hidden source-account must not appear in export preview"
      assert_includes account_ids, "acc_visible"
      assert_equal 1, body["hidden_suppressions"].size
      sup = body["hidden_suppressions"].first
      assert_equal "acme",       sup["profile_key"]
      assert_equal "acc_hidden", sup["account_id"]
      assert_equal "Hidden Card", sup["name"]
    end

    def test_filter_source_hidden_drops_hidden_accounts_and_their_transactions
      # Source-level hidden_accounts must take effect BEFORE the virtual
      # envelope is built, otherwise a hidden singleton account leaks into
      # the consolidated /accounts response. We exercise the helper used by
      # handle_virtual_accounts directly so the assertion is tight.
      protocol = Protocol.new(feature: @feature)
      canonical = {
        "accounts" => [
          { "id" => "acc_keep", "currency" => "EUR" },
          { "id" => "acc_hide", "currency" => "EUR" }
        ],
        "transactions" => [
          { "id" => "txn_a", "account_id" => "acc_keep", "amount" => "1.00" },
          { "id" => "txn_b", "account_id" => "acc_hide", "amount" => "2.00" }
        ]
      }
      filtered = protocol.send(:filter_source_hidden, canonical, ["acc_hide"])
      assert_equal ["acc_keep"], filtered["accounts"].map { |a| a["id"] }
      assert_equal ["txn_a"],    filtered["transactions"].map { |t| t["id"] }

      # Empty hidden list returns the canonical untouched (same object,
      # no needless allocation).
      assert_same canonical, protocol.send(:filter_source_hidden, canonical, [])
    end

    def test_hidden_accounts_are_filtered_from_served_payload
      provision_profile_with_access_url("acme")
      req("PATCH", "/admin/api/profiles/acme",
        body: { hidden_accounts: ["b2"] }, headers: admin)

      envelope = {
        "accounts" => [
          { "id" => "a1", "currency" => "EUR", "balance" => "1.00",
            "balance-date" => Time.now.to_i, "transactions" => [] },
          { "id" => "b2", "currency" => "EUR", "balance" => "2.00",
            "balance-date" => Time.now.to_i, "transactions" => [] }
        ],
        "errors" => []
      }
      @feature.cache_store.write("acme", envelope)
      @feature.state_store.force_state("acme", "ready")

      url, user, password = current_access_url("acme")
      res = req("GET", url, headers: basic_auth(user, password))
      body = JSON.parse(res.body)
      assert_equal ["a1"], body["accounts"].map { |a| a["id"] }
    end

    def test_scheduler_tick_enqueues_due_profiles
      provision_profile_with_access_url("acme")
      # 300s minimum interval is too slow to test against a single tick, so
      # patch the profile on disk directly to a tiny interval. The protocol
      # layer's own coerce_interval floor protects the admin path.
      @feature.profile_store.update("acme") do |p|
        p["sync_interval_seconds"] = 1
        p
      end
      @feature.state_store.force_state("acme", "idle",
        "last_synced_at" => (Time.now - 60).utc.iso8601)

      @feature.auto_sync_tick
      assert_includes @queue.enqueued.map(&:first), "acme"
    end

    def test_scheduler_tick_skips_running_and_needs_reauth
      provision_profile_with_access_url("acme")
      @feature.profile_store.update("acme") do |p|
        p["sync_interval_seconds"] = 1
        p
      end

      %w[running queued needs_reauth].each do |state|
        @queue.enqueued.clear
        @feature.state_store.force_state("acme", state,
          "last_synced_at" => (Time.now - 3600).utc.iso8601)
        @feature.auto_sync_tick
        assert_empty @queue.enqueued, "must not enqueue from state=#{state}"
      end
    end

    def test_admin_login_rejects_wrong_password
      res = req("POST", "/admin/login", body: "password=wrong",
                headers: { "Content-Type" => "application/x-www-form-urlencoded" })
      # Redirect back to the login page with the error flag set — the
      # static login.html surfaces "Incorrect password" when ?e=1 is in
      # the query string. POST-redirect-GET avoids form resubmission
      # warnings if the operator refreshes after a failed attempt.
      assert_equal "303", res.code
      assert_match(%r{/admin/login\?e=1}, res["location"].to_s)
    end

    # ── Run artifacts ───────────────────────────────────────

    # Tiny but valid 1×1 PNG, hex-encoded. Used as a stand-in for the
    # screenshots freentonic would write to the runs dir.
    PNG_1x1 = [
      "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489" \
      "0000000d49444154789c63f80f00000100010047fb50f80000000049454e44ae42" \
      "6082"
    ].pack("H*").freeze

    def with_run_artifacts(profile_key, run_id)
      req("POST", "/admin/api/profiles", body: { profile_key: profile_key, workflow: @workflow_name }, headers: admin)
      # Persist the run record so handle_runs has something to enumerate.
      @feature.run_log.record(profile_key, {
        run_id: run_id, profile_key: profile_key, exit_code: 1,
        outcome: "error", error_kind: "user_error",
        started_at: Time.now.utc.iso8601
      })
      run_dir = File.join(@artifacts_dir, run_id)
      FileUtils.mkdir_p(run_dir)
      yield run_dir
    end

    def test_run_artifacts_listing_classifies_by_extension
      with_run_artifacts("acme", "run-classify-1") do |dir|
        File.binwrite(File.join(dir, "shot-01.png"), PNG_1x1)
        File.write(File.join(dir, "scrape.log"), "hello\n")
        File.write(File.join(dir, "ignored.exe"), "binary garbage")

        res = req("GET", "/admin/api/profiles/acme/runs/run-classify-1/artifacts", headers: admin)
        assert_equal "200", res.code
        names = JSON.parse(res.body)["artifacts"].map { |a| [a["name"], a["kind"]] }
        assert_includes names, ["shot-01.png", "screenshot"]
        assert_includes names, ["scrape.log",  "log"]
        # Unknown extensions are dropped — don't surface arbitrary files.
        refute(names.any? { |n, _| n == "ignored.exe" })
      end
    end

    def test_run_artifacts_inline_listing_in_runs_response
      with_run_artifacts("acme", "run-inline-1") do |dir|
        File.binwrite(File.join(dir, "shot.png"), PNG_1x1)
        res = req("GET", "/admin/api/profiles/acme/runs", headers: admin)
        assert_equal "200", res.code
        runs = JSON.parse(res.body)["runs"]
        run = runs.find { |r| r["run_id"] == "run-inline-1" }
        assert run, "expected run in /runs response"
        assert_equal 1, run["artifacts"].length
        assert_equal "screenshot", run["artifacts"].first["kind"]
      end
    end

    def test_run_artifact_serves_image_with_correct_content_type
      with_run_artifacts("acme", "run-serve-1") do |dir|
        File.binwrite(File.join(dir, "shot.png"), PNG_1x1)
        res = req("GET", "/admin/api/profiles/acme/runs/run-serve-1/artifacts/0", headers: admin)
        assert_equal "200", res.code
        assert_equal "image/png", res["content-type"]
        assert_equal PNG_1x1.bytesize.to_s, res["content-length"]
        assert_equal PNG_1x1, res.body.b
      end
    end

    def test_run_artifact_bad_index_returns_404
      with_run_artifacts("acme", "run-badidx-1") do |dir|
        File.binwrite(File.join(dir, "shot.png"), PNG_1x1)
        res = req("GET", "/admin/api/profiles/acme/runs/run-badidx-1/artifacts/99", headers: admin)
        assert_equal "404", res.code
      end
    end

    def test_run_artifact_symlink_escape_is_blocked
      # Drop a symlink in the run dir that points OUTSIDE the artifacts
      # root (a /etc/passwd-style escape attempt). The server must
      # refuse to serve it via realpath escape check.
      secret_root = Dir.mktmpdir("simplefreen-secret-")
      secret_file = File.join(secret_root, "secret.png")
      File.binwrite(secret_file, "do not leak")
      with_run_artifacts("acme", "run-escape-1") do |dir|
        File.symlink(secret_file, File.join(dir, "escape.png"))
        res = req("GET", "/admin/api/profiles/acme/runs/run-escape-1/artifacts/0", headers: admin)
        # Either 404 (resolve_run_artifact_path returned nil) or no 200
        # serving the secret bytes — both are acceptable; the load-bearing
        # check is that secret bytes never appear in a 2xx response body.
        refute_equal "200", res.code, "symlink escape unexpectedly served"
        refute_includes res.body.to_s, "do not leak"
      end
    ensure
      FileUtils.rm_rf(secret_root) if secret_root
    end

    def test_clear_session_calls_freentonic_prune
      req("POST", "/admin/api/profiles", body: { profile_key: "acme", workflow: @workflow_name }, headers: admin)

      # Stub freentonic_client.prune_profile so the admin endpoint can
      # exercise its full happy path without a live freentonic.
      called = []
      class << @feature.freentonic_client
        # singleton override only on this instance
      end
      @feature.freentonic_client.define_singleton_method(:prune_profile) do |key|
        called << key
        { "deleted" => [key], "count" => 1 }
      end

      res = req("POST", "/admin/api/profiles/acme/clear-session", headers: admin)
      assert_equal "200", res.code
      body = JSON.parse(res.body)
      assert body["ok"]
      assert_equal ["acme"], body["deleted"]
      assert_equal ["acme"], called
    end

    def test_clear_session_returns_502_when_freentonic_unreachable
      req("POST", "/admin/api/profiles", body: { profile_key: "acme", workflow: @workflow_name }, headers: admin)

      @feature.freentonic_client.define_singleton_method(:prune_profile) do |_|
        raise FreentonicClient::ConnectionError, "connection refused"
      end

      res = req("POST", "/admin/api/profiles/acme/clear-session", headers: admin)
      assert_equal "502", res.code
      body = JSON.parse(res.body)
      assert_match(/freentonic unreachable/, body["error"])
    end

    def test_freentonic_health_probe_endpoint
      # No real freentonic; the client will fail the probe. We only care
      # that the endpoint runs and returns a snapshot with state info.
      health = FreentonicHealth.new(client: @feature.freentonic_client)
      @feature.install_freentonic_health(health)
      res = req("POST", "/admin/api/freentonic/health/probe", headers: admin)
      assert_equal "200", res.code
      body = JSON.parse(res.body)
      assert_includes %w[active degraded unknown], body["state"]
      refute_nil body["last_probe_at"]
    end

    def test_workflows_refresh_endpoint_lays_down_provider_dirs
      # Build a tiny tarball + monkey-patch WorkflowsRefresher to use
      # an in-memory fixture instead of hitting GitHub. We patch
      # singleton on the constructor path via initializer args by
      # routing through the same env override the handler reads.
      tar_bytes = nil
      Dir.mktmpdir("proto-refresh-build-") do |tmp|
        provider_dir = File.join(tmp, "freentonic-providers-main", "acme")
        FileUtils.mkdir_p(provider_dir)
        File.write(File.join(provider_dir, "workflow.yml"), "version: 1\n")
        Dir.chdir(tmp) do
          system("tar", "-czf", "providers.tar.gz", "freentonic-providers-main", exception: true)
          tar_bytes = File.binread(File.join(tmp, "providers.tar.gz"))
        end
      end

      # Stub the HTTP fetch by injecting via WorkflowsRefresher's
      # http_get keyword. The handler currently builds the refresher
      # fresh per call, so we monkey-patch ::new to thread our stub
      # for this test only.
      original_new = WorkflowsRefresher.method(:new)
      WorkflowsRefresher.define_singleton_method(:new) do |**kwargs|
        original_new.call(**kwargs.merge(http_get: ->(_url) { tar_bytes }))
      end
      begin
        res = req("POST", "/admin/api/workflows/refresh", headers: admin)
        assert_equal "200", res.code
        body = JSON.parse(res.body)
        assert_equal ["acme"], body["providers"]
        assert_path_exists File.join(@workflows_dir, "acme", "workflow.yml")
      ensure
        WorkflowsRefresher.singleton_class.send(:remove_method, :new)
        WorkflowsRefresher.define_singleton_method(:new, original_new)
      end
    end

    def test_browse_endpoint_enqueues_interactive_job
      provision_profile_with_credentials("acme")
      res = req("POST", "/admin/api/profiles/acme/browse", headers: admin)
      assert_equal "200", res.code
      body = JSON.parse(res.body)
      assert body["interactive"]
      assert_match(/\A[A-Za-z0-9]{8}\z/, body["vnc_password"])
      assert_match(%r{/novnc/vnc\.html}, body["vnc_url"])
      # Recording queue captures everything enqueued; verify it's flagged.
      assert_equal "acme", @queue.enqueued.last.first
    end

    def test_cancel_run_endpoint_calls_freentonic
      called = []
      @feature.freentonic_client.define_singleton_method(:cancel) do |run_id|
        called << run_id
        { "ok" => true, "cancelled" => true }
      end
      res = req("POST", "/admin/api/runs/simplefreen-acme-abc123/cancel", headers: admin)
      assert_equal "200", res.code
      body = JSON.parse(res.body)
      assert body["ok"]
      assert_equal ["simplefreen-acme-abc123"], called
    end

    def test_cancel_run_rejects_invalid_run_id
      res = req("POST", "/admin/api/runs/..%2Fetc/cancel", headers: admin)
      assert_equal "404", res.code
    end

    # ── helpers ─────────────────────────────────────────────

    def provision_profile_with_credentials(key)
      req("POST", "/admin/api/profiles",
          body: { profile_key: key, workflow: @workflow_name }, headers: admin)
      req("POST", "/admin/api/profiles/#{key}/credentials",
          body: { secrets: { "USER_DNI" => "12345", "USER_PIN" => "9999" } },
          headers: admin)
    end

    def provision_profile_with_access_url(key)
      req("POST", "/admin/api/profiles", body: { profile_key: key, workflow: @workflow_name }, headers: admin)
      res = req("POST", "/admin/api/profiles/#{key}/setup-token", headers: admin)
      claim_url = Base64.strict_decode64(JSON.parse(res.body)["setup_token"])
      @claim_response = req("POST", URI(claim_url).path)
    end

    # Eligible for /admin/api/sync-all: profile has both stored credentials
    # AND a claimed access URL (password_pw on disk).
    def provision_profile_for_sync_all(key)
      req("POST", "/admin/api/profiles",
          body: { profile_key: key, workflow: @workflow_name }, headers: admin)
      req("POST", "/admin/api/profiles/#{key}/credentials",
          body: { secrets: { "USER_DNI" => "12345", "USER_PIN" => "9999" } },
          headers: admin)
      res = req("POST", "/admin/api/profiles/#{key}/setup-token", headers: admin)
      claim_url = Base64.strict_decode64(JSON.parse(res.body)["setup_token"])
      req("POST", URI(claim_url).path)
    end

    # Reproduces what Actual's sync-server (and the real SimpleFIN CLI)
    # does: take the access URL's base path and append /accounts. Always
    # returns the final path the account-fetching GET hits.
    def current_access_url(key)
      uri = URI(@claim_response.body.strip)
      user = URI.decode_www_form_component(uri.user)
      password = URI.decode_www_form_component(uri.password)
      path = uri.path + "/accounts"
      [path, user, password]
    end

    def basic_auth(user, password)
      { "Authorization" => "Basic #{Base64.strict_encode64("#{user}:#{password}")}" }
    end
  end
end
