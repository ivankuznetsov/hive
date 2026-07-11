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
      quarantines = Dir.glob(File.join(dir, ".hive-state", "refactor_patrol", "v2", "quarantine", "manifests", "*.json"))
      assert_equal 1, quarantines.size
      evidence = JSON.parse(File.read(quarantines.first))
      assert_equal manifest.fetch("job_id"), evidence.fetch("job_id")
      assert_equal "divergent_manifest", evidence.fetch("reason")
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
      assert_equal 1, Dir.glob(File.join(dir, ".hive-state", "refactor_patrol", "v2", "quarantine", "manifests", "*.json")).size
    end
  end

  def test_pr_reference_rejects_non_positive_and_malformed_values
    with_tmp_dir do |dir|
      resolver = resolver_for(dir, FakeGh.new(details))

      [ "0", "-1", "not a PR", "https://github.com/acme/demo/issues/7", "http://[" ].each do |value|
        assert_raises(Hive::GhError, value) { resolver.resolve(value) }
      end
    end
  end

  def test_metadata_rejects_invalid_time_file_shapes_statuses_and_duplicates
    with_tmp_dir do |dir|
      invalid = [
        details.merge("merged_at" => "yesterday"),
        details.merge("files" => [ nil ], "changed_files" => 1),
        details.merge("files" => [ { "path" => "lib/x.rb", "status" => "mystery" } ], "changed_files" => 1),
        details.merge(
          "files" => [
            { "path" => "lib/x.rb", "status" => "modified" },
            { "path" => "lib/x.rb", "status" => "added" }
          ],
          "changed_files" => 2
        )
      ]

      invalid.each do |candidate|
        assert_raises(Hive::GhError) { resolver_for(dir, FakeGh.new(candidate)).resolve("7") }
      end
    end
  end

  def test_corrupt_authoritative_manifest_is_quarantined_without_replacement
    with_tmp_dir do |dir|
      resolver = resolver_for(dir, FakeGh.new(details))
      manifest = resolver.resolve("7")
      path = resolver.manifest_path(manifest.fetch("job_id"))
      File.write(path, "{")

      error = assert_raises(Hive::RefactorPatrol::PrManifestResolver::Conflict) do
        resolver.resolve("7")
      end

      assert_includes error.message, "manifest is corrupt"
      assert_equal "{", File.binread(path)
      evidence = Dir.glob(
        File.join(dir, ".hive-state", "refactor_patrol", "v2", "quarantine", "manifests", "*.json")
      )
      assert_equal 1, evidence.size
      assert_equal "corrupt_authoritative_manifest", JSON.parse(File.read(evidence.first)).fetch("reason")
    end
  end

  def test_manifest_contract_rejects_schema_scope_checksum_and_source_drift
    manifest = Hive::RefactorPatrol::PrManifest.build(
      source: details.slice(
        "url", "number", "repository", "base_branch", "base_sha", "merge_sha", "merged_at"
      ).merge("registration" => "demo"),
      files: details.fetch("files")
    )

    invalid = [
      manifest.merge("schema" => "legacy"),
      manifest.merge("job_id" => "other"),
      manifest.merge("manifest_checksum" => "0" * 64),
      manifest.merge("source" => manifest.fetch("source").merge("number" => 0))
    ]
    invalid.each do |candidate|
      assert_raises(Hive::RefactorPatrol::PrManifest::Invalid) do
        Hive::RefactorPatrol::PrManifest.validate!(
          candidate,
          expected_job_id: manifest.fetch("job_id"), registration: "demo", default_branch: "main"
        )
      end
    end

    assert_raises(Hive::RefactorPatrol::PrManifest::Invalid) do
      Hive::RefactorPatrol::PrManifest.validate!(manifest, registration: "other")
    end
    assert_raises(Hive::RefactorPatrol::PrManifest::Invalid) do
      Hive::RefactorPatrol::PrManifest.validate!(manifest, default_branch: "release")
    end

    assert_same manifest, Hive::RefactorPatrol::PrManifest.validate!(
      manifest,
      expected_job_id: manifest.fetch("job_id"), registration: "demo", default_branch: "main"
    )

    invalid_scope = manifest.merge("changed_paths" => [ "lib/checkout.rb", "lib/checkout.rb" ])
    assert_raises(Hive::RefactorPatrol::PrManifest::Invalid) do
      Hive::RefactorPatrol::PrManifest.validate!(invalid_scope)
    end

    invalid_source = manifest.merge("source" => [])
    assert_raises(Hive::RefactorPatrol::PrManifest::Invalid) do
      Hive::RefactorPatrol::PrManifest.validate!(invalid_source)
    end

    invalid_time = Marshal.load(Marshal.dump(manifest))
    invalid_time.fetch("source")["merged_at"] = "yesterday"
    assert_raises(Hive::RefactorPatrol::PrManifest::Invalid) do
      Hive::RefactorPatrol::PrManifest.validate!(invalid_time)
    end
  end

  def test_manifest_load_wraps_missing_and_invalid_json
    with_tmp_dir do |dir|
      missing = File.join(dir, "missing.json")
      invalid = File.join(dir, "invalid.json")
      File.write(invalid, "{")

      assert_raises(Hive::RefactorPatrol::PrManifest::Invalid) do
        Hive::RefactorPatrol::PrManifest.load!(missing)
      end
      assert_raises(Hive::RefactorPatrol::PrManifest::Invalid) do
        Hive::RefactorPatrol::PrManifest.load!(invalid)
      end
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
