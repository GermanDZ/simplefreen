# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

require "simplefreen"

module Simplefreen
  class WorkflowsRefresherTest < Minitest::Test
    def setup
      @workflows_dir = Dir.mktmpdir("refresher-wf-")
    end

    def teardown
      FileUtils.rm_rf(@workflows_dir)
    end

    # Build a minimal valid tarball: a single top-level dir containing
    # two providers, each with a workflow.yml plus some sibling files
    # the refresher should ignore.
    #
    # The default top-level dir name follows GitHub's tarball convention:
    # `<owner>-<repo>-<short-sha>`. The refresher parses the trailing
    # segment as the resolved commit SHA.
    def build_tarball(name: "GermanDZ-freentonic-providers-abc1234", providers: { "ing" => "ok", "revolut" => "ok" })
      Dir.mktmpdir("refresher-build-") do |tmp|
        root = File.join(tmp, name)
        FileUtils.mkdir_p(root)
        providers.each do |slug, body|
          dir = File.join(root, slug)
          FileUtils.mkdir_p(dir)
          File.write(File.join(dir, "workflow.yml"), "---\nversion: 1\n# #{body}\n")
          File.write(File.join(dir, "config.yml"),   "---\nignored_by_refresher: true\n")
        end
        File.write(File.join(root, "README.md"), "ignored top-level file\n")
        tarball = File.join(tmp, "providers.tar.gz")
        Dir.chdir(tmp) do
          system("tar", "-czf", tarball, name, exception: true)
        end
        File.binread(tarball)
      end
    end

    def test_refreshes_providers_from_tarball
      bytes = build_tarball
      refresher = WorkflowsRefresher.new(
        workflows_dir: @workflows_dir,
        http_get:      ->(_url) { bytes }
      )

      result = refresher.refresh!(ref: "main")

      assert_equal %w[ing revolut], result[:providers]
      assert_equal "main", result[:ref]
      assert_equal "abc1234", result[:commit]   # parsed from tar top-dir
      assert_path_exists File.join(@workflows_dir, "ing",     "workflow.yml")
      assert_path_exists File.join(@workflows_dir, "revolut", "workflow.yml")
      # Only `<slug>/workflow.yml` matters per convention, but the
      # whole provider dir gets copied — config.yml comes along.
      assert_path_exists File.join(@workflows_dir, "ing", "config.yml")

      # Meta is persisted so the next call (and the admin UI) knows
      # what's installed.
      meta = WorkflowsRefresher.read_meta(@workflows_dir)
      assert_equal "main",     meta["ref"]
      assert_equal "abc1234",  meta["commit"]
      assert_equal %w[ing revolut], meta["providers"]
    end

    def test_refresh_uses_ref_in_url
      seen = []
      refresher = WorkflowsRefresher.new(
        workflows_dir: @workflows_dir,
        http_get:      ->(url) { seen << url; build_tarball }
      )
      refresher.refresh!(ref: "v0.4.1")
      assert_equal 1, seen.size
      assert_match(%r{api\.github\.com/repos/.+/tarball/v0\.4\.1}, seen.first)
    end

    def test_refresh_rejects_unsafe_ref
      refresher = WorkflowsRefresher.new(workflows_dir: @workflows_dir, http_get: ->(_url) { "x" })
      err = assert_raises(WorkflowsRefresher::Error) { refresher.refresh!(ref: "main; rm -rf /") }
      assert_match(/invalid characters/, err.message)
    end

    def test_refresh_replaces_stale_provider_dirs
      # Pre-existing provider with old content.
      FileUtils.mkdir_p(File.join(@workflows_dir, "ing"))
      File.write(File.join(@workflows_dir, "ing", "workflow.yml"),  "stale\n")
      File.write(File.join(@workflows_dir, "ing", "deleted_in_upstream.yml"), "should be gone\n")

      bytes = build_tarball(providers: { "ing" => "fresh" })
      refresher = WorkflowsRefresher.new(workflows_dir: @workflows_dir, http_get: ->(_url) { bytes })
      refresher.refresh!

      content = File.read(File.join(@workflows_dir, "ing", "workflow.yml"))
      assert_match(/fresh/, content)
      refute_path_exists File.join(@workflows_dir, "ing", "deleted_in_upstream.yml")
    end

    def test_refresh_raises_when_tarball_has_no_providers
      bytes = build_tarball(providers: {}) # only the top-level README
      refresher = WorkflowsRefresher.new(workflows_dir: @workflows_dir, http_get: ->(_url) { bytes })
      err = assert_raises(WorkflowsRefresher::Error) { refresher.refresh! }
      assert_match(/no `<slug>\/workflow\.yml`/, err.message)
    end

    def test_refresh_raises_on_unwritable_workflows_dir
      File.chmod(0o500, @workflows_dir)
      refresher = WorkflowsRefresher.new(workflows_dir: @workflows_dir, http_get: ->(_url) { build_tarball })
      err = assert_raises(WorkflowsRefresher::Error) { refresher.refresh! }
      assert_match(/not writable/, err.message)
    ensure
      File.chmod(0o700, @workflows_dir) if File.exist?(@workflows_dir)
    end

    def test_refresh_propagates_404_with_clear_message
      # Simulate GitHub returning 404 for an unknown ref by raising the
      # equivalent Error from the http_get stub.
      refresher = WorkflowsRefresher.new(
        workflows_dir: @workflows_dir,
        http_get:      ->(_url) { raise WorkflowsRefresher::Error, "ref not found at GermanDZ/freentonic-providers (check that the branch/tag/SHA exists)" }
      )
      err = assert_raises(WorkflowsRefresher::Error) { refresher.refresh!(ref: "no-such-tag") }
      assert_match(/ref not found/, err.message)
    end
  end
end
