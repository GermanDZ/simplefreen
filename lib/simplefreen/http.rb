# frozen_string_literal: true

require "json"
require "base64"

require_relative "crypto"

module Simplefreen
  # Minimal HTTP response helpers shared by the protocol / admin API /
  # admin UI handlers. The parent InvokeServer already owns the socket
  # and the basic request parse; this module just produces bytes.
  module Http
    STATUS_REASONS = {
      200 => "OK",
      301 => "Moved Permanently",
      302 => "Found",
      303 => "See Other",
      400 => "Bad Request",
      401 => "Unauthorized",
      403 => "Forbidden",
      404 => "Not Found",
      405 => "Method Not Allowed",
      409 => "Conflict",
      410 => "Gone",
      422 => "Unprocessable Entity",
      429 => "Too Many Requests",
      500 => "Internal Server Error",
      503 => "Service Unavailable"
    }.freeze

    SECURITY_HEADERS = {
      "Cache-Control"           => "no-store",
      "X-Content-Type-Options"  => "nosniff",
      "X-Frame-Options"         => "DENY",
      "Referrer-Policy"         => "no-referrer",
      "Content-Security-Policy" => "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; script-src 'self'; base-uri 'none'; frame-ancestors 'none'"
    }.freeze

    module_function

    def write(client, status:, body:, headers: {})
      reason = STATUS_REASONS[status] || "Status"
      body = body.to_s
      final_headers = {
        "Content-Type"   => "text/plain; charset=utf-8",
        "Content-Length" => body.bytesize.to_s,
        "Connection"     => "close"
      }.merge(SECURITY_HEADERS).merge(headers)
      head = +"HTTP/1.1 #{status} #{reason}\r\n"
      final_headers.each { |k, v| head << "#{k}: #{v}\r\n" }
      head << "\r\n"
      client.write(head)
      client.write(body) unless body.empty?
    rescue Errno::EPIPE, Errno::ECONNRESET
      nil
    end

    def write_json(client, status, hash, headers: {})
      write(client, status: status, body: JSON.generate(hash),
            headers: headers.merge("Content-Type" => "application/json"))
    end

    def write_plain(client, status, text, headers: {})
      write(client, status: status, body: text, headers: headers)
    end

    def write_html(client, status, html, headers: {})
      write(client, status: status, body: html,
            headers: headers.merge("Content-Type" => "text/html; charset=utf-8"))
    end

    def write_redirect(client, location, status: 303, headers: {})
      write(client, status: status, body: "",
            headers: headers.merge("Location" => location, "Content-Type" => "text/plain"))
    end

    # Serve a binary blob (e.g. a screenshot). Caller supplies the
    # Content-Type and the body bytes. Bypasses the default
    # Cache-Control: no-store from SECURITY_HEADERS so the browser can
    # cache immutable per-run artifacts; per-run paths include the
    # run_id so cache invalidation is implicit.
    def write_binary(client, status, content_type, bytes, headers: {})
      write(client, status: status, body: bytes,
            headers: headers.merge(
              "Content-Type"  => content_type,
              "Cache-Control" => "private, max-age=300, immutable"
            ))
    end

    # Parse an HTTP Basic auth header. Returns [user, password] or nil.
    def parse_basic_auth(header)
      return nil unless header.is_a?(String)
      return nil unless header =~ /\ABasic\s+(\S+)\z/i
      decoded = Base64.strict_decode64(Regexp.last_match(1).strip) rescue nil
      return nil unless decoded
      user, password = decoded.split(":", 2)
      return nil unless user && password
      [user, password]
    end

    # Simple form-urlencoded body parser. Returns a Hash with string keys.
    def parse_form(body)
      body = body.to_s
      params = {}
      body.split("&").each do |pair|
        k, v = pair.split("=", 2)
        next if k.nil? || k.empty?
        params[url_decode(k)] = url_decode(v.to_s)
      end
      params
    end

    def url_decode(str)
      str.tr("+", " ").gsub(/%([0-9a-fA-F]{2})/) { [Regexp.last_match(1)].pack("H*") }
    end

    # Parse the query string off a path; returns [pathname, params_hash].
    def split_query(path)
      pn, qs = path.split("?", 2)
      [pn, qs ? parse_form(qs) : {}]
    end

    # Bearer auth check against a fixed secret. Constant-time.
    def bearer_token(header)
      return nil unless header.is_a?(String)
      return nil unless header =~ /\ABearer\s+(\S+)/
      Regexp.last_match(1)
    end
  end
end
