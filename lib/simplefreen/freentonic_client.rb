# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Simplefreen
  # Thin HTTP wrapper around freentonic's public REST API. Shape follows
  # finanzas-web's `Freentonic::Client` — stdlib Net::HTTP only, bearer-
  # token auth, every response mapped to a typed struct. Raises typed
  # errors so the scheduler can branch on them.
  class FreentonicClient
    OPEN_TIMEOUT = 5

    # Since PR #25 (#13), POST /invoke returns 202 in milliseconds and the
    # result is observed by polling GET /runs/:id. These govern that poll.
    INVOKE_READ_TIMEOUT  = 10   # the 202 comes back fast; this only covers validation
    POLL_INTERVAL        = 2    # seconds between GET /runs/:id ticks
    POLL_READ_TIMEOUT    = 10   # per-poll read timeout
    POLL_DEADLINE_BUFFER = 120  # slack over the run's timeout_sec before we give up
    MAX_POLL_FAILURES    = 5    # consecutive transient poll errors tolerated before ConnectionError

    class Error < StandardError; end
    class HttpError < Error
      attr_reader :status, :body
      def initialize(status, body)
        @status = status
        @body = body
        super("freentonic returned HTTP #{status}: #{body.to_s.slice(0, 300)}")
      end
    end
    class TimeoutError < Error; end
    class ConnectionError < Error; end
    # POST /invoke returned 503 — the accepted-but-unfinished backlog is at
    # capacity (or the server is shutting down). Carries retry_after seconds
    # when the server supplied it.
    class QueueFullError < Error
      attr_reader :retry_after
      def initialize(body, retry_after: nil)
        @retry_after = retry_after
        hint = retry_after ? " (retry after #{retry_after}s)" : ""
        super("freentonic run queue is full#{hint}: #{body.to_s.slice(0, 200)}")
      end
    end
    # The run reached the terminal `cancelled` status — it was cancelled
    # while still queued, before any Chrome child spawned. (A run cancelled
    # *while running* finalizes as `done` with a non-zero exit_code instead.)
    class CancelledError < Error; end

    # Terminal state of a run. `status` is "done" for a run that executed to
    # completion (successfully or not — check exit_code). Mirrors freentonic's
    # InvokeRunner::Result plus the async lifecycle `status`.
    InvokeResult = Struct.new(
      :run_id, :status, :exit_code, :error_kind, :duration_ms,
      :artifacts, :log_path, :warnings,
      keyword_init: true
    )

    def initialize(base_url:, invoke_token:, open_timeout: OPEN_TIMEOUT, logger: nil,
                   invoke_read_timeout: INVOKE_READ_TIMEOUT, poll_interval: POLL_INTERVAL,
                   poll_read_timeout: POLL_READ_TIMEOUT, clock: nil, sleeper: nil)
      @base_url            = base_url.sub(/\/+\z/, "")
      @invoke_token        = invoke_token
      @open_timeout        = open_timeout
      @logger              = logger || ->(_msg) {}
      @invoke_read_timeout = invoke_read_timeout
      @poll_interval       = poll_interval
      @poll_read_timeout   = poll_read_timeout
      # Injectable for tests; monotonic so a wall-clock jump can't skew the
      # poll deadline. Sleeper is injectable so tests never really sleep.
      @clock   = clock   || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
    end

    # Ping the /healthz route. Returns the parsed JSON body on 200,
    # raises HttpError otherwise. Short timeout — this is a liveness probe.
    def healthz(read_timeout: 3)
      uri = URI.join(@base_url + "/", "healthz")
      get_json(uri, read_timeout: read_timeout, require_auth: false)
    end

    # Submit a workflow and block until it reaches a terminal state, then
    # return an InvokeResult. Since freentonic PR #25, /invoke is async:
    # POST validates and returns `202 {run_id, status:"queued"}` in ms, and
    # the result is observed by polling GET /runs/:id. We keep this method
    # blocking so the single-worker Scheduler contract is unchanged — it
    # still hands us a body and gets back a completed run.
    #
    # `body` is a Hash matching freentonic's InvokeRequest schema: run_id,
    # workflow, profile_key, lookback, credentials, export, chrome,
    # vnc_password. Caller is responsible for building it.
    #
    # Raises:
    #   HttpError       — request rejected (400/404/409/413/422/…)
    #   QueueFullError  — 503, backlog full / shutting down
    #   CancelledError  — run was cancelled while still queued
    #   TimeoutError    — POST timed out, or the run never went terminal
    #   ConnectionError — server unreachable (on POST, or persistently while polling)
    #   Error           — run finished with `error` status, unknown status,
    #                     evicted mid-poll, or a non-JSON body
    #
    # For backward compatibility with a not-yet-upgraded (synchronous)
    # freentonic, a `200` on the POST is treated as the legacy inline result,
    # so this client can ship independently of the container bump.
    def invoke(body)
      timeout_sec = body["timeout_sec"] || body[:timeout_sec] || 1800
      uri  = URI.join(@base_url + "/", "invoke")
      http = new_http(uri, read_timeout: @invoke_read_timeout)
      req  = Net::HTTP::Post.new(uri.request_uri)
      req["Content-Type"]  = "application/json"
      req["Authorization"] = "Bearer #{@invoke_token}"
      req.body = JSON.generate(body)

      resp = begin
        http.request(req)
      rescue Net::OpenTimeout => e
        raise TimeoutError, "open timeout on /invoke: #{e.message}"
      rescue Net::ReadTimeout => e
        raise TimeoutError, "read timeout on /invoke (validation): #{e.message}"
      rescue Errno::ECONNREFUSED, SocketError => e
        raise ConnectionError, "cannot reach freentonic at #{@base_url}: #{e.message}"
      end

      status = resp.code.to_i

      # 503: bounded backlog or shutdown. Our own @invoke_mutex means we
      # rarely fill the server's queue, but surface retry_after when we do.
      if status == 503
        retry_after = begin
          JSON.parse(resp.body)["retry_after"]
        rescue StandardError
          nil
        end
        raise QueueFullError.new(resp.body, retry_after: retry_after)
      end

      # Legacy synchronous server (pre-#25): the full result rides the POST.
      return build_invoke_result(parse_json!(resp.body)) if status == 200

      # New async contract: 202 accept. Anything else is a failure to accept.
      raise HttpError.new(status, resp.body) unless status == 202

      accepted = parse_json!(resp.body)
      run_id   = accepted["run_id"] || body["run_id"] || body[:run_id]
      poll_run(run_id, deadline_sec: timeout_sec + POLL_DEADLINE_BUFFER)
    end

    # Cancel an in-flight invoke. freentonic SIGTERMs the spawned
    # Chrome session; the child exits with a non-zero code which the
    # scheduler interprets as `error`. The main use is "browse mode"
    # (interactive=true on /invoke): the operator clicks "Stop
    # browsing" and we trigger the cancel here.
    def cancel(run_id, read_timeout: 10)
      uri = URI.join(@base_url + "/", "cancel/#{URI.encode_www_form_component(run_id)}")
      http = new_http(uri, read_timeout: read_timeout)
      req  = Net::HTTP::Post.new(uri.request_uri)
      req["Authorization"] = "Bearer #{@invoke_token}"
      resp = http.request(req)
      # 200 == cancel issued, 404 == nothing in flight under this run_id
      # (already finished or never started). Both are non-fatal from the
      # operator's point of view; surface the body either way.
      unless resp.is_a?(Net::HTTPSuccess) || resp.code.to_i == 404
        raise HttpError.new(resp.code.to_i, resp.body)
      end
      JSON.parse(resp.body) rescue { "ok" => resp.is_a?(Net::HTTPSuccess) }
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise TimeoutError, "timeout cancelling run: #{e.message}"
    rescue Errno::ECONNREFUSED, SocketError => e
      raise ConnectionError, "cannot reach freentonic at #{@base_url}: #{e.message}"
    end

    # Wipe freentonic's per-profile Chrome user-data directory. Used by
    # the "clear session" admin action so the operator can reset cookies
    # / device-trust / fingerprint markers and re-warm the profile by
    # interacting manually via VNC. freentonic serializes prune behind
    # the same invoke mutex, so a prune call blocks until any in-flight
    # scrape for this or any other profile finishes.
    #
    # Returns the JSON body freentonic returns: `{ "deleted": [...], "count": N }`.
    def prune_profile(profile_key, read_timeout: 30)
      uri = URI.join(@base_url + "/", "profiles/prune")
      http = new_http(uri, read_timeout: read_timeout)
      req  = Net::HTTP::Post.new(uri.request_uri)
      req["Content-Type"]  = "application/json"
      req["Authorization"] = "Bearer #{@invoke_token}"
      req.body = JSON.generate({ "profile_key" => profile_key })

      resp = http.request(req)
      unless resp.is_a?(Net::HTTPSuccess)
        raise HttpError.new(resp.code.to_i, resp.body)
      end
      JSON.parse(resp.body)
    rescue JSON::ParserError => e
      raise Error, "freentonic returned non-JSON body: #{e.message}"
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise TimeoutError, "timeout pruning profile: #{e.message}"
    rescue Errno::ECONNREFUSED, SocketError => e
      raise ConnectionError, "cannot reach freentonic at #{@base_url}: #{e.message}"
    end

    # Pull a run log from freentonic's `/runs/<run_id>/log` endpoint.
    # Returns [body_text, total_size, truncated?] or nil if freentonic
    # 404s for the run. Raises on other errors.
    #
    # We tail the last `max_bytes` of the log via a Range header so long
    # runs don't flood the admin UI's live-log panel.
    def fetch_run_log(run_id, max_bytes: 256 * 1024, read_timeout: 10)
      uri = URI.join(@base_url + "/", "runs/#{URI.encode_www_form_component(run_id)}/log")
      http = new_http(uri, read_timeout: read_timeout)
      req  = Net::HTTP::Get.new(uri.request_uri)
      req["Authorization"] = "Bearer #{@invoke_token}"
      # Ask for the last `max_bytes` bytes (suffix-range). freentonic's
      # log route supports this shape; on a miss it serves the whole
      # file, which we tail-trim on our side as a belt-and-suspenders.
      req["Range"] = "bytes=-#{max_bytes}"

      resp = http.request(req)
      return nil if resp.code.to_i == 404
      unless resp.is_a?(Net::HTTPSuccess) || resp.is_a?(Net::HTTPPartialContent)
        raise HttpError.new(resp.code.to_i, resp.body)
      end

      body = resp.body.to_s
      size = body.bytesize
      # If Content-Range came back, prefer its total size.
      if (cr = resp["Content-Range"]) && cr =~ /\/(\d+)\z/
        size = Regexp.last_match(1).to_i
      end
      truncated = size > body.bytesize || resp.is_a?(Net::HTTPPartialContent)
      [body, size, truncated]
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise TimeoutError, "timeout fetching run log: #{e.message}"
    rescue Errno::ECONNREFUSED, SocketError => e
      raise ConnectionError, "cannot reach freentonic at #{@base_url}: #{e.message}"
    end

    # Incrementally tail a run's log for the live admin panel. Fetches the
    # window starting at byte `offset` (bounded to `max_bytes`) with a
    # forward Range request and returns:
    #
    #   { chunk:, next_offset:, size: } — `chunk` is the new UTF-8 text
    #       written since `offset`; poll again with `next_offset` to pick up
    #       further growth. `size` is the log's current total byte length.
    #   nil                            — freentonic 404s for the run.
    #
    # Unlike #fetch_run_log (which re-pulls the whole suffix on every call),
    # this transfers only the bytes appended since the last poll, so a long
    # run streams cheaply. A trailing partial UTF-8 sequence is held back
    # (not counted in `next_offset`) so a multibyte character is never split
    # across two polls.
    def tail_run_log(run_id, offset:, max_bytes: 256 * 1024, read_timeout: 10)
      unless offset.is_a?(Integer) && offset >= 0
        raise ArgumentError, "offset must be a non-negative Integer, got #{offset.inspect}"
      end

      uri  = URI.join(@base_url + "/", "runs/#{URI.encode_www_form_component(run_id)}/log")
      http = new_http(uri, read_timeout: read_timeout)
      req  = Net::HTTP::Get.new(uri.request_uri)
      req["Authorization"] = "Bearer #{@invoke_token}"
      # Bounded forward window so a large backlog streams over several polls
      # rather than one giant transfer.
      req["Range"] = "bytes=#{offset}-#{offset + max_bytes - 1}"

      resp = http.request(req)
      code = resp.code.to_i
      return nil if code == 404

      # 416: `offset` is at/after EOF — nothing new yet. Hold the caller's
      # offset and report the current total (from `Content-Range: bytes */N`).
      if code == 416
        return { chunk: "", next_offset: offset, size: content_range_total(resp, offset) }
      end

      unless resp.is_a?(Net::HTTPSuccess) || resp.is_a?(Net::HTTPPartialContent)
        raise HttpError.new(code, resp.body)
      end

      raw = resp.body.to_s.b
      # Defensive: a bare 200 means the server ignored Range and sent the
      # whole file — slice to our window so we don't re-emit seen bytes.
      raw = (raw.byteslice(offset..-1) || "".b) if code == 200 && offset.positive?

      text, consumed = split_complete_utf8(raw)
      next_offset = offset + consumed
      { chunk: text, next_offset: next_offset, size: content_range_total(resp, next_offset) }
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise TimeoutError, "timeout tailing run log: #{e.message}"
    rescue Errno::ECONNREFUSED, SocketError => e
      raise ConnectionError, "cannot reach freentonic at #{@base_url}: #{e.message}"
    end

    # List the prompts a paused workflow is waiting on. freentonic exposes
    # one prompt at a time per run (the runner blocks on
    # RemotePromptStore#prompt) — we still return an array because that's
    # the wire shape and lets a future "queued multi-step approval" flow
    # ride the same endpoint without a contract change.
    #
    # Each entry: { "prompt_id", "kind" ("input"|"confirm"), "message",
    #               "mask", "created_at", "expires_at" }.
    # Returns nil if freentonic 404s for the run (not started, already
    # finished, or run_id outside its charset).
    def fetch_run_prompts(run_id, read_timeout: 10)
      uri  = URI.join(@base_url + "/", "runs/#{URI.encode_www_form_component(run_id)}/prompts")
      http = new_http(uri, read_timeout: read_timeout)
      req  = Net::HTTP::Get.new(uri.request_uri)
      req["Authorization"] = "Bearer #{@invoke_token}"

      resp = http.request(req)
      return nil if resp.code.to_i == 404
      unless resp.is_a?(Net::HTTPSuccess)
        raise HttpError.new(resp.code.to_i, resp.body)
      end
      body = JSON.parse(resp.body)
      Array(body["prompts"])
    rescue JSON::ParserError => e
      raise Error, "freentonic returned non-JSON body: #{e.message}"
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise TimeoutError, "timeout fetching run prompts: #{e.message}"
    rescue Errno::ECONNREFUSED, SocketError => e
      raise ConnectionError, "cannot reach freentonic at #{@base_url}: #{e.message}"
    end

    # Submit an answer to a paused prompt. `kind` mirrors what
    # fetch_run_prompts returned for the prompt; for "input" we ship
    # `{ "value": ... }`, for "confirm" we ship `{}`. The runner picks
    # up the response file on its next 250 ms poll and resumes the
    # workflow.
    #
    # Returns a small Hash so the admin proxy can branch without parsing
    # error strings:
    #   { ok: true,  status: 200 }
    #   { ok: false, status: 404|409|410|400, body: <freentonic body string> }
    # Anything else (5xx, malformed JSON, etc.) raises.
    def submit_prompt_answer(run_id, prompt_id, kind:, value: nil, read_timeout: 10)
      uri  = URI.join(
        @base_url + "/",
        "runs/#{URI.encode_www_form_component(run_id)}/prompts/#{URI.encode_www_form_component(prompt_id)}"
      )
      http = new_http(uri, read_timeout: read_timeout)
      req  = Net::HTTP::Post.new(uri.request_uri)
      req["Content-Type"]  = "application/json"
      req["Authorization"] = "Bearer #{@invoke_token}"
      req.body = JSON.generate(submit_prompt_body(kind, value))

      resp = http.request(req)
      status = resp.code.to_i
      if resp.is_a?(Net::HTTPSuccess)
        { ok: true, status: status }
      elsif [400, 404, 409, 410].include?(status)
        { ok: false, status: status, body: resp.body.to_s }
      else
        raise HttpError.new(status, resp.body)
      end
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise TimeoutError, "timeout submitting prompt answer: #{e.message}"
    rescue Errno::ECONNREFUSED, SocketError => e
      raise ConnectionError, "cannot reach freentonic at #{@base_url}: #{e.message}"
    end

    # Pull the raw.json freentonic wrote for an audit-mode run (invoked
    # with `through: "extract", dump_raw: true`). Returns the parsed
    # JSON Hash, or nil if freentonic 404s for the run (run wasn't an
    # audit invoke, or never finished extract). Raises on other errors.
    def fetch_run_raw(run_id, read_timeout: 30)
      uri  = URI.join(@base_url + "/", "runs/#{URI.encode_www_form_component(run_id)}/raw")
      http = new_http(uri, read_timeout: read_timeout)
      req  = Net::HTTP::Get.new(uri.request_uri)
      req["Authorization"] = "Bearer #{@invoke_token}"

      resp = http.request(req)
      return nil if resp.code.to_i == 404
      unless resp.is_a?(Net::HTTPSuccess)
        raise HttpError.new(resp.code.to_i, resp.body)
      end
      JSON.parse(resp.body)
    rescue JSON::ParserError => e
      raise Error, "freentonic returned non-JSON body: #{e.message}"
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise TimeoutError, "timeout fetching run raw: #{e.message}"
    rescue Errno::ECONNREFUSED, SocketError => e
      raise ConnectionError, "cannot reach freentonic at #{@base_url}: #{e.message}"
    end

    # Pull the recording.jsonl freentonic wrote for a recording-mode
    # run. Returns the raw body string (newline-delimited JSON), or nil
    # if the run has no recording (run wasn't in recording mode, or it
    # never produced any events). Caller is responsible for parsing the
    # JSONL — kept as a string here so the admin proxy can stream
    # straight through without round-tripping through Ruby objects.
    def fetch_run_recording(run_id, read_timeout: 10)
      uri  = URI.join(@base_url + "/", "runs/#{URI.encode_www_form_component(run_id)}/recording")
      http = new_http(uri, read_timeout: read_timeout)
      req  = Net::HTTP::Get.new(uri.request_uri)
      req["Authorization"] = "Bearer #{@invoke_token}"

      resp = http.request(req)
      return nil if resp.code.to_i == 404
      unless resp.is_a?(Net::HTTPSuccess)
        raise HttpError.new(resp.code.to_i, resp.body)
      end
      resp.body.to_s
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise TimeoutError, "timeout fetching run recording: #{e.message}"
    rescue Errno::ECONNREFUSED, SocketError => e
      raise ConnectionError, "cannot reach freentonic at #{@base_url}: #{e.message}"
    end

    private

    # Poll GET /runs/:id until the run reaches a terminal state, then map it
    # onto an InvokeResult (or raise). `deadline_sec` is a backstop over the
    # server's own watchdog: a healthy run reports `done` (with
    # error_kind:"timeout" if it was killed) well before this fires — this
    # only trips if the server goes silent after the 202.
    def poll_run(run_id, deadline_sec:)
      uri      = URI.join(@base_url + "/", "runs/#{URI.encode_www_form_component(run_id)}")
      deadline = @clock.call + deadline_sec
      failures = 0

      loop do
        if @clock.call >= deadline
          raise TimeoutError, "run #{run_id} did not reach a terminal state within #{deadline_sec}s"
        end

        resp = begin
          http = new_http(uri, read_timeout: @poll_read_timeout)
          get  = Net::HTTP::Get.new(uri.request_uri)
          get["Authorization"] = "Bearer #{@invoke_token}"
          http.request(get)
        rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, SocketError => e
          # A transient blip (server restart, momentary network loss). The run
          # may still be executing, so don't abandon it for a single miss —
          # tolerate a bounded burst, then give up.
          failures += 1
          if failures > MAX_POLL_FAILURES
            raise ConnectionError, "lost contact with freentonic while polling run #{run_id}: #{e.message}"
          end
          @sleeper.call(@poll_interval)
          next
        end
        failures = 0

        code = resp.code.to_i
        if code == 404
          # Never registered, run_id charset-rejected, or evicted from the
          # retention window. Either way there's no result to wait for.
          raise Error, "run #{run_id} is unknown or was evicted from freentonic's retention window"
        end
        raise HttpError.new(code, resp.body) unless resp.is_a?(Net::HTTPSuccess)

        run = parse_json!(resp.body)
        case run["status"]
        when "queued", "running"
          @sleeper.call(@poll_interval)
          next
        when "done"
          return build_invoke_result(run)
        when "error"
          raise Error, "freentonic run #{run_id} failed: #{run["error"]}"
        when "cancelled"
          raise CancelledError, "freentonic run #{run_id} was cancelled before it started"
        else
          raise Error, "freentonic returned unknown run status #{run["status"].inspect} for #{run_id}"
        end
      end
    end

    # Map a `done` (or legacy inline) run body onto an InvokeResult.
    def build_invoke_result(parsed)
      InvokeResult.new(
        run_id:      parsed["run_id"],
        status:      parsed["status"] || "done",
        exit_code:   parsed["exit_code"],
        error_kind:  parsed["error_kind"],
        duration_ms: parsed["duration_ms"],
        artifacts:   parsed["artifacts"] || [],
        log_path:    parsed["log_path"],
        warnings:    parsed["warnings"]  || []
      )
    end

    def parse_json!(body)
      JSON.parse(body)
    rescue JSON::ParserError => e
      raise Error, "freentonic returned non-JSON body: #{e.message}"
    end

    # Total file length from a `Content-Range: bytes <a>-<b>/<total>` (or the
    # `bytes */<total>` form a 416 carries). Falls back to `default` when the
    # header is missing or malformed.
    def content_range_total(resp, default)
      cr = resp["Content-Range"]
      (cr && cr =~ %r{/(\d+)\z}) ? Regexp.last_match(1).to_i : default
    end

    # Split a raw byte buffer into [valid_utf8_string, bytes_consumed],
    # holding back a trailing incomplete multibyte sequence (≤3 bytes) so a
    # character is never split across chunk boundaries — the held bytes come
    # back on the next poll once completed. Genuinely invalid bytes earlier
    # in the buffer are scrubbed rather than held forever.
    def split_complete_utf8(bytes)
      whole = bytes.dup.force_encoding("UTF-8")
      return [whole, bytes.bytesize] if whole.valid_encoding?

      1.upto(3) do |back|
        break if back >= bytes.bytesize
        head = bytes.byteslice(0, bytes.bytesize - back).force_encoding("UTF-8")
        return [head, bytes.bytesize - back] if head.valid_encoding?
      end
      [whole.scrub(""), bytes.bytesize]
    end

    def get_json(uri, read_timeout:, require_auth: true)
      http = new_http(uri, read_timeout: read_timeout)
      req  = Net::HTTP::Get.new(uri.request_uri)
      req["Authorization"] = "Bearer #{@invoke_token}" if require_auth
      resp = http.request(req)
      unless resp.is_a?(Net::HTTPSuccess)
        raise HttpError.new(resp.code.to_i, resp.body)
      end
      JSON.parse(resp.body)
    rescue JSON::ParserError => e
      raise Error, "freentonic returned non-JSON body: #{e.message}"
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise TimeoutError, e.message
    rescue Errno::ECONNREFUSED, SocketError => e
      raise ConnectionError, "cannot reach freentonic at #{@base_url}: #{e.message}"
    end

    def new_http(uri, read_timeout:)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = @open_timeout
      http.read_timeout = read_timeout
      http
    end

    # Build the POST body for submit_prompt_answer. Caller-supplied `kind`
    # is whatever fetch_run_prompts handed back; we route on it here rather
    # than in the public method body so the latter stays a thin wrapper
    # around the HTTP exchange.
    def submit_prompt_body(kind, value)
      case kind.to_s
      when "input"
        unless value.is_a?(String) && !value.empty?
          raise ArgumentError, "submit_prompt_answer: value must be a non-empty string for input prompts"
        end
        { "value" => value }
      when "confirm", "await"
        # No payload — the freentonic side keys off the stored request kind
        # and just records a confirmation. `await` is the fallback button on a
        # self-resolving wait prompt.
        {}
      else
        raise ArgumentError, "submit_prompt_answer: unknown kind #{kind.inspect}"
      end
    end
  end
end
