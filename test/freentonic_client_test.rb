# frozen_string_literal: true

require_relative "test_helper"
require "net/http"
require "json"

module Simplefreen
  class FreentonicClientTest < Minitest::Test
    # Minimal fake Net::HTTP response. Mirrors the subset the client reads.
    FakeResp = Struct.new(:code, :body, :headers) do
      def initialize(code, body, headers = {})
        super
      end
      def [](key); (headers || {})[key]; end
      def is_a?(klass)
        case klass.name
        when "Net::HTTPSuccess"
          (200..299).cover?(code.to_i)
        when "Net::HTTPPartialContent"
          code.to_i == 206
        else
          super
        end
      end
    end

    # Builds a fake Net::HTTP object whose #request returns whatever the
    # block produces. Captures the request for assertions.
    def with_fake_http(&responder)
      captured = []
      fake = Object.new
      fake.define_singleton_method(:use_ssl=) { |_| }
      fake.define_singleton_method(:open_timeout=) { |_| }
      fake.define_singleton_method(:read_timeout=) { |_| }
      fake.define_singleton_method(:request) do |req|
        captured << req
        responder.call(req)
      end
      [fake, captured]
    end

    def test_healthz_returns_parsed_json
      fake, _captured = with_fake_http { |_req| FakeResp.new("200", '{"ok":true}') }
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "t")
        assert_equal({ "ok" => true }, client.healthz)
      end
    end

    def test_healthz_raises_http_error_on_non_2xx
      fake, _ = with_fake_http { |_req| FakeResp.new("500", "oops") }
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "t")
        err = assert_raises(FreentonicClient::HttpError) { client.healthz }
        assert_equal 500, err.status
      end
    end

    def test_invoke_sends_bearer_and_json_body
      fake, captured = with_fake_http do |_req|
        FakeResp.new("200", JSON.generate({
          "run_id" => "r1", "exit_code" => 0, "error_kind" => nil,
          "duration_ms" => 42, "artifacts" => [], "log_path" => "runs/r1/log",
          "warnings" => []
        }))
      end
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "tok-xyz")
        result = client.invoke({
          "run_id" => "r1", "workflow" => "ing/workflow.yml",
          "credentials" => { "inline" => { "USER" => "me" } },
          "export" => { "mode" => "http", "url" => "http://simplefreen/push/r1", "token" => "one-shot" }
        })
        assert_equal "r1", result.run_id
        assert_equal 0, result.exit_code
        assert_equal 42, result.duration_ms

        req = captured.last
        assert_equal "application/json", req["Content-Type"]
        assert_equal "Bearer tok-xyz", req["Authorization"]
        body = JSON.parse(req.body)
        assert_equal "r1", body["run_id"]
        assert_equal "http", body["export"]["mode"]
      end
    end

    def test_invoke_raises_timeout_error_on_read_timeout
      fake = Object.new
      fake.define_singleton_method(:use_ssl=) { |_| }
      fake.define_singleton_method(:open_timeout=) { |_| }
      fake.define_singleton_method(:read_timeout=) { |_| }
      fake.define_singleton_method(:request) { |_| raise Net::ReadTimeout, "deadline hit" }
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "t")
        err = assert_raises(FreentonicClient::TimeoutError) do
          client.invoke("run_id" => "r1", "timeout_sec" => 5)
        end
        assert_match(/deadline hit/, err.message)
      end
    end

    def test_invoke_raises_connection_error_when_unreachable
      fake = Object.new
      fake.define_singleton_method(:use_ssl=) { |_| }
      fake.define_singleton_method(:open_timeout=) { |_| }
      fake.define_singleton_method(:read_timeout=) { |_| }
      fake.define_singleton_method(:request) { |_| raise Errno::ECONNREFUSED }
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "t")
        assert_raises(FreentonicClient::ConnectionError) { client.invoke({}) }
      end
    end

    # ── async /invoke: 202-accept + GET /runs/:id polling (PR #25) ─────────

    # A test client that never really sleeps and can be handed a scripted
    # monotonic clock. Keeps the poll loop instant and deterministic.
    def async_client(clock: nil)
      FreentonicClient.new(
        base_url: "http://freentonic", invoke_token: "tok",
        poll_interval: 0, sleeper: ->(_s) {}, clock: clock
      )
    end

    def test_invoke_posts_202_then_polls_until_done
      calls = []
      fake, captured = with_fake_http do |req|
        calls << req.method
        if req.method == "POST"
          FakeResp.new("202", JSON.generate({ "run_id" => "r1", "status" => "queued" }))
        else # GET /runs/r1 — running first, then done
          gets = calls.count { |m| m == "GET" }
          if gets == 1
            FakeResp.new("200", JSON.generate({
              "run_id" => "r1", "status" => "running",
              "started_at" => "t", "elapsed_ms" => 10
            }))
          else
            FakeResp.new("200", JSON.generate({
              "run_id" => "r1", "status" => "done", "exit_code" => 0,
              "error_kind" => nil, "duration_ms" => 4200,
              "artifacts" => [{ "path" => "runs/r1/log", "size" => 9 }],
              "log_path" => "runs/r1/log", "warnings" => [], "finished_at" => "t2"
            }))
          end
        end
      end
      with_net_http_new(fake) do
        result = async_client.invoke({
          "run_id" => "r1", "workflow" => "ing/workflow.yml",
          "credentials" => { "inline" => { "USER" => "me" } }
        })
        assert_equal "done", result.status
        assert_equal 0, result.exit_code
        assert_equal 4200, result.duration_ms
        assert_equal "runs/r1/log", result.log_path
        assert_equal 1, result.artifacts.size

        # POST first, then at least two polled GETs to /runs/r1 with bearer.
        assert_equal "POST", captured.first.method
        assert_equal "Bearer tok", captured.first["Authorization"]
        gets = captured.select { |r| r.method == "GET" }
        assert_operator gets.size, :>=, 2
        assert(gets.all? { |r| r.path =~ %r{/runs/r1\z} })
        assert(gets.all? { |r| r["Authorization"] == "Bearer tok" })
      end
    end

    def test_invoke_returns_result_from_legacy_200_without_polling
      fake, captured = with_fake_http do |_req|
        FakeResp.new("200", JSON.generate({
          "run_id" => "r1", "status" => "done", "exit_code" => 0,
          "error_kind" => nil, "duration_ms" => 42, "artifacts" => [],
          "log_path" => "runs/r1/log", "warnings" => []
        }))
      end
      with_net_http_new(fake) do
        result = async_client.invoke({ "run_id" => "r1" })
        assert_equal 0, result.exit_code
        # Legacy sync server: the POST body is the result — no polling.
        assert_equal 1, captured.size
        assert_equal "POST", captured.first.method
      end
    end

    def test_invoke_raises_error_when_run_finishes_with_error_status
      fake, _ = with_fake_http do |req|
        if req.method == "POST"
          FakeResp.new("202", JSON.generate({ "run_id" => "r1", "status" => "queued" }))
        else
          FakeResp.new("200", JSON.generate({
            "run_id" => "r1", "status" => "error",
            "error" => "profile_key escapes its containment root", "finished_at" => "t"
          }))
        end
      end
      with_net_http_new(fake) do
        err = assert_raises(FreentonicClient::Error) { async_client.invoke({ "run_id" => "r1" }) }
        assert_match(/escapes its containment root/, err.message)
      end
    end

    def test_invoke_raises_cancelled_error_when_run_cancelled_while_queued
      fake, _ = with_fake_http do |req|
        if req.method == "POST"
          FakeResp.new("202", JSON.generate({ "run_id" => "r1", "status" => "queued" }))
        else
          FakeResp.new("200", JSON.generate({
            "run_id" => "r1", "status" => "cancelled", "finished_at" => "t"
          }))
        end
      end
      with_net_http_new(fake) do
        assert_raises(FreentonicClient::CancelledError) { async_client.invoke({ "run_id" => "r1" }) }
      end
    end

    def test_invoke_raises_queue_full_error_on_503
      fake, _ = with_fake_http do |_req|
        FakeResp.new("503", JSON.generate({ "error" => "run queue full; retry later", "retry_after" => 5 }))
      end
      with_net_http_new(fake) do
        err = assert_raises(FreentonicClient::QueueFullError) { async_client.invoke({ "run_id" => "r1" }) }
        assert_equal 5, err.retry_after
      end
    end

    def test_invoke_raises_http_error_on_409_duplicate_run_id
      fake, _ = with_fake_http { |_req| FakeResp.new("409", JSON.generate({ "error" => "run_id already in flight" })) }
      with_net_http_new(fake) do
        err = assert_raises(FreentonicClient::HttpError) { async_client.invoke({ "run_id" => "r1" }) }
        assert_equal 409, err.status
      end
    end

    def test_invoke_raises_http_error_on_400_validation
      fake, _ = with_fake_http { |_req| FakeResp.new("400", JSON.generate({ "error" => "workflow is required" })) }
      with_net_http_new(fake) do
        err = assert_raises(FreentonicClient::HttpError) { async_client.invoke({}) }
        assert_equal 400, err.status
      end
    end

    def test_invoke_raises_error_when_run_evicted_during_poll
      fake, _ = with_fake_http do |req|
        if req.method == "POST"
          FakeResp.new("202", JSON.generate({ "run_id" => "r1", "status" => "queued" }))
        else
          FakeResp.new("404", JSON.generate({ "error" => "run not found" }))
        end
      end
      with_net_http_new(fake) do
        err = assert_raises(FreentonicClient::Error) { async_client.invoke({ "run_id" => "r1" }) }
        assert_match(/unknown or was evicted/, err.message)
      end
    end

    def test_invoke_tolerates_transient_poll_failures_then_returns
      gets = { n: 0 }
      fake, _ = with_fake_http do |req|
        if req.method == "POST"
          FakeResp.new("202", JSON.generate({ "run_id" => "r1", "status" => "queued" }))
        else
          gets[:n] += 1
          raise Errno::ECONNREFUSED if gets[:n] <= 2
          FakeResp.new("200", JSON.generate({
            "run_id" => "r1", "status" => "done", "exit_code" => 0, "error_kind" => nil,
            "duration_ms" => 1, "artifacts" => [], "log_path" => "runs/r1/log", "warnings" => []
          }))
        end
      end
      with_net_http_new(fake) do
        result = async_client.invoke({ "run_id" => "r1" })
        assert_equal 0, result.exit_code
        assert_operator gets[:n], :>=, 3
      end
    end

    def test_invoke_raises_connection_error_after_persistent_poll_failures
      fake, _ = with_fake_http do |req|
        if req.method == "POST"
          FakeResp.new("202", JSON.generate({ "run_id" => "r1", "status" => "queued" }))
        else
          raise Errno::ECONNREFUSED
        end
      end
      with_net_http_new(fake) do
        assert_raises(FreentonicClient::ConnectionError) { async_client.invoke({ "run_id" => "r1" }) }
      end
    end

    def test_invoke_times_out_when_run_never_reaches_terminal_state
      # Scripted monotonic clock: setup call, one in-window check, then a
      # value past the deadline so the second loop iteration gives up.
      ticks = [0.0, 10.0, 10_000.0]
      clock = -> { ticks.length > 1 ? ticks.shift : ticks.first }
      fake, _ = with_fake_http do |req|
        if req.method == "POST"
          FakeResp.new("202", JSON.generate({ "run_id" => "r1", "status" => "queued" }))
        else
          FakeResp.new("200", JSON.generate({
            "run_id" => "r1", "status" => "running", "started_at" => "t", "elapsed_ms" => 1
          }))
        end
      end
      with_net_http_new(fake) do
        err = assert_raises(FreentonicClient::TimeoutError) do
          async_client(clock: clock).invoke({ "run_id" => "r1", "timeout_sec" => 5 })
        end
        assert_match(/terminal state/, err.message)
      end
    end

    def test_fetch_run_log_returns_body_size_truncated
      fake, captured = with_fake_http do |_req|
        FakeResp.new("206", "last 20 bytes of log", { "Content-Range" => "bytes 980-999/1000" })
      end
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "t")
        body, size, truncated = client.fetch_run_log("simplefreen-acme-abc", max_bytes: 20)
        assert_equal "last 20 bytes of log", body
        assert_equal 1000, size
        assert truncated

        req = captured.last
        assert_equal "bytes=-20", req["Range"]
      end
    end

    def test_fetch_run_log_returns_nil_on_404
      fake, _ = with_fake_http { |_req| FakeResp.new("404", "not found") }
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "t")
        assert_nil client.fetch_run_log("no-such")
      end
    end

    # ── tail_run_log: incremental forward-range live tailing ──────────────

    def test_tail_run_log_sends_forward_range_and_returns_chunk
      fake, captured = with_fake_http do |_req|
        FakeResp.new("206", "new bytes here", { "Content-Range" => "bytes 100-113/114" })
      end
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "tok")
        data = client.tail_run_log("simplefreen-acme-r1", offset: 100, max_bytes: 1024)
        assert_equal "new bytes here", data[:chunk]
        assert_equal 114, data[:next_offset]   # 100 + 14 bytes consumed
        assert_equal 114, data[:size]

        req = captured.last
        assert_equal "Bearer tok", req["Authorization"]
        assert_equal "bytes=100-1123", req["Range"]   # offset .. offset+max-1
        assert_match(%r{/runs/simplefreen-acme-r1/log\z}, req.path)
      end
    end

    def test_tail_run_log_416_reports_no_new_bytes_and_keeps_offset
      fake, _ = with_fake_http do |_req|
        FakeResp.new("416", "", { "Content-Range" => "bytes */500" })
      end
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "t")
        data = client.tail_run_log("r1", offset: 500)
        assert_equal "", data[:chunk]
        assert_equal 500, data[:next_offset]   # unchanged — nothing appended yet
        assert_equal 500, data[:size]
      end
    end

    def test_tail_run_log_holds_back_partial_utf8_at_boundary
      # "abé" (4 bytes) followed by a dangling first byte of a 2-byte char.
      raw = ("abé".b + "\xC3".b)  # 5 bytes; last byte is an incomplete seq
      fake, _ = with_fake_http do |_req|
        FakeResp.new("206", raw, { "Content-Range" => "bytes 0-4/200" })
      end
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "t")
        data = client.tail_run_log("r1", offset: 0)
        assert_equal "abé", data[:chunk]
        assert data[:chunk].valid_encoding?
        assert_equal Encoding::UTF_8, data[:chunk].encoding
        # Only 4 of 5 bytes consumed; the dangling 0xC3 is re-fetched next poll.
        assert_equal 4, data[:next_offset]
      end
    end

    def test_tail_run_log_returns_nil_on_404
      fake, _ = with_fake_http { |_req| FakeResp.new("404", "not found") }
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "t")
        assert_nil client.tail_run_log("no-such", offset: 0)
      end
    end

    def test_tail_run_log_raises_http_error_on_5xx
      fake, _ = with_fake_http { |_req| FakeResp.new("500", "boom") }
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "t")
        err = assert_raises(FreentonicClient::HttpError) { client.tail_run_log("r1", offset: 0) }
        assert_equal 500, err.status
      end
    end

    def test_tail_run_log_rejects_bad_offset
      client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "t")
      assert_raises(ArgumentError) { client.tail_run_log("r1", offset: -1) }
      assert_raises(ArgumentError) { client.tail_run_log("r1", offset: "10") }
    end

    # End-to-end: polling with the returned offset across a growing log must
    # reconstruct exactly what was appended, with no gaps or repeats.
    def test_tail_run_log_streams_growing_log_across_polls
      log = +"".b   # mutable byte buffer the fake serves ranges from
      fake, _ = with_fake_http do |req|
        m = req["Range"].match(/\Abytes=(\d+)-(\d+)\z/)
        a = m[1].to_i
        if a >= log.bytesize
          FakeResp.new("416", "", { "Content-Range" => "bytes */#{log.bytesize}" })
        else
          b = [m[2].to_i, log.bytesize - 1].min
          slice = log.byteslice(a..b)
          FakeResp.new("206", slice, { "Content-Range" => "bytes #{a}-#{b}/#{log.bytesize}" })
        end
      end

      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "t")
        acc = +""
        offset = 0

        # 1. Empty log → 416, nothing consumed.
        d = client.tail_run_log("r1", offset: offset)
        assert_equal "", d[:chunk]
        offset = d[:next_offset]
        assert_equal 0, offset

        # 2. Two appends, each picked up from the prior offset.
        log << "hello\n"
        d = client.tail_run_log("r1", offset: offset)
        acc << d[:chunk]; offset = d[:next_offset]

        log << "world!\n"
        d = client.tail_run_log("r1", offset: offset)
        acc << d[:chunk]; offset = d[:next_offset]

        # 3. No new bytes → 416, offset holds.
        d = client.tail_run_log("r1", offset: offset)
        assert_equal "", d[:chunk]
        assert_equal offset, d[:next_offset]

        assert_equal "hello\nworld!\n", acc
        assert_equal log.bytesize, offset
      end
    end

    def test_prune_profile_posts_json_with_bearer_and_returns_deleted
      fake, captured = with_fake_http do |_req|
        FakeResp.new("200", JSON.generate({ "deleted" => ["acme"], "count" => 1 }))
      end
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "tok-xyz")
        result = client.prune_profile("acme")
        assert_equal ["acme"], result["deleted"]

        req = captured.last
        assert_equal "Bearer tok-xyz", req["Authorization"]
        assert_equal "application/json", req["Content-Type"]
        body = JSON.parse(req.body)
        assert_equal "acme", body["profile_key"]
      end
    end

    def test_prune_profile_raises_http_error_on_400
      fake, _ = with_fake_http { |_req| FakeResp.new("400", "bad profile_key") }
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "t")
        err = assert_raises(FreentonicClient::HttpError) { client.prune_profile("../etc") }
        assert_equal 400, err.status
      end
    end

    def test_fetch_run_prompts_returns_array_with_bearer
      fake, captured = with_fake_http do |_req|
        FakeResp.new("200", JSON.generate({
          "run_id"  => "r1",
          "prompts" => [{
            "prompt_id" => "p1", "kind" => "input", "message" => "Enter the SMS code:",
            "mask" => true, "created_at" => "2026-04-30T12:00:00Z",
            "expires_at" => "2026-04-30T12:05:00Z"
          }]
        }))
      end
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "tok")
        prompts = client.fetch_run_prompts("simplefreen-acme-r1")
        assert_equal 1, prompts.size
        assert_equal "p1", prompts.first["prompt_id"]
        assert_equal "input", prompts.first["kind"]

        req = captured.last
        assert_equal "Bearer tok", req["Authorization"]
        assert_match(%r{/runs/simplefreen-acme-r1/prompts\z}, req.path)
      end
    end

    def test_fetch_run_prompts_returns_empty_when_no_prompts_pending
      fake, _ = with_fake_http { |_req| FakeResp.new("200", JSON.generate({ "run_id" => "r1", "prompts" => [] })) }
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "t")
        assert_equal [], client.fetch_run_prompts("r1")
      end
    end

    def test_fetch_run_prompts_returns_nil_on_404
      fake, _ = with_fake_http { |_req| FakeResp.new("404", JSON.generate({ "error" => "run_id not found" })) }
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "t")
        assert_nil client.fetch_run_prompts("no-such")
      end
    end

    def test_submit_prompt_answer_input_posts_value_and_returns_ok
      fake, captured = with_fake_http { |_req| FakeResp.new("200", JSON.generate({ "ok" => true, "prompt_id" => "p1" })) }
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "tok")
        result = client.submit_prompt_answer("r1", "p1", kind: "input", value: "123456")
        assert_equal({ ok: true, status: 200 }, result)

        req = captured.last
        assert_equal "Bearer tok", req["Authorization"]
        assert_equal "application/json", req["Content-Type"]
        assert_match(%r{/runs/r1/prompts/p1\z}, req.path)
        assert_equal({ "value" => "123456" }, JSON.parse(req.body))
      end
    end

    def test_submit_prompt_answer_confirm_posts_empty_body
      fake, captured = with_fake_http { |_req| FakeResp.new("200", JSON.generate({ "ok" => true, "prompt_id" => "p1" })) }
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "t")
        result = client.submit_prompt_answer("r1", "p1", kind: "confirm")
        assert result[:ok]
        assert_equal({}, JSON.parse(captured.last.body))
      end
    end

    def test_submit_prompt_answer_returns_structured_failure_on_409
      fake, _ = with_fake_http { |_req| FakeResp.new("409", JSON.generate({ "error" => "prompt already answered" })) }
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "t")
        result = client.submit_prompt_answer("r1", "p1", kind: "input", value: "abc")
        assert_equal false, result[:ok]
        assert_equal 409, result[:status]
      end
    end

    def test_submit_prompt_answer_returns_structured_failure_on_410
      fake, _ = with_fake_http { |_req| FakeResp.new("410", JSON.generate({ "error" => "prompt expired" })) }
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "t")
        result = client.submit_prompt_answer("r1", "p1", kind: "input", value: "abc")
        assert_equal false, result[:ok]
        assert_equal 410, result[:status]
      end
    end

    def test_submit_prompt_answer_raises_argument_error_on_empty_input_value
      client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "t")
      assert_raises(ArgumentError) do
        client.submit_prompt_answer("r1", "p1", kind: "input", value: "")
      end
    end

    def test_submit_prompt_answer_raises_http_error_on_5xx
      fake, _ = with_fake_http { |_req| FakeResp.new("500", "boom") }
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "t")
        err = assert_raises(FreentonicClient::HttpError) do
          client.submit_prompt_answer("r1", "p1", kind: "input", value: "abc")
        end
        assert_equal 500, err.status
      end
    end

    def test_fetch_run_recording_returns_jsonl_body_with_bearer
      jsonl = <<~JSONL
        {"kind":"recorder_started","t":1}
        {"kind":"click","selector":"#login","tag":"button"}
      JSONL
      fake, captured = with_fake_http { |_req| FakeResp.new("200", jsonl) }
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "tok")
        body = client.fetch_run_recording("simplefreen-acme-r1")
        assert_equal jsonl, body

        req = captured.last
        assert_equal "Bearer tok", req["Authorization"]
        assert_match(%r{/runs/simplefreen-acme-r1/recording\z}, req.path)
      end
    end

    def test_fetch_run_recording_returns_nil_on_404
      fake, _ = with_fake_http { |_req| FakeResp.new("404", JSON.generate({ "error" => "recording not found" })) }
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "t")
        assert_nil client.fetch_run_recording("no-such")
      end
    end

    def test_fetch_run_recording_raises_http_error_on_5xx
      fake, _ = with_fake_http { |_req| FakeResp.new("500", "boom") }
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "t")
        err = assert_raises(FreentonicClient::HttpError) { client.fetch_run_recording("r1") }
        assert_equal 500, err.status
      end
    end

    # ── fetch_run_raw (audit-mode dump) ───────────────────

    def test_fetch_run_raw_returns_parsed_json_with_bearer
      payload = { "accounts" => [{ "id" => "ing-1" }], "transactions" => [] }
      fake, captured = with_fake_http { |_req| FakeResp.new("200", JSON.generate(payload)) }
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "tok")
        body = client.fetch_run_raw("simplefreen-ing-abc")
        assert_equal payload, body

        req = captured.last
        assert_equal "Bearer tok", req["Authorization"]
        assert_match(%r{/runs/simplefreen-ing-abc/raw\z}, req.path)
      end
    end

    def test_fetch_run_raw_returns_nil_on_404
      fake, _ = with_fake_http { |_req| FakeResp.new("404", JSON.generate({ "error" => "raw not found" })) }
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "t")
        assert_nil client.fetch_run_raw("no-such")
      end
    end

    def test_fetch_run_raw_raises_on_5xx
      fake, _ = with_fake_http { |_req| FakeResp.new("500", "boom") }
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "t")
        err = assert_raises(FreentonicClient::HttpError) { client.fetch_run_raw("r1") }
        assert_equal 500, err.status
      end
    end

    def test_fetch_run_raw_raises_on_non_json_body
      fake, _ = with_fake_http { |_req| FakeResp.new("200", "not json") }
      with_net_http_new(fake) do
        client = FreentonicClient.new(base_url: "http://freentonic", invoke_token: "t")
        assert_raises(FreentonicClient::Error) { client.fetch_run_raw("r1") }
      end
    end
  end
end
