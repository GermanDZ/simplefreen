# frozen_string_literal: true

require_relative "admin_api"
require_relative "admin_ui"
require_relative "http"
require_relative "protocol"
require_relative "push_receiver"

module Simplefreen
  # Top-level path dispatcher for the full simplefreen HTTP surface.
  # Returns :handled when it wrote the response; :not_handled when the
  # path doesn't belong here (caller can fall through to /healthz or 404).
  class Router
    attr_reader :feature

    def initialize(feature:, workflows_dir:, asset_dir:)
      @feature        = feature
      @protocol       = Protocol.new(feature: feature)
      @admin_api      = AdminApi.new(feature: feature, workflows_dir: workflows_dir)
      @admin_ui       = AdminUi.new(feature: feature, asset_dir: asset_dir)
      @push_receiver  = PushReceiver.new(feature: feature)
    end

    # `request` is the Server::Request struct.
    # Returns :handled if the response was written; :not_handled otherwise.
    def dispatch(client, request)
      path = request.path
      pathname = path.split("?", 2).first

      if pathname.start_with?("/simplefin/")
        @protocol.dispatch(client, request.method, path, request)
        return :handled
      end

      if pathname.start_with?("/push/")
        @push_receiver.dispatch(client, request.method, path, request)
        return :handled
      end

      if pathname.start_with?("/admin/api/")
        return :handled if handle_admin_api(client, request, path)
      end

      if pathname == "/admin" || pathname == "/admin/" || pathname.start_with?("/admin/")
        @admin_ui.dispatch(client, request.method, path, request)
        return :handled
      end

      :not_handled
    end

    private

    def handle_admin_api(client, request, path)
      # The admin API accepts Bearer admin_password (tests / scripting)
      # OR a valid session cookie (browser UI). We add the cookie path by
      # injecting a synthetic Authorization header when the cookie is
      # valid — keeps AdminApi's auth check simple.
      cookie_auth = @admin_ui.session_authenticated?(request) && !request.headers["authorization"]
      if cookie_auth
        # CSRF defense. `SameSite=Strict` alone is not enough here: under the
        # `*.example.com` wildcard, any sibling subdomain is same-site, and
        # several mutating endpoints accept empty/simple bodies that dodge the
        # CORS preflight. So a cookie-authenticated MUTATION must additionally
        # prove same-origin via Origin/Referer. Real Bearer clients (scripts,
        # tests) are exempt — an attacker can't forge the bearer to begin with.
        if mutating?(request.method) && !same_origin?(request)
          @feature.log("admin api CSRF refused: method=#{request.method} " \
            "origin=#{request.headers["origin"].inspect}")
          Http.write_json(client, 403, { "error" => "cross-origin request refused" })
          return true
        end
        request.headers["authorization"] = "Bearer #{@feature.admin_password}"
      end
      @admin_api.dispatch(client, request.method, path, request)
      true
    end

    MUTATING_METHODS = %w[POST PUT PATCH DELETE].freeze

    def mutating?(method)
      MUTATING_METHODS.include?(method)
    end

    # A browser sets Origin on every non-GET fetch, so for a mutation we can
    # require it to match our own public URL (or a configured CORS origin).
    # Fall back to Referer for the rare browser/proxy that strips Origin.
    def same_origin?(request)
      allowed = [@feature.public_url, *@feature.cors_allowed_origins]
        .compact.map { |o| o.sub(/\/+\z/, "") }

      origin = request.headers["origin"].to_s.sub(/\/+\z/, "")
      unless origin.empty?
        return allowed.include?(origin)
      end

      referer = request.headers["referer"].to_s
      return false if referer.empty?
      allowed.any? { |o| referer == o || referer.start_with?(o + "/") }
    end
  end
end
