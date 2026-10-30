# frozen_string_literal: true

require_relative "freentonic_client"

module Simplefreen
  # Periodic health probe for the freentonic upstream. Owns a background
  # thread that pings `FREENTONIC_URL/healthz` on a fixed cadence; flips
  # an in-memory `@state` between :active, :degraded, and :unknown.
  # The scheduler consults `#state` before dequeuing a job — syncs against
  # a degraded freentonic are skipped until the monitor sees it respond
  # again. Mirrors finanzas-web's FreentonicHealthCheckJob shape.
  class FreentonicHealth
    DEFAULT_INTERVAL_SECONDS = 5 * 60

    attr_reader :last_error, :last_probe_at

    def initialize(client:, interval_seconds: DEFAULT_INTERVAL_SECONDS, logger: nil)
      @client           = client
      @interval_seconds = interval_seconds
      @logger           = logger || ->(_msg) {}
      @mutex            = Mutex.new
      @state            = :unknown
      @last_error       = nil
      @last_probe_at    = nil
      @stopping         = false
      @thread           = nil
    end

    def state
      @mutex.synchronize { @state }
    end

    def active?
      state == :active
    end

    def snapshot
      @mutex.synchronize do
        {
          state:         @state,
          last_error:    @last_error,
          last_probe_at: @last_probe_at
        }
      end
    end

    def start
      return self if @thread
      @stopping = false
      @thread = Thread.new do
        # Run one probe immediately so the scheduler has a real signal
        # before the first 5-minute window elapses.
        probe_once
        until @stopping
          @interval_seconds.times do
            break if @stopping
            sleep 1
          end
          break if @stopping
          probe_once
        end
      end
      self
    end

    def stop(timeout: 5)
      @stopping = true
      @thread&.join(timeout)
      @thread = nil
    end

    # One-shot probe. Exposed so tests can drive it deterministically and
    # so an admin "refresh now" button could trigger it on demand.
    def probe_once
      @client.healthz(read_timeout: 3)
      @mutex.synchronize do
        prior = @state
        @state = :active
        @last_error = nil
        @last_probe_at = Time.now.utc.iso8601
        log("freentonic health: #{prior} → :active") if prior != :active
      end
      :active
    rescue StandardError => e
      @mutex.synchronize do
        prior = @state
        @state = :degraded
        @last_error = "#{e.class}: #{e.message}"
        @last_probe_at = Time.now.utc.iso8601
        log("freentonic health: #{prior} → :degraded (#{e.class}: #{e.message})") if prior != :degraded
      end
      :degraded
    end

    private

    def log(msg)
      @logger.call(msg)
    end
  end
end
