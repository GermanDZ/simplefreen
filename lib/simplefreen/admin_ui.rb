# frozen_string_literal: true

require "digest"
require "securerandom"
require "time"

require_relative "crypto"
require_relative "http"

module Simplefreen
  # Cookie-session admin UI. One password (the bearer token used by the
  # admin API). On login we mint a random cookie value that we store as a
  # PBKDF2 hash in memory keyed by its cookie value — the password never
  # touches the wire after login.
  #
  # Sessions are in-memory, so a restart logs everyone out (fine for a
  # single-tenant self-hosted deployment).
  class AdminUi
    SESSION_COOKIE  = "freentonic_simplefin_session"
    SESSION_TTL_SEC = 24 * 3600

    # Login brute-force throttle. The admin surface is internet-reachable
    # via the edge proxy, and a single password gates everything, so after
    # too many failures in a window we lock the login endpoint for a short
    # cooldown. A global (not per-IP) lock is fine for a single-operator
    # deployment and — unlike a per-request sleep — holds no connections,
    # so it can't be turned into a slot-exhaustion lever.
    LOGIN_MAX_FAILURES = 10
    LOGIN_WINDOW_SEC   = 300
    LOGIN_LOCKOUT_SEC  = 60

    def initialize(feature:, asset_dir:)
      @feature    = feature
      @asset_dir  = asset_dir
      @sessions   = {}
      @session_mu = Mutex.new
      @login_fails        = 0
      @login_window_start = 0
      @login_locked_until = 0
    end

    def dispatch(client, method, path, request)
      pathname, _params = Http.split_query(path)

      case
      when pathname == "/admin/login" && method == "GET"
        # Static asset — the page reads ?e=1 inline to surface the
        # "incorrect password" banner without server-side templating.
        serve_login(client)
      when pathname == "/admin/login" && method == "POST"
        handle_login(client, request)
      when pathname == "/admin/logout" && method == "POST"
        handle_logout(client, request)
      when pathname == "/admin" || pathname == "/admin/"
        return serve_login(client) unless authenticated?(request)
        serve_asset(client, "index.html")
      when pathname.start_with?("/admin/assets/")
        rel = pathname.sub(%r{\A/admin/assets/}, "")
        # The login page's CSS lives under /admin/assets, so the
        # asset routes for tokens.css + styles.css must be reachable
        # unauthenticated. Everything else still requires a session.
        return serve_asset(client, rel) if public_asset?(rel)
        return serve_login(client) unless authenticated?(request)
        serve_asset(client, rel)
      else
        Http.write_json(client, 404, { "error" => "not found" })
      end
    end

    # API-style handler: accepts Bearer admin password OR a valid session
    # cookie. Used by the /admin/api/* endpoints as a fallback so the UI
    # can call them with cookie auth without having to restore the
    # password on every page load.
    def session_authenticated?(request)
      authenticated?(request)
    end

    private

    # Login HTML and the assets it imports are public; everything
    # else under /admin/assets requires authentication.
    PUBLIC_LOGIN_ASSETS = %w[styles.css lib/tokens.css lib/boot.js favicon.svg].freeze

    def public_asset?(rel)
      PUBLIC_LOGIN_ASSETS.include?(rel)
    end

    def serve_login(client)
      serve_asset(client, "login.html")
    end

    def handle_login(client, request)
      if login_locked?
        return Http.write_json(client, 429,
          { "error" => "too many failed login attempts; try again shortly" },
          headers: { "Retry-After" => LOGIN_LOCKOUT_SEC.to_s })
      end
      form = Http.parse_form(request.body)
      password = form["password"].to_s
      if Crypto.secure_compare(password, @feature.admin_password) && !password.empty?
        note_login_success
        cookie_value = mint_session
        Http.write_redirect(client, "/admin/", status: 303,
          headers: {
            "Set-Cookie" => build_cookie(cookie_value)
          })
      else
        note_login_failure
        Http.write_redirect(client, "/admin/login?e=1", status: 303)
      end
    end

    def login_locked?
      @session_mu.synchronize { Time.now.to_i < @login_locked_until }
    end

    def note_login_failure
      @session_mu.synchronize do
        now = Time.now.to_i
        # Fresh window if the previous one elapsed (or this is the first fail).
        if @login_fails.zero? || (now - @login_window_start) > LOGIN_WINDOW_SEC
          @login_fails = 0
          @login_window_start = now
        end
        @login_fails += 1
        if @login_fails >= LOGIN_MAX_FAILURES
          @login_locked_until = now + LOGIN_LOCKOUT_SEC
          @login_fails = 0
          @feature.log("admin login locked for #{LOGIN_LOCKOUT_SEC}s after #{LOGIN_MAX_FAILURES} failures")
        end
      end
    end

    def note_login_success
      @session_mu.synchronize do
        @login_fails = 0
        @login_locked_until = 0
      end
    end

    def handle_logout(client, request)
      cookie = cookie_value_from(request)
      @session_mu.synchronize { @sessions.delete(cookie) if cookie }
      Http.write_redirect(client, "/admin/login", status: 303,
        headers: { "Set-Cookie" => build_cookie("", max_age: 0) })
    end

    def mint_session
      token = Crypto.random_token(bytes: 32)
      @session_mu.synchronize do
        @sessions[token] = Time.now.to_i + SESSION_TTL_SEC
      end
      expire_stale
      token
    end

    def expire_stale
      now = Time.now.to_i
      @session_mu.synchronize do
        @sessions.delete_if { |_, expiry| expiry < now }
      end
    end

    def authenticated?(request)
      return true if bearer_ok?(request)
      cookie = cookie_value_from(request)
      return false if cookie.nil? || cookie.empty?
      @session_mu.synchronize do
        expiry = @sessions[cookie]
        return false if expiry.nil?
        return false if expiry < Time.now.to_i
        true
      end
    end

    def bearer_ok?(request)
      token = Http.bearer_token(request.headers["authorization"])
      return false unless token
      Crypto.secure_compare(token, @feature.admin_password)
    end

    def cookie_value_from(request)
      raw = request.headers["cookie"]
      return nil unless raw.is_a?(String)
      raw.split(/;\s*/).each do |pair|
        k, v = pair.split("=", 2)
        return v if k == SESSION_COOKIE
      end
      nil
    end

    def build_cookie(value, max_age: SESSION_TTL_SEC)
      attrs = [
        "#{SESSION_COOKIE}=#{value}",
        "Path=/",
        "HttpOnly",
        # The edge proxy terminates TLS, so the browser always sees an
        # HTTPS origin — mark the cookie Secure so it is never transmitted
        # over a plaintext hop even if one is accidentally introduced.
        "Secure",
        "SameSite=Strict",
        "Max-Age=#{max_age}"
      ]
      attrs.join("; ")
    end

    ASSET_MIME = {
      ".html" => "text/html; charset=utf-8",
      ".js"   => "application/javascript; charset=utf-8",
      ".css"  => "text/css; charset=utf-8",
      ".svg"  => "image/svg+xml"
    }.freeze

    # Serve a file from the bundled UI directory. Traversal-safe: the
    # resolved path must be a real file under the asset root.
    def serve_asset(client, rel)
      return not_found(client) if rel.include?("\0")
      candidate = File.expand_path(File.join(@asset_dir, rel))
      unless candidate.start_with?(File.expand_path(@asset_dir) + File::SEPARATOR) || candidate == File.expand_path(@asset_dir)
        return not_found(client)
      end
      return not_found(client) unless File.file?(candidate)

      body = File.binread(candidate)
      ext  = File.extname(candidate).downcase
      mime = ASSET_MIME[ext] || "application/octet-stream"
      # No build pipeline → no content-hashed filenames. Tell the
      # browser to revalidate on every request so a deploy-side asset
      # change lands without a hard refresh. ETag would be tidier but
      # this server doesn't speak conditional requests yet; no-cache
      # is the safe default.
      Http.write(client, status: 200, body: body, headers: {
        "Content-Type"  => mime,
        "Cache-Control" => "no-cache, must-revalidate"
      })
    end

    def not_found(client)
      Http.write(client, status: 404, body: "not found")
    end
  end
end
