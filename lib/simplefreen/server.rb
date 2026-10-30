# frozen_string_literal: true

require "socket"
require "json"
require "time"

require_relative "http"
require_relative "profile_health"

module Simplefreen
  # Minimal HTTP/1.1 server built on stdlib TCPServer — mirrors
  # freentonic's invoke_server.rb shape but trimmed down to just the
  # routes simplefreen needs. No /invoke, no /runs log streaming, no
  # Range handling.
  #
  # Dispatch hands everything off to a `router` (Simplefreen::Router).
  # The only route served directly here is /healthz — cheap liveness
  # probe so upstream monitors don't have to talk to the auth-protected
  # admin API.
  class Server
    DEFAULT_ADDR = "0.0.0.0"
    DEFAULT_PORT = 7878

    # Default 64 MiB, granted ONLY to a freentonic push that presents a
    # live push token for its run (see #body_limit_for): a full-history
    # scrape (~10 years, thousands of transactions across multiple banks)
    # can run several MiB once canonical-shaped. Override with
    # SIMPLEFREEN_MAX_BODY_MB.
    MAX_BODY_BYTES = (Integer(ENV["SIMPLEFREEN_MAX_BODY_MB"] || 64)) * 1024 * 1024
    # Every other request is buffered before any auth check runs, so it
    # gets a small cap. Admin JSON bodies and the login form are a few KiB.
    MAX_PREAUTH_BODY_BYTES = 1024 * 1024
    MAX_HEADER_BYTES = 16 * 1024
    READ_TIMEOUT     = 30

    MAX_CONCURRENT_CONNECTIONS = 64

    STATUS_REASONS = {
      200 => "OK",
      400 => "Bad Request",
      401 => "Unauthorized",
      404 => "Not Found",
      405 => "Method Not Allowed",
      413 => "Payload Too Large",
      422 => "Unprocessable Entity",
      500 => "Internal Server Error",
      503 => "Service Unavailable"
    }.freeze

    def initialize(
      router:,
      listen_addr:   DEFAULT_ADDR,
      listen_port:   DEFAULT_PORT,
      logger:        $stdout,
      max_concurrent_connections: MAX_CONCURRENT_CONNECTIONS
    )
      @router          = router
      @listen_addr     = listen_addr
      @listen_port     = listen_port
      @logger          = logger

      @shutting_down      = false
      @server_socket      = nil
      @connection_mutex   = Mutex.new
      @active_connections = 0
      @max_connections    = max_concurrent_connections
    end

    def start
      @server_socket = TCPServer.new(@listen_addr, @listen_port)
      log "listening on http://#{@listen_addr}:#{@listen_port}"

      loop do
        break if @shutting_down
        begin
          client = @server_socket.accept
        rescue IOError, Errno::EBADF, Errno::EINVAL, Errno::ENOTSOCK
          break
        end

        admitted = @connection_mutex.synchronize do
          if @active_connections >= @max_connections
            false
          else
            @active_connections += 1
            true
          end
        end

        if admitted
          Thread.new(client) do |c|
            begin
              handle_connection(c)
            ensure
              @connection_mutex.synchronize { @active_connections -= 1 }
            end
          end
        else
          refuse_over_capacity(client)
        end
      end
    ensure
      @server_socket&.close rescue nil
    end

    # Safe to call from a signal handler (or a thread spawned from
    # one). Calls shutdown(SHUT_RDWR) on the listen socket BEFORE
    # close — on macOS, just calling close() while another thread is
    # in accept(2) doesn't reliably wake accept; a half-close does.
    # The accept loop then catches the resulting error and exits.
    def shutdown
      @shutting_down = true
      begin
        @server_socket&.shutdown(Socket::SHUT_RDWR)
      rescue StandardError
        # Already closed, never connected, or kernel disagrees —
        # fall through to close anyway.
      end
      @server_socket&.close rescue nil
    end

    def shutting_down?
      @shutting_down
    end

    def active_connection_count
      @connection_mutex.synchronize { @active_connections }
    end

    private

    # ─── HTTP wire protocol ───

    def refuse_over_capacity(client)
      client.sync = true
      client.write(
        "HTTP/1.1 503 Service Unavailable\r\n" \
        "Content-Type: application/json\r\n" \
        "Content-Length: 0\r\n" \
        "Retry-After: 1\r\n" \
        "Connection: close\r\n" \
        "\r\n"
      )
      begin
        client.shutdown(Socket::SHUT_WR)
      rescue StandardError
        # ok
      end
      deadline = Time.now + 0.5
      while Time.now < deadline
        ready = IO.select([client], nil, nil, 0.1)
        break unless ready
        begin
          chunk = client.read_nonblock(4096)
          break if chunk.nil? || chunk.empty?
        rescue IO::WaitReadable, EOFError, Errno::ECONNRESET, StandardError
          break
        end
      end
    rescue StandardError
      # client gave up / network blip — not our problem
    ensure
      client.close rescue nil
    end

    def handle_connection(client)
      client.sync = true
      begin
        request = read_request(client)
      rescue RequestTooLarge
        write_response(client, 413, { "error" => "payload too large" })
        return
      rescue RequestMalformed => e
        write_response(client, 400, { "error" => "malformed request: #{e.message}" })
        return
      rescue IOError, Errno::EPIPE, Errno::ECONNRESET, Errno::ETIMEDOUT
        return
      end
      return unless request

      path = request.path.split("?", 2).first

      # /healthz is the only route we answer directly. Everything else
      # goes through the router, which owns /simplefin/*, /admin/*, /push/*.
      if path == "/healthz"
        return handle_healthz(client, request)
      end

      # Convenience redirects for bare hostnames: bouncing `/` to the
      # admin UI saves a hand-typed `/admin/` path. The favicon
      # request is what every browser auto-fires; serve a 204 so the
      # network panel stops complaining (the real icon is declared
      # via <link rel="icon"> inside the admin pages themselves).
      if path == "/" && request.method == "GET"
        return Http.write_redirect(client, "/admin/", status: 302)
      end
      if path == "/favicon.ico"
        return Http.write(client, status: 204, body: "")
      end

      outcome = @router.dispatch(client, request)
      if outcome != :handled
        write_response(client, 404, { "error" => "not found" })
      end
    rescue StandardError => e
      log_exception("connection", e)
      begin
        write_response(client, 500, { "error" => "internal server error" })
      rescue StandardError
        nil
      end
    ensure
      client.close rescue nil
    end

    class RequestMalformed < StandardError; end
    class RequestTooLarge  < StandardError; end

    Request = Struct.new(:method, :path, :headers, :body, keyword_init: true)

    class BufferedReader
      MAX_LINE_BYTES = 16 * 1024

      def initialize(io, timeout)
        @io      = io
        @timeout = timeout
        @buffer  = String.new.force_encoding(Encoding::BINARY)
      end

      def readline_crlf
        loop do
          if (idx = @buffer.index("\r\n"))
            line = @buffer.byteslice(0, idx + 2)
            @buffer = @buffer.byteslice(idx + 2, @buffer.bytesize - (idx + 2)) || "".b
            return line
          end
          raise RequestMalformed, "line too long" if @buffer.bytesize > MAX_LINE_BYTES
          return nil unless fill_buffer
        end
      end

      def read_exactly(n)
        while @buffer.bytesize < n
          fill_buffer or raise RequestMalformed, "unexpected EOF in body"
        end
        result  = @buffer.byteslice(0, n)
        @buffer = @buffer.byteslice(n, @buffer.bytesize - n) || "".b
        result
      end

      private

      def fill_buffer
        loop do
          ready = IO.select([@io], nil, nil, @timeout)
          raise RequestMalformed, "read timeout" unless ready
          chunk = @io.read_nonblock(4096, exception: false)
          case chunk
          when :wait_readable
            next
          when nil
            return false # EOF
          else
            @buffer << chunk.b
            return true
          end
        end
      end
    end

    def read_request(client)
      reader = BufferedReader.new(client, READ_TIMEOUT)
      line = reader.readline_crlf
      return nil if line.nil?
      unless line =~ /\A([A-Z]+) (\S+) HTTP\/1\.[01]\r\n\z/
        raise RequestMalformed, "invalid request line"
      end
      method = Regexp.last_match(1)
      path   = Regexp.last_match(2)

      headers = {}
      header_bytes = line.bytesize
      loop do
        header_line = reader.readline_crlf or raise RequestMalformed, "unexpected EOF in headers"
        header_bytes += header_line.bytesize
        raise RequestMalformed, "headers too large" if header_bytes > MAX_HEADER_BYTES
        break if header_line == "\r\n"
        unless header_line =~ /\A([^:]+):\s*(.*?)\r\n\z/
          raise RequestMalformed, "invalid header line"
        end
        headers[Regexp.last_match(1).downcase] = Regexp.last_match(2)
      end

      # Reject chunked — same reasoning as freentonic's invoke_server:
      # silent fallback to Content-Length would be a request-smuggling
      # shape if a proxy in front of us disagreed on framing.
      if (te = headers["transfer-encoding"]) && !te.strip.empty?
        raise RequestMalformed, "Transfer-Encoding not supported"
      end

      length = parse_content_length(headers["content-length"])
      raise RequestTooLarge if length > body_limit_for(method, path, headers)

      body = length.positive? ? reader.read_exactly(length) : ""
      Request.new(method: method, path: path, headers: headers, body: body)
    end

    # Decided from the request line + headers alone, before any body bytes
    # are buffered, so an unauthenticated client can't make us hold
    # MAX_BODY_BYTES per connection. The token is only checked here, not
    # consumed — PushReceiver still burns it before accepting the payload.
    def body_limit_for(method, path, headers)
      return MAX_PREAUTH_BODY_BYTES unless method == "POST"
      match = path.split("?", 2).first.match(%r{\A/push/([^/]+)\z})
      return MAX_PREAUTH_BODY_BYTES unless match

      token  = Http.bearer_token(headers["authorization"])
      tokens = @router.respond_to?(:feature) ? @router.feature&.push_tokens : nil
      return MAX_PREAUTH_BODY_BYTES unless token && tokens&.valid?(match[1], token)

      MAX_BODY_BYTES
    end

    def parse_content_length(raw)
      return 0 if raw.nil? || raw.strip.empty?
      unless raw.strip =~ /\A\d+\z/
        raise RequestMalformed, "invalid Content-Length: #{raw.inspect}"
      end
      raw.strip.to_i
    end

    def write_response(client, status, body_hash)
      body = JSON.generate(body_hash)
      reason = STATUS_REASONS[status] || "Status"
      client.write(
        "HTTP/1.1 #{status} #{reason}\r\n" \
        "Content-Type: application/json\r\n" \
        "Content-Length: #{body.bytesize}\r\n" \
        "Connection: close\r\n" \
        "\r\n" \
        "#{body}"
      )
    rescue Errno::EPIPE, Errno::ECONNRESET
      nil
    end

    # ─── routes handled directly ───

    def handle_healthz(client, _request)
      feature = @router.feature
      scheduler = feature&.scheduler
      # No scheduler installed (e.g. a stripped test harness) → don't claim
      # a worker is dead. Otherwise reflect the real thread liveness.
      worker_alive = scheduler.nil? || scheduler.worker_alive?
      # Status stays 200 as long as the process serves requests — /accounts
      # reads history/cache and does NOT need the worker, and kamal-proxy
      # gates deploys on the status code, so we must not 503 a still-serving
      # container. The body's `ok` carries the real health so a body-aware
      # uptime monitor (keyword match on `"ok":true`) catches a dead worker.
      payload = {
        "ok"                     => !@shutting_down && worker_alive,
        "shutting_down"          => @shutting_down,
        "scheduler_worker_alive" => worker_alive,
        # Configured-to-sync profiles whose last SUCCESS is overdue. Purely
        # informational — staleness does NOT flip `ok` to false (the serving
        # path still works), but exposing the count lets a body-aware uptime
        # monitor alarm on a quietly-wedged sync without scraping the
        # bearer-gated /admin/api/metrics.
        "stale_profiles"         => stale_profile_count(feature)
      }
      if (health = feature&.freentonic_health)
        payload["freentonic"] = health.snapshot
      end
      write_response(client, 200, payload)
    end

    # Count configured-to-sync profiles whose last SUCCESS is overdue. Kept
    # cheap (a handful of small JSON reads) and fully guarded — /healthz is on
    # the kamal-proxy deploy-gate path and must never raise. Returns nil if
    # the feature/stores aren't reachable so callers can tell "0 stale" from
    # "couldn't compute."
    def stale_profile_count(feature)
      return nil unless feature
      now = Time.now
      feature.profile_store.list.count do |profile|
        next false if profile["kind"] == "virtual"
        state = feature.state_store.read(profile["profile_key"])
        ProfileHealth.stale?(profile, state, now)
      end
    rescue StandardError => e
      log("healthz stale-count failed: #{e.class}: #{e.message}")
      nil
    end

    def log(msg)
      return unless @logger
      @logger.puts("[simplefreen] #{msg}")
      @logger.flush if @logger.respond_to?(:flush)
    end

    def log_exception(context, error)
      log("error in #{context}: #{error.class}: #{error.message}")
      error.backtrace&.first(12)&.each { |line| log("  #{line}") }
    end
  end
end
