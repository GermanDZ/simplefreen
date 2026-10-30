# frozen_string_literal: true

module Simplefreen
  # User-facing error. Surfaced with `abort error.message` by the CLI.
  class Error < StandardError; end

  # Config missing, invalid, or the operator fed something broken.
  class ConfigError < Error; end

  # Raised when the scheduler can't proceed with a job for a reason
  # the operator can fix from the admin UI (missing credentials,
  # disabled profile, …). The message is surfaced verbatim in the
  # profile's `last_error` instead of getting wrapped in
  # "invoke setup failed: ClassName: …" prefixing.
  class OperatorError < Error; end
end
