# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "json"
require "net/http"
require "socket"

module Simplefreen
  # Tests POST /push/<run_id>. Boots the real Server + Router + Feature
  # and a fake scheduler-as-stub so the push receiver has an active_job
  # to correlate against.
  class PushReceiverTest < Minitest::Test
    class ActiveJobStub
      attr_reader :active_job
      def initialize(profile_key:, run_id:)
        @active_job = { profile_key: profile_key, run_id: run_id }
      end
      def enqueue(*, **); :enqueued; end
      def pending_keys; []; end
      def active_key; @active_job[:profile_key]; end
    end

    def setup
      @root          = Dir.mktmpdir("simplefreen-push-")
      @workflows_dir = Dir.mktmpdir("simplefreen-push-wf-")

      @master = Crypto.decode_master_key(Crypto.generate_master_key_b64)
      @feature = Feature.new(
        root:                    @root,
        master_key:              @master,
        admin_password:          "pw",
        public_url:              "http://simplefreen",
        freentonic_url:          "http://freentonic",
        freentonic_invoke_token: "t"
      )
      @feature.profile_store.create(key: "acme", workflow: "acme/workflow.yml")

      @tokens = PushTokens.new
      @feature.install_push_tokens(@tokens)

      @router = Router.new(
        feature:       @feature,
        workflows_dir: @workflows_dir,
        asset_dir:     File.expand_path("../lib/simplefreen/ui", __dir__)
      )

      @port = find_free_port
      @server = Server.new(router: @router, listen_addr: "127.0.0.1",
                           listen_port: @port, logger: nil)
      @thread = Thread.new { @server.start }
      wait_for_server_up
    end

    def teardown
      @server&.shutdown
      @thread&.join(3)
      FileUtils.rm_rf(@root)
      FileUtils.rm_rf(@workflows_dir)
    end

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

    def post(path, body, token: nil)
      uri = URI("http://127.0.0.1:#{@port}#{path}")
      req = Net::HTTP::Post.new(uri.request_uri)
      req["Content-Type"] = "application/json"
      req["Authorization"] = "Bearer #{token}" if token
      req.body = body.is_a?(String) ? body : JSON.generate(body)
      Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
    end

    def payload_for(account_id)
      {
        "schema_version" => "0.1",
        "summary" => { "counts" => { "accounts" => 1, "transactions" => 0 } },
        "meta" => {},
        "accounts" => [
          {
            "id"          => account_id,
            "institution" => "ing",
            "name"        => "Fake",
            "currency"    => "EUR",
            "balance"     => { "current" => "100.00", "timestamp" => "2026-04-22T10:00:00Z" }
          }
        ],
        "transactions" => [],
        "liabilities"  => [],
        "investments"  => []
      }
    end

    def test_push_with_valid_token_and_active_job_writes_cache
      run_id = "simplefreen-acme-abc123"
      token  = @tokens.mint(run_id)
      @feature.install_scheduler(ActiveJobStub.new(profile_key: "acme", run_id: run_id))

      res = post("/push/#{run_id}", payload_for("acc_1111111111111111"), token: token)
      assert_equal "200", res.code
      body = JSON.parse(res.body)
      assert_equal true, body["ok"]
      assert_equal 1, body["accounts"]

      assert @feature.cache_store.exists?("acme")
      state = @feature.state_store.read("acme")
      assert_equal "ready", state["state"]
    end

    def test_push_persists_canonical_envelope_and_meta
      run_id = "simplefreen-acme-canonical"
      token  = @tokens.mint(run_id)
      @feature.install_scheduler(ActiveJobStub.new(profile_key: "acme", run_id: run_id))

      payload = payload_for("acc_1111111111111111").merge(
        "transactions" => [
          { "id" => "txn_aaaaaaaaaaaaaaaa", "account_id" => "acc_1111111111111111",
            "date" => "2026-04-20", "amount" => "-12.34", "currency" => "EUR",
            "description" => "Coffee", "status" => "posted" }
        ]
      )
      res = post("/push/#{run_id}", payload, token: token)
      assert_equal "200", res.code

      canonical_path = Paths.run_canonical_path("acme", run_id, @root)
      meta_path      = Paths.run_canonical_meta_path("acme", run_id, @root)
      assert File.file?(canonical_path), "canonical envelope was not persisted"
      assert File.file?(meta_path),      "canonical meta was not persisted"

      stored = JSON.parse(File.read(canonical_path))
      assert_equal "0.1", stored["schema_version"]
      assert_equal 1, stored["accounts"].size
      assert_equal 1, stored["transactions"].size

      meta = JSON.parse(File.read(meta_path))
      assert_equal "0.1", meta["schema_version"]
      assert_equal 1, meta["accounts_count"]
      assert_equal 1, meta["transactions_count"]
      assert_equal 0, meta["reshape_errors"]
      assert_kind_of String, meta["received_at"]
    end

    def test_push_rejects_unknown_token
      run_id = "simplefreen-acme-xyz"
      @feature.install_scheduler(ActiveJobStub.new(profile_key: "acme", run_id: run_id))
      res = post("/push/#{run_id}", payload_for("acc_1111111111111111"), token: "bogus")
      assert_equal "401", res.code
      refute @feature.cache_store.exists?("acme")
    end

    def test_push_rejects_token_for_wrong_run_id
      token = @tokens.mint("simplefreen-acme-real")
      @feature.install_scheduler(ActiveJobStub.new(profile_key: "acme", run_id: "simplefreen-acme-other"))
      # Use token minted for a different run — should be rejected.
      res = post("/push/simplefreen-acme-other", payload_for("acc_1111111111111111"), token: token)
      assert_equal "401", res.code
    end

    def test_push_is_single_use
      run_id = "simplefreen-acme-once"
      token  = @tokens.mint(run_id)
      @feature.install_scheduler(ActiveJobStub.new(profile_key: "acme", run_id: run_id))

      first = post("/push/#{run_id}", payload_for("acc_1111111111111111"), token: token)
      assert_equal "200", first.code
      second = post("/push/#{run_id}", payload_for("acc_2222222222222222"), token: token)
      assert_equal "401", second.code
    end

    def test_push_without_bearer_is_401
      res = post("/push/anything", payload_for("acc_xxxxxxxxxxxxxxxx"))
      assert_equal "401", res.code
    end

    def test_push_rejects_bad_run_id_charset
      token = @tokens.mint("legit")
      res = post("/push/..%2Fescape", payload_for("acc_1111111111111111"), token: token)
      # ..%2Fescape isn't a single path segment the router can match, so
      # our dispatch returns 404 before handle_push runs.
      assert_includes %w[400 404], res.code
    end

    def test_push_rejects_body_without_accounts_array
      run_id = "simplefreen-acme-baddata"
      token  = @tokens.mint(run_id)
      @feature.install_scheduler(ActiveJobStub.new(profile_key: "acme", run_id: run_id))

      res = post("/push/#{run_id}", "not json at all", token: token)
      assert_equal "422", res.code
    end

    def test_push_rejects_non_canonical_payload_missing_schema_version
      run_id = "simplefreen-acme-legacy"
      token  = @tokens.mint(run_id)
      @feature.install_scheduler(ActiveJobStub.new(profile_key: "acme", run_id: run_id))

      # Canonical requires schema_version. A pre-v0.4 freentonic image
      # would POST without it; reject up front rather than letting Reshape
      # silently produce a broken SimpleFIN envelope.
      legacy = { "source_tag" => "ing", "accounts" => [] }
      res = post("/push/#{run_id}", legacy, token: token)
      assert_equal "422", res.code
      refute @feature.cache_store.exists?("acme")
    end

    def test_push_writes_to_history_store
      run_id = "simplefreen-acme-hist1"
      token  = @tokens.mint(run_id)
      @feature.install_scheduler(ActiveJobStub.new(profile_key: "acme", run_id: run_id))

      payload = payload_for("acc_1111111111111111").merge(
        "transactions" => [
          { "id" => "txn_h1aaaaaaaaaaaaaa", "account_id" => "acc_1111111111111111",
            "date" => "2026-05-01", "amount" => "-10.00", "currency" => "EUR",
            "description" => "First", "status" => "posted" }
        ]
      )
      res = post("/push/#{run_id}", payload, token: token)
      assert_equal "200", res.code

      hist = @feature.history_store.read("acme")
      refute_nil hist, "history was not written"
      assert_equal run_id, hist["last_run_id"]
      assert_equal 1, hist["transactions"].size
      assert_equal "txn_h1aaaaaaaaaaaaaa", hist["transactions"].first["id"]
    end

    def test_two_pushes_accumulate_in_history_with_dedup
      # First push: txn_a only.
      run_id1 = "simplefreen-acme-acc1"
      token1  = @tokens.mint(run_id1)
      @feature.install_scheduler(ActiveJobStub.new(profile_key: "acme", run_id: run_id1))
      p1 = payload_for("acc_1111111111111111").merge(
        "transactions" => [
          { "id" => "txn_aaaaaaaaaaaaaaaa", "account_id" => "acc_1111111111111111",
            "date" => "2026-05-01", "amount" => "-10.00", "currency" => "EUR",
            "description" => "A", "status" => "posted" }
        ]
      )
      assert_equal "200", post("/push/#{run_id1}", p1, token: token1).code

      # Second push: overlapping txn_a + new txn_b. Union with dedup expected.
      run_id2 = "simplefreen-acme-acc2"
      token2  = @tokens.mint(run_id2)
      @feature.install_scheduler(ActiveJobStub.new(profile_key: "acme", run_id: run_id2))
      p2 = payload_for("acc_1111111111111111").merge(
        "transactions" => [
          { "id" => "txn_aaaaaaaaaaaaaaaa", "account_id" => "acc_1111111111111111",
            "date" => "2026-05-01", "amount" => "-10.00", "currency" => "EUR",
            "description" => "A", "status" => "posted" },
          { "id" => "txn_bbbbbbbbbbbbbbbb", "account_id" => "acc_1111111111111111",
            "date" => "2026-05-02", "amount" => "-20.00", "currency" => "EUR",
            "description" => "B", "status" => "posted" }
        ]
      )
      assert_equal "200", post("/push/#{run_id2}", p2, token: token2).code

      hist = @feature.history_store.read("acme")
      ids = hist["transactions"].map { |t| t["id"] }.sort
      assert_equal %w[txn_aaaaaaaaaaaaaaaa txn_bbbbbbbbbbbbbbbb], ids
      assert_equal run_id2, hist["last_run_id"]
    end

    def test_served_envelope_reflects_accumulated_history
      # Push 1 contributes txn_a; push 2 contributes only txn_b but the
      # served SimpleFIN cache must show BOTH because it now derives from
      # the merged history, not just the latest run.
      run_id1 = "simplefreen-acme-merge1"
      token1  = @tokens.mint(run_id1)
      @feature.install_scheduler(ActiveJobStub.new(profile_key: "acme", run_id: run_id1))
      p1 = payload_for("acc_1111111111111111").merge(
        "transactions" => [
          { "id" => "txn_m1aaaaaaaaaaaaaa", "account_id" => "acc_1111111111111111",
            "date" => "2026-05-01", "amount" => "-10.00", "currency" => "EUR",
            "description" => "M1", "status" => "posted" }
        ]
      )
      assert_equal "200", post("/push/#{run_id1}", p1, token: token1).code

      run_id2 = "simplefreen-acme-merge2"
      token2  = @tokens.mint(run_id2)
      @feature.install_scheduler(ActiveJobStub.new(profile_key: "acme", run_id: run_id2))
      p2 = payload_for("acc_1111111111111111").merge(
        "transactions" => [
          { "id" => "txn_m2bbbbbbbbbbbbbb", "account_id" => "acc_1111111111111111",
            "date" => "2026-05-02", "amount" => "-20.00", "currency" => "EUR",
            "description" => "M2", "status" => "posted" }
        ]
      )
      assert_equal "200", post("/push/#{run_id2}", p2, token: token2).code

      envelope = @feature.cache_store.read("acme")
      txn_ids = envelope["accounts"].flat_map { |a| Array(a["transactions"]).map { |t| t["id"] } }.sort
      assert_includes txn_ids, "txn_m1aaaaaaaaaaaaaa"
      assert_includes txn_ids, "txn_m2bbbbbbbbbbbbbb"
    end

    def test_history_merge_failure_falls_back_to_per_run_envelope
      # If HistoryStore explodes mid-push the system must still serve
      # this run's data — the raw canonical is on disk for later rebuild.
      run_id = "simplefreen-acme-histfail"
      token  = @tokens.mint(run_id)
      @feature.install_scheduler(ActiveJobStub.new(profile_key: "acme", run_id: run_id))

      def @feature.history_store
        Object.new.tap do |o|
          def o.merge_run!(*, **); raise "boom"; end
        end
      end

      payload = payload_for("acc_1111111111111111").merge(
        "transactions" => [
          { "id" => "txn_ffffffffffffffff", "account_id" => "acc_1111111111111111",
            "date" => "2026-05-03", "amount" => "-30.00", "currency" => "EUR",
            "description" => "Fallback", "status" => "posted" }
        ]
      )
      res = post("/push/#{run_id}", payload, token: token)
      # Must still succeed and serve the per-run envelope.
      assert_equal "200", res.code
      envelope = @feature.cache_store.read("acme")
      txn_ids = envelope["accounts"].flat_map { |a| Array(a["transactions"]).map { |t| t["id"] } }
      assert_equal ["txn_ffffffffffffffff"], txn_ids
      # And the raw canonical is durable on disk for HistoryStore#rebuild_from_runs!.
      assert File.file?(Paths.run_canonical_path("acme", run_id, @root))
      # R-M2: the merge failure is not silent — a marker lands in state so
      # /admin/api/metrics can surface that history stopped accumulating.
      state = @feature.state_store.read("acme")
      assert_equal "ready", state["state"]
      refute_nil state["history_merge_failed_at"]
      assert_match(/boom/, state["last_merge_error"])
    end

    def test_successful_push_clears_merge_failure_marker
      # A clean merge after a failure must clear the marker.
      run_id = "simplefreen-acme-recovered"
      token  = @tokens.mint(run_id)
      @feature.install_scheduler(ActiveJobStub.new(profile_key: "acme", run_id: run_id))
      @feature.state_store.force_state("acme", "ready",
        "history_merge_failed_at" => "2020-01-01T00:00:00Z",
        "last_merge_error" => "old boom")

      res = post("/push/#{run_id}", payload_for("acc_1111111111111111"), token: token)
      assert_equal "200", res.code
      state = @feature.state_store.read("acme")
      assert_nil state["history_merge_failed_at"]
      assert_nil state["last_merge_error"]
    end

    def test_push_without_active_job_refuses_to_cache
      run_id = "simplefreen-acme-orphan"
      token  = @tokens.mint(run_id)
      # no scheduler installed → no active_job match
      res = post("/push/#{run_id}", payload_for("acc_1111111111111111"), token: token)
      assert_equal "422", res.code
      refute @feature.cache_store.exists?("acme")
    end

    # ── Body-size cap is decided before the body is read ──────

    # Sends only the request head, announcing a body that never arrives.
    # A 413 here proves the server rejected the size from headers alone,
    # without buffering anything.
    def head_only_status(path, content_length:, token: nil)
      sock = TCPSocket.new("127.0.0.1", @port)
      head = +"POST #{path} HTTP/1.1\r\nHost: x\r\nContent-Length: #{content_length}\r\n"
      head << "Authorization: Bearer #{token}\r\n" if token
      sock.write(head << "\r\n")
      sock.gets.to_s[/\AHTTP\/1\.1 (\d{3})/, 1]
    ensure
      sock&.close
    end

    def test_large_body_without_valid_push_token_is_refused_before_reading
      big = Server::MAX_PREAUTH_BODY_BYTES * 2
      assert_equal "413", head_only_status("/push/simplefreen-acme-big", content_length: big)
      assert_equal "413", head_only_status("/push/simplefreen-acme-big", content_length: big,
                                           token: "forged")
      assert_equal "413", head_only_status("/admin/login", content_length: big)
    end

    def test_large_push_with_valid_token_is_accepted
      run_id = "simplefreen-acme-big"
      token  = @tokens.mint(run_id)
      @feature.install_scheduler(ActiveJobStub.new(profile_key: "acme", run_id: run_id))

      payload = payload_for("acc_1111111111111111")
      payload["meta"] = { "pad" => "x" * (Server::MAX_PREAUTH_BODY_BYTES + 1) }
      res = post("/push/#{run_id}", payload, token: token)
      assert_equal "200", res.code
    end

    def test_large_push_token_check_does_not_consume_token
      # A token for one run must not unlock the large cap for another, and
      # the header-time check must leave the token for the receiver.
      run_id = "simplefreen-acme-big"
      token  = @tokens.mint(run_id)
      big    = Server::MAX_PREAUTH_BODY_BYTES * 2
      assert_equal "413", head_only_status("/push/simplefreen-acme-other", content_length: big,
                                           token: token)
      assert @tokens.valid?(run_id, token)
    end
  end
end
