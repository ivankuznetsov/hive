require "test_helper"
require "hive/refactor_patrol/pr_manifest_resolver"

class RefactorPatrolPrManifestResolverTest < Minitest::Test
  include HiveTestHelper

  class FakeGh
    attr_accessor :details

    def initialize(details)
      @details = details
    end

    def merged_pr_details(*)
      Marshal.load(Marshal.dump(details))
    end
  end

  def test_resolves_and_publishes_write_once_checksummed_manifest
    with_tmp_dir do |dir|
      gh = FakeGh.new(details)
      resolver = resolver_for(dir, gh)

      manifest = resolver.resolve("7")
      path = resolver.manifest_path(manifest.fetch("job_id"))
      bytes = File.binread(path)
      assert_equal %w[lib/checkout.rb test/checkout_test.rb], manifest.fetch("changed_paths")
      refute_empty manifest.fetch("manifest_checksum")

      assert_equal manifest, resolver.resolve("https://github.com/acme/demo/pull/7")
      assert_equal bytes, File.binread(path), "identical replay must not rewrite its manifest"

      gh.details = details.merge(
        "files" => [ { "path" => "lib/other.rb", "status" => "modified" } ],
        "changed_files" => 1
      )
      assert_raises(Hive::RefactorPatrol::PrManifestResolver::Conflict) { resolver.resolve("7") }
      assert_equal bytes, File.binread(path), "conflicting replay must leave authoritative bytes untouched"
    end
  end

  def test_dry_run_validates_without_creating_v2_state
    with_tmp_dir do |dir|
      resolver = resolver_for(dir, FakeGh.new(details), dry_run: true)

      assert_equal 7, resolver.resolve("7").dig("source", "number")
      refute Dir.exist?(File.join(dir, ".hive-state", "refactor_patrol", "v2"))
    end
  end

  def test_rejects_unmerged_wrong_base_incomplete_and_unsafe_metadata
    with_tmp_dir do |dir|
      variants = [
        details.merge("state" => "OPEN"),
        details.merge("base_branch" => "release"),
        details.merge("merge_sha" => ""),
        details.merge("changed_files" => 3),
        details.merge("files" => [ { "path" => "../secret", "status" => "modified" } ], "changed_files" => 1),
        details.merge("files" => [ { "path" => "/etc/passwd", "status" => "modified" } ], "changed_files" => 1)
      ]

      variants.each do |invalid|
        assert_raises(Hive::GhError) { resolver_for(dir, FakeGh.new(invalid)).resolve("7") }
      end
    end
  end

  def test_concurrent_conflicting_publishers_never_clobber_first_manifest
    with_tmp_dir do |dir|
      left = details
      right = details.merge(
        "files" => [ { "path" => "lib/other.rb", "status" => "modified" } ],
        "changed_files" => 1
      )
      start = Queue.new
      outcomes = Queue.new
      [ left, right ].each do |candidate|
        Thread.new do
          start.pop
          begin
            outcomes << resolver_for(dir, FakeGh.new(candidate)).resolve("7")
          rescue StandardError => e
            outcomes << e
          end
        end
      end
      2.times { start << true }
      results = 2.times.map { outcomes.pop }

      assert_equal 1, results.count { |item| item.is_a?(Hash) }
      assert_equal 1, results.count { |item| item.is_a?(Hive::RefactorPatrol::PrManifestResolver::Conflict) }
      stored = JSON.parse(Dir[File.join(dir, ".hive-state", "refactor_patrol", "v2", "manifests", "*.json")].then { |paths| File.read(paths.one? ? paths.first : "") })
      assert_includes [ left["files"], right["files"] ], stored.fetch("files")
    end
  end

  private

  def resolver_for(dir, gh, dry_run: false)
    Hive::RefactorPatrol::PrManifestResolver.new(
      project_root: dir,
      registration: "demo",
      default_branch: "main",
      cfg: {},
      gh: gh,
      dry_run: dry_run
    )
  end

  def details
    {
      "number" => 7,
      "url" => "https://github.com/acme/demo/pull/7",
      "repository" => "acme/demo",
      "state" => "MERGED",
      "base_branch" => "main",
      "base_sha" => "a" * 40,
      "merge_sha" => "b" * 40,
      "merged_at" => "2026-07-10T10:00:00Z",
      "changed_files" => 2,
      "files" => [
        { "path" => "lib/checkout.rb", "status" => "modified" },
        { "path" => "test/checkout_test.rb", "status" => "added" }
      ]
    }
  end
end
