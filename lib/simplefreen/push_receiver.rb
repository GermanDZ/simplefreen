# frozen_string_literal: true

require "json"
require "time"

require_relative "atomic_file"
require_relative "http"
require_relative "paths"
require_relative "reshape"

module Simplefreen
  # Receives the normalized bank payload freentonic pushes at the end of a
  # sync via its `http` exporter. Path: `POST /push/<run_id>` with
  # `Authorization: Bearer <one-shot-token>`. The token is validated
  # against the in-memory PushTokens mint-table and consumed on success —
  # single-use, TTL-gated, scoped to the run_id so a valid token for run A
  # can't be used to poison run B's cache.
  #
  # On success: reshape the payload into SimpleFIN envelope shape, write
  # to CacheStore atomically, transition state → ready. Emulates
  # finanzas-web's bank_push_controller down to the 422-with-errors shape.
  class PushReceiver
    RUN_ID_PATTERN = Paths::FILENAME_PATTERN

    def initialize(feature:)
      @feature = feature
    end

    def dispatch(client, method, path, request)
      pathname, _params = Http.split_query(path)

      if (match = pathname.match(%r{\A/push/([^/]+)\z}))
        unless method == "POST"
          return Http.write_json(client, 405, { "error" => "method not allowed" })
        end
        return handle_push(client, match[1], request)
      end

      Http.write_json(client, 404, { "error" => "not found" })
    end

    private

    def handle_push(client, run_id, request)
      unless run_id =~ RUN_ID_PATTERN
        return Http.write_json(client, 400, { "error" => "invalid run_id" })
      end

      token = Http.bearer_token(request.headers["authorization"])
      unless token
        return Http.write_json(client, 401, { "error" => "missing bearer token" })
      end

      table = @feature.push_tokens
      unless table
        return Http.write_json(client, 503, { "error" => "push-token table not installed" })
      end

      unless table.consume(run_id, token)
        # Could be: unknown token, expired, run mismatch, or already used.
        # Don't leak which — all look like forgeries to an attacker.
        @feature.log("push rejected: bad bearer for run_id=#{run_id}")
        return Http.write_json(client, 401, { "error" => "bearer invalid, expired, or already consumed" })
      end

      # Expect a JSON body. freentonic's http exporter always emits JSON.
      payload = parse_json(request.body)
      unless payload.is_a?(Hash)
        return Http.write_json(client, 422, {
          "ok" => false,
          "errors" => ["request body is not a JSON object"]
        })
      end

      unless canonical_payload?(payload)
        # Cheap defense against a rolled-back pre-v0.4 freentonic image
        # sneaking a legacy-shape envelope through — Reshape would accept
        # parts of it and silently produce a broken SimpleFIN response.
        return Http.write_json(client, 422, {
          "ok" => false,
          "errors" => ["expected canonical envelope (schema_version), got something else"]
        })
      end

      # Correlate the run back to a profile_key. Freentonic's http
      # exporter threads FREENTONIC_RUN_ID into payload["meta"] for us,
      # but simplefreen knows the mapping directly via the scheduler's
      # active_job or the run_log entry. We use the simplest reliable
      # source: the scheduler's active-job record.
      profile_key = find_profile_key_for_run(run_id)
      unless profile_key
        @feature.log("push accepted but no active job maps to run_id=#{run_id}")
        return Http.write_json(client, 422, {
          "ok" => false,
          "errors" => ["no active job found for run_id; refusing to cache"]
        })
      end

      # Persist the immutable raw delta first. This is durable input for
      # the durable history store (next step) and the recovery source if
      # history.json ever needs to be rebuilt.
      raw_envelope = Reshape.call(payload)
      persist_canonical(profile_key, run_id, payload, raw_envelope)

      # Merge this run's transactions into the profile's durable history,
      # then reshape from the merged set so the served SimpleFIN envelope
      # reflects accumulated history rather than just the latest scrape.
      # On merge failure we fall back to the per-run envelope: the raw
      # canonical is already on disk, so HistoryStore#rebuild_from_runs!
      # can recover later. The system stays serving in the meantime.
      merge_error = nil
      envelope =
        begin
          merged = @feature.history_store.merge_run!(profile_key,
            run_id: run_id, payload: payload)
          Reshape.call(merged)
        rescue StandardError => e
          # Keep serving (the per-run envelope is still valid data), but a
          # persistent merge failure means history has stopped accumulating
          # while every other signal looks healthy. Record a marker so the
          # operator can actually see it via /admin/api/metrics.
          merge_error = "#{e.class}: #{e.message}"
          @feature.log("history merge failed for #{profile_key}/#{run_id}: " \
            "#{merge_error} — falling back to per-run envelope")
          raw_envelope
        end

      begin
        @feature.cache_store.write(profile_key, envelope)
      rescue StandardError => e
        @feature.log("cache write failed for #{profile_key}: #{e.class}: #{e.message}")
        return Http.write_json(client, 500, {
          "ok" => false,
          "errors" => ["cache write failed: #{e.class}"]
        })
      end

      now = Time.now.utc.iso8601
      @feature.state_store.force_state(profile_key, "ready",
        "last_run_id"             => run_id,
        "last_error"              => nil,
        "last_synced_at"          => now,
        "last_attempt_at"         => now,
        # Clear on a clean merge; stamp when the union stopped advancing.
        "history_merge_failed_at" => merge_error ? now : nil,
        "last_merge_error"        => merge_error)

      @feature.log("push accepted for #{profile_key} run_id=#{run_id} " \
        "(#{envelope["accounts"].size} account(s), #{envelope["errors"].size} reshape err(s))")

      Http.write_json(client, 200, {
        "ok"       => true,
        "run_id"   => run_id,
        "accounts" => envelope["accounts"].size,
        "errors"   => envelope["errors"]
      })
    end

    def parse_json(body)
      return nil if body.nil? || body.empty?
      # The HTTP layer hands us the body as BINARY-tagged bytes (server
      # buffers raw octets). JSON.parse will faithfully propagate that
      # encoding into every parsed String, and JSON 3.0 raises when those
      # are later passed back through JSON.generate. Re-tag as UTF-8 here
      # — the wire encoding for application/json is UTF-8 by spec.
      JSON.parse(body.dup.force_encoding(Encoding::UTF_8))
    rescue JSON::ParserError
      nil
    end

    def canonical_payload?(payload)
      payload.is_a?(Hash) && payload["schema_version"].is_a?(String)
    end

    # Persist the canonical envelope alongside the run-log entry so the
    # admin UI can show what data was collected. Diagnostic-only: a write
    # failure here must not fail the push (the SimpleFIN cache is already
    # written and Actual will see the new data).
    def persist_canonical(profile_key, run_id, payload, envelope)
      root = @feature.root
      AtomicFile.write_json(Paths.run_canonical_path(profile_key, run_id, root), payload)
      meta = {
        "schema_version"     => payload["schema_version"],
        "received_at"        => Time.now.utc.iso8601,
        "accounts_count"     => Array(payload["accounts"]).size,
        "transactions_count" => Array(payload["transactions"]).size,
        "reshape_errors"     => Array(envelope["errors"]).size,
        "summary"            => payload["summary"],
        "meta"               => payload["meta"]
      }
      AtomicFile.write_json(Paths.run_canonical_meta_path(profile_key, run_id, root), meta)
    rescue StandardError => e
      @feature.log("canonical persist failed for #{profile_key}/#{run_id}: #{e.class}: #{e.message}")
    end

    # Look up which profile an in-flight run belongs to. Prefer the
    # scheduler's active-job record (authoritative, minted by us). Fall
    # back to scanning run_log for any profile whose latest run has this
    # run_id (covers the rare case where /push arrives after /invoke has
    # already returned and the scheduler has cleared active_job).
    def find_profile_key_for_run(run_id)
      job = @feature.scheduler&.active_job
      return job[:profile_key] if job && job[:run_id] == run_id

      @feature.profile_store.list.each do |profile|
        latest = @feature.run_log.recent(profile["profile_key"], limit: 3)
        if latest.any? { |r| r["run_id"] == run_id }
          return profile["profile_key"]
        end
      end
      nil
    end
  end
end
