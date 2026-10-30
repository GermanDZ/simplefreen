# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "tmpdir"
require "uri"

require_relative "atomic_file"
require_relative "paths"

module Simplefreen
  # Pulls workflow YAMLs from a GitHub repo tarball at a specific ref
  # (branch / tag / commit SHA — anything GitHub's tarball API accepts)
  # and lays them down under `workflows_dir`. Convention is one
  # `<provider_slug>/workflow.yml` per provider; everything else in the
  # tarball is ignored (READMEs, fixtures, etc. — they don't break
  # anything but they aren't surfaced to the admin dropdown either).
  #
  # Usage:
  #   refresher = WorkflowsRefresher.new(workflows_dir: "/workflows")
  #   refresher.refresh!(ref: "v0.4.1")
  #   # => { providers: ["ing"], ref: "v0.4.1", commit: "abc1234", ... }
  #
  # Atomicity: each provider directory is replaced as a unit (rm -rf +
  # cp -r). A failed download / extraction / validation step never
  # touches `workflows_dir`. A failure mid-sync may leave some providers
  # updated and others not — re-running the refresh recovers.
  #
  # Tracking: on success, writes `.refresh-meta.json` at the root of
  # `workflows_dir` so the admin UI can show what's installed and
  # default the next refresh to the same ref.
  class WorkflowsRefresher
    DEFAULT_REPO = "GermanDZ/freentonic-providers"
    DEFAULT_REF  = "main"
    META_FILE    = ".refresh-meta.json"

    # Cap on the tarball size — defense in depth against a runaway
    # download (typo'd URL pointing at a multi-GB asset). 50 MB is way
    # more than freentonic-providers will ever realistically be.
    MAX_TARBALL_BYTES = 50 * 1024 * 1024

    # Some servers don't honor redirects without an explicit chain depth.
    MAX_REDIRECTS = 5

    # GitHub allows branch names / tag names with `/`, `_`, `-`, `.`,
    # and the SHA forms are hex-only. The pattern is permissive but
    # forecloses shell-meaningful characters and obvious URL injection.
    REF_PATTERN = %r{\A[A-Za-z0-9_./\-]{1,128}\z}

    class Error < StandardError; end

    # Read the metadata `refresh!` last wrote to this dir, or nil if no
    # refresh has ever been run (or the dir was deleted). Cheap read —
    # safe to call from a hot UI path.
    def self.read_meta(workflows_dir)
      return nil if workflows_dir.nil? || workflows_dir.empty?
      path = File.join(workflows_dir, META_FILE)
      return nil unless File.file?(path)
      AtomicFile.read_json(path)
    end

    def initialize(workflows_dir:, repo: DEFAULT_REPO, http_get: nil, logger: nil)
      raise Error, "workflows_dir is required" if workflows_dir.nil? || workflows_dir.empty?
      @workflows_dir = workflows_dir
      @repo          = repo
      @http_get      = http_get   # injectable for tests
      @logger        = logger || ->(_msg) {}
    end

    # Pull the tarball for `ref` (branch / tag / commit SHA — anything
    # GitHub's tarball API resolves) and lay providers down. Returns a
    # hash with the ref, the resolved short commit SHA (parsed from the
    # tarball's top-level dir name), the providers found, and the
    # absolute source URL used.
    def refresh!(ref: DEFAULT_REF)
      ref = ref.to_s.strip
      ref = DEFAULT_REF if ref.empty?
      raise Error, "ref contains invalid characters or is too long" unless ref =~ REF_PATTERN
      ensure_writable!

      source_url = tarball_url(ref)

      Dir.mktmpdir("simplefreen-workflows-refresh-") do |tmp|
        tarball = File.join(tmp, "providers.tar.gz")
        File.open(tarball, "wb") { |f| f.write(get_with_redirects(source_url)) }

        extracted = File.join(tmp, "extracted")
        Dir.mkdir(extracted)
        extract_tarball(tarball, extracted)

        provider_root = single_top_level_dir(extracted)
        # GitHub's tarball top-level dir is always <owner>-<repo>-<shortsha>.
        # That last segment is our breadcrumb back to the resolved commit.
        commit = File.basename(provider_root).split("-").last

        providers = discover_providers(provider_root)
        raise Error, "no `<slug>/workflow.yml` files in tarball" if providers.empty?

        replaced = []
        providers.each do |slug|
          src = File.join(provider_root, slug)
          dst = File.join(@workflows_dir, slug)
          FileUtils.rm_rf(dst)
          FileUtils.cp_r(src, dst)
          replaced << slug
        end

        meta = {
          "ref"        => ref,
          "commit"     => commit,
          "providers"  => replaced,
          "repo"       => @repo,
          "source"     => source_url,
          "fetched_at" => Time.now.utc.iso8601
        }
        AtomicFile.write_json(File.join(@workflows_dir, META_FILE), meta)
        meta.transform_keys(&:to_sym)
      end
    end

    private

    def tarball_url(ref)
      # GitHub's REST tarball endpoint accepts any ref form (branch,
      # tag, full or short commit SHA) and 302-redirects to the actual
      # download. The redirect target carries the resolved commit but
      # we don't need it — we read the short SHA from the extracted
      # top-level dir name instead.
      "https://api.github.com/repos/#{@repo}/tarball/#{URI.encode_www_form_component(ref)}"
    end

    def ensure_writable!
      FileUtils.mkdir_p(@workflows_dir)
      raise Error, "#{@workflows_dir} is not writable" unless File.writable?(@workflows_dir)
    end

    def get_with_redirects(url, depth: 0)
      raise Error, "too many redirects fetching tarball" if depth > MAX_REDIRECTS
      return @http_get.call(url) if @http_get   # test injection point

      uri = URI(url)
      raise Error, "unsupported scheme: #{uri.scheme}" unless %w[http https].include?(uri.scheme)

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                      open_timeout: 5, read_timeout: 30) do |http|
        # GitHub's API rejects `Accept: application/octet-stream` on
        # the tarball endpoint with 415; it wants the standard JSON
        # accept and returns binary regardless. The User-Agent is
        # mandatory — unauthenticated requests get 403 without one.
        req = Net::HTTP::Get.new(uri.request_uri,
          "User-Agent" => "simplefreen/#{Simplefreen::VERSION} (workflows-refresh)",
          "Accept"     => "application/vnd.github+json")
        resp = http.request(req)
        case resp
        when Net::HTTPSuccess
          if resp.body.bytesize > MAX_TARBALL_BYTES
            raise Error, "tarball exceeds #{MAX_TARBALL_BYTES} bytes (got #{resp.body.bytesize})"
          end
          resp.body
        when Net::HTTPRedirection
          target = resp["location"]
          raise Error, "redirect with no Location header" if target.nil? || target.empty?
          @logger.call("workflows refresh: following redirect to #{target}")
          get_with_redirects(target, depth: depth + 1)
        when Net::HTTPNotFound
          raise Error, "ref not found at #{@repo} (check that the branch/tag/SHA exists)"
        else
          raise Error, "GET #{url} returned #{resp.code}"
        end
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED => e
      raise Error, "network error fetching tarball: #{e.class}: #{e.message}"
    end

    # Shell out to tar — every base image we ship for has it (busybox,
    # debian-slim, alpine all bundle tar). Keeps simplefreen's gem-deps
    # at zero. The `-C` flag scopes extraction to the destination so
    # absolute paths in the tarball can't escape.
    def extract_tarball(tarball, dest)
      ok = system("tar", "-xzf", tarball, "-C", dest, exception: false)
      raise Error, "tar extraction failed (exit status #{$?&.exitstatus})" unless ok
    end

    def single_top_level_dir(extracted)
      entries = Dir.children(extracted).select { |c| File.directory?(File.join(extracted, c)) }
      raise Error, "expected exactly one top-level dir in tarball, got #{entries.inspect}" if entries.size != 1
      File.join(extracted, entries.first)
    end

    def discover_providers(root)
      Dir.children(root).select do |name|
        # Convention: `<slug>/workflow.yml`. Matches the dropdown's
        # filter in `AdminApi#list_workflows`. Provider slugs must be
        # safe to splice into paths.
        next false unless name =~ Paths::FILENAME_PATTERN
        File.file?(File.join(root, name, "workflow.yml"))
      end.sort
    end
  end
end
