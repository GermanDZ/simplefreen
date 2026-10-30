# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "simplefreen"

# Swap Net::HTTP.new to return `replacement` inside the block. Pure-stdlib
# substitute for minitest-mock so we don't acquire a runtime dep. Mirrors
# the pattern in freentonic/test/test_helper.rb.
def with_net_http_new(replacement)
  original = Net::HTTP.method(:new)
  Net::HTTP.define_singleton_method(:new) { |*_args, **_kwargs| replacement }
  yield
ensure
  Net::HTTP.define_singleton_method(:new, original) if original
end
