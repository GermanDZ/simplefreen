# frozen_string_literal: true

require "net/http"
require "uri"

module Simplefreen
  # Push-notification delivery via ntfy (ntfy.sh or a self-hosted instance).
  # One plain Net::HTTP POST per alert — zero gems, reaches a phone. The
  # Watchdog owns *when* to notify; this class owns only *how* to deliver.
  #
  # Config (all via ENV, read by .from_env):
  #   SIMPLEFREEN_NTFY_URL   — full topic URL, e.g.
  #                            https://ntfy.sh/simplefreen-alerts-<random>
  #                            (unset ⇒ notifier is unconfigured, notify no-ops)
  #   SIMPLEFREEN_NTFY_TOKEN — optional bearer token for a protected topic /
  #                            self-hosted ntfy with auth
  #
  # ntfy maps a handful of request headers onto the notification: `Title` is
  # the bold heading, `Priority` is 1 (min) … 5 (max), and `Tags` is a
  # comma-separated list where known names (warning, x, hourglass, …) render
  # as emoji. The POST body is the message text.
  class Notifier
    URL_ENV   = "SIMPLEFREEN_NTFY_URL"
    TOKEN_ENV = "SIMPLEFREEN_NTFY_TOKEN"

    DEFAULT_OPEN_TIMEOUT = 5
    DEFAULT_READ_TIMEOUT = 5

    attr_reader :url

    def initialize(url:, token: nil, open_timeout: DEFAULT_OPEN_TIMEOUT,
                   read_timeout: DEFAULT_READ_TIMEOUT, logger: nil)
      raw = url.to_s.strip
      @url = raw.empty? ? nil : raw
      @uri = parse_uri(@url)
      tok = token.to_s.strip
      @token = tok.empty? ? nil : tok
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @logger = logger || ->(_msg) {}
    end

    # Build from ENV. Always returns a Notifier — an unconfigured one when
    # SIMPLEFREEN_NTFY_URL is unset, so callers never have to nil-check.
    def self.from_env(logger: nil)
      new(url: ENV[URL_ENV], token: ENV[TOKEN_ENV], logger: logger)
    end

    # True once a usable http(s) topic URL is present. The Watchdog skips its
    # whole loop when this is false — no point computing alerts nothing can
    # deliver.
    def configured?
      !@uri.nil?
    end

    # Best-effort delivery. Returns true on a 2xx, false otherwise (including
    # when unconfigured or on any transport error). NEVER raises — an alerting
    # path that could crash the caller would be worse than no alerting at all.
    def notify(title:, message:, priority: nil, tags: nil)
      return false unless configured?

      req = Net::HTTP::Post.new(@uri.request_uri)
      req.body = message.to_s
      req["Title"] = header_line(title) if title
      req["Priority"] = priority.to_s if priority
      taglist = Array(tags).map(&:to_s).reject(&:empty?)
      req["Tags"] = taglist.join(",") unless taglist.empty?
      req["Authorization"] = "Bearer #{@token}" if @token

      http = Net::HTTP.new(@uri.host, @uri.port)
      http.use_ssl = (@uri.scheme == "https")
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout

      resp = http.request(req)
      ok = resp.is_a?(Net::HTTPSuccess)
      log("ntfy POST returned HTTP #{resp.code}") unless ok
      ok
    rescue StandardError => e
      log("ntfy delivery failed: #{e.class}: #{e.message}")
      false
    end

    private

    def parse_uri(url)
      return nil if url.nil?
      uri = URI.parse(url)
      return nil unless uri.is_a?(URI::HTTP) && uri.host
      uri
    rescue URI::InvalidURIError
      nil
    end

    # HTTP header values must be a single line; strip CR/LF so a title
    # carrying an error message can't smuggle in header injection or a broken
    # request. ntfy decodes the Title header as UTF-8, so non-ASCII is fine.
    def header_line(value)
      value.to_s.gsub(/[\r\n]+/, " ").strip
    end

    def log(msg)
      @logger.call("[simplefreen] #{msg}")
    end
  end
end
