# frozen_string_literal: true

require_relative "test_helper"

module Simplefreen
  class NotifierTest < Minitest::Test
    # Minimal Net::HTTP stand-in: records the request, returns a canned
    # response. Accepts the setter calls Notifier makes.
    class FakeHttp
      attr_reader :requests
      attr_accessor :use_ssl, :open_timeout, :read_timeout, :response

      def initialize(response)
        @requests = []
        @response = response
      end

      def request(req)
        @requests << req
        raise @response if @response.is_a?(Exception)
        @response
      end
    end

    def ok_response(code = "200")
      resp = Object.new
      resp.define_singleton_method(:is_a?) { |klass| klass == Net::HTTPSuccess }
      resp.define_singleton_method(:code) { code }
      resp
    end

    def err_response(code = "500")
      resp = Object.new
      resp.define_singleton_method(:is_a?) { |_klass| false }
      resp.define_singleton_method(:code) { code }
      resp
    end

    def test_unconfigured_when_url_blank
      refute Notifier.new(url: nil).configured?
      refute Notifier.new(url: "").configured?
      refute Notifier.new(url: "   ").configured?
    end

    def test_unconfigured_when_url_not_http
      refute Notifier.new(url: "not a url").configured?
      refute Notifier.new(url: "ftp://ntfy.example/topic").configured?
    end

    def test_configured_with_http_url
      assert Notifier.new(url: "https://ntfy.sh/my-topic").configured?
    end

    def test_notify_noops_when_unconfigured
      n = Notifier.new(url: nil)
      # Must not touch the network — no with_net_http_new stub installed.
      assert_equal false, n.notify(title: "x", message: "y")
    end

    def test_notify_posts_title_priority_tags_and_body
      fake = FakeHttp.new(ok_response)
      n = Notifier.new(url: "https://ntfy.sh/my-topic")
      result = with_net_http_new(fake) do
        n.notify(title: "ING needs re-auth", message: "session expired",
                 priority: 4, tags: %w[warning key])
      end
      assert_equal true, result
      req = fake.requests.fetch(0)
      assert_equal "session expired", req.body
      assert_equal "ING needs re-auth", req["Title"]
      assert_equal "4", req["Priority"]
      assert_equal "warning,key", req["Tags"]
      assert_nil req["Authorization"]
      assert_equal true, fake.use_ssl
    end

    def test_notify_sends_bearer_when_token_present
      fake = FakeHttp.new(ok_response)
      n = Notifier.new(url: "https://ntfy.sh/my-topic", token: "sekret")
      with_net_http_new(fake) { n.notify(title: "t", message: "m") }
      assert_equal "Bearer sekret", fake.requests.fetch(0)["Authorization"]
    end

    def test_title_header_is_single_line
      fake = FakeHttp.new(ok_response)
      n = Notifier.new(url: "https://ntfy.sh/my-topic")
      with_net_http_new(fake) do
        n.notify(title: "line one\nline two\r\nthree", message: "m")
      end
      title = fake.requests.fetch(0)["Title"]
      refute_match(/[\r\n]/, title)
    end

    def test_notify_returns_false_on_http_error
      fake = FakeHttp.new(err_response("503"))
      n = Notifier.new(url: "https://ntfy.sh/my-topic")
      result = with_net_http_new(fake) { n.notify(title: "t", message: "m") }
      assert_equal false, result
    end

    def test_notify_swallows_transport_errors
      fake = FakeHttp.new(Errno::ECONNREFUSED.new("refused"))
      n = Notifier.new(url: "https://ntfy.sh/my-topic")
      # Must not raise — best-effort delivery.
      result = with_net_http_new(fake) { n.notify(title: "t", message: "m") }
      assert_equal false, result
    end

    def test_from_env_reads_url_and_token
      original = ENV.values_at(Notifier::URL_ENV, Notifier::TOKEN_ENV)
      ENV[Notifier::URL_ENV] = "https://ntfy.sh/env-topic"
      ENV[Notifier::TOKEN_ENV] = "envtok"
      n = Notifier.from_env
      assert n.configured?
      assert_equal "https://ntfy.sh/env-topic", n.url
    ensure
      ENV[Notifier::URL_ENV], ENV[Notifier::TOKEN_ENV] = original
    end
  end
end
