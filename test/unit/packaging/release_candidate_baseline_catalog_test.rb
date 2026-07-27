require "test_helper"
require "digest"
require "json"
require "open3"
require "yaml"
require_relative "../../../packaging/release_candidate/baseline_catalog"
require_relative "../../../packaging/release_candidate/runner"

class ReleaseCandidateBaselineCatalogTest < Minitest::Test
  include HiveTestHelper
  ROOT = File.expand_path("../../..", __dir__).freeze
  CATALOG = File.join(ROOT, "packaging/release_candidate/baselines.yml").freeze

  def test_checked_in_catalog_pins_reviewed_producer_and_observer_packages
    catalog = HiveReleaseCandidate::BaselineCatalog.load(CATALOG)

    assert_equal "latest-stable", catalog.latest_stable.id
    assert_equal "0.6.9", catalog.latest_stable.version
    assert_equal(
      1_631_232,
      catalog.latest_stable.packages.fetch("producer").fetch("artifact").fetch("size")
    )
    assert_equal(
      "9e9d065f67ccf3381b263f9a5ca44afb79b3122309b1b87c2477ddb6b2fba7a1",
      catalog.latest_stable.packages.fetch("producer").fetch("artifact").fetch("sha256")
    )
    legacy = catalog.fetch("legacy-bench-v041")
    assert_equal 1_070_592, legacy.packages.fetch("producer").fetch("artifact").fetch("size")
    assert_equal 1_164_288, legacy.packages.fetch("observer").fetch("artifact").fetch("size")
    assert_equal(
      "596f8e9018a2a7d419ca1758344ed64b617d1edb5679a25e8d86684ecb15ee36",
      legacy.packages.fetch("producer").fetch("artifact").fetch("sha256")
    )
    assert_equal(
      "df7e1599621db2fe4710dcd676d11be6b7f0a8a050fcda3b28030e943143a356",
      legacy.packages.fetch("observer").fetch("artifact").fetch("sha256")
    )
    assert_match(/\A[0-9a-f]{64}\z/, catalog.digest)
    assert_match(/\A[0-9a-f]{64}\z/, catalog.dependency_closure_digest)
    assert_equal(
      "77459fb53267625944a5b8b995e7012c02f55a96b4d28a7a9d7b7e13864147e0",
      catalog.latest_stable.packages.dig("producer", "authentication", "checksum", "sha256")
    )
  end

  def test_catalog_rejects_missing_review_metadata_and_noncanonical_asset_urls
    raw = YAML.safe_load_file(CATALOG, aliases: false)
    raw.fetch("rows").first.delete("retirement")
    error = assert_raises(HiveReleaseCandidate::Error) do
      HiveReleaseCandidate::BaselineCatalog.parse(YAML.dump(raw), source: "fixture.yml")
    end
    assert_includes error.message, "retirement"

    raw = YAML.safe_load_file(CATALOG, aliases: false)
    raw.fetch("rows").first.fetch("packages").fetch("producer")
      .fetch("artifact")["url"] = "http://example.test/substituted.gem"
    error = assert_raises(HiveReleaseCandidate::Error) do
      HiveReleaseCandidate::BaselineCatalog.parse(YAML.dump(raw), source: "fixture.yml")
    end
    assert_includes error.message, "canonical HTTPS release URL"

    raw = YAML.safe_load_file(CATALOG, aliases: false)
    raw.fetch("rows").first["unexpected"] = true
    error = assert_raises(HiveReleaseCandidate::Error) do
      HiveReleaseCandidate::BaselineCatalog.parse(YAML.dump(raw), source: "fixture.yml")
    end
    assert_includes error.message, "extra: unexpected"

    raw = YAML.safe_load_file(CATALOG, aliases: false)
    raw.fetch("rows") << Marshal.load(Marshal.dump(raw.fetch("rows").first))
    error = assert_raises(HiveReleaseCandidate::Error) do
      HiveReleaseCandidate::BaselineCatalog.parse(YAML.dump(raw), source: "fixture.yml")
    end
    assert_includes error.message, "duplicate baseline id"
  end

  def test_latest_stable_freshness_fails_closed_without_floating_the_catalog
    catalog = HiveReleaseCandidate::BaselineCatalog.load(CATALOG)

    fresh = catalog.freshness(observed_tag: "v0.6.9", observed_prerelease: false)
    stale = catalog.freshness(observed_tag: "v0.7.0", observed_prerelease: false)

    assert_equal "passed", fresh.fetch("status")
    assert_equal "failed", stale.fetch("status")
    assert_equal "baseline_catalog_stale", stale.fetch("reason")
    assert_equal "v0.6.9", stale.fetch("catalog_tag")
    assert_equal "v0.6.9", catalog.latest_stable.tag
  end

  def test_dependency_closure_rejects_lock_mismatch_and_incomplete_cache
    catalog = HiveReleaseCandidate::BaselineCatalog.load(CATALOG)
    entry = catalog.latest_stable
    lock = run_git(ROOT, "show", "v0.6.9:Gemfile.lock")
    filenames = catalog.send(:runtime_closure_filenames, { "producer" => lock })
    manifest = {
      "schema" => "hive-release-candidate-offline-gem-cache",
      "schema_version" => 1,
      "lock_sha256s" => {
        "producer" => entry.dependency_closure.fetch("lock").fetch("sha256")
      },
      "completeness" => "exact-locked-runtime-transitive-closure",
      "network" => "forbidden",
      "artifacts" => filenames.map do |filename|
        { "filename" => filename, "size" => 4, "sha256" => "a" * 64 }
      end
    }

    assert catalog.verify_dependency_closure!(
      entry, lock_contents: { "producer" => lock },
      cache_manifest_content: JSON.generate(manifest)
    )

    error = assert_raises(HiveReleaseCandidate::Error) do
      catalog.verify_dependency_closure!(
        entry, lock_contents: { "producer" => "#{lock}substituted" },
        cache_manifest_content: JSON.generate(manifest)
      )
    end
    assert_includes error.message, "lock digest mismatch"

    error = assert_raises(HiveReleaseCandidate::Error) do
      catalog.verify_dependency_closure!(
        entry, lock_contents: { "producer" => lock },
        cache_manifest_content: JSON.generate(manifest.merge(
          "artifacts" => manifest.fetch("artifacts").drop(1)
        ))
      )
    end
    assert_includes error.message, "locked runtime closure"
  end

  def test_historical_closure_rejects_observer_lock_mismatch
    catalog = HiveReleaseCandidate::BaselineCatalog.load(CATALOG)
    entry = catalog.fetch("legacy-bench-v041")
    producer = run_git(ROOT, "show", "v0.4.1:Gemfile.lock")
    observer = run_git(ROOT, "show", "v0.4.2:Gemfile.lock")
    lock_sha256s = {
      "producer" => Digest::SHA256.hexdigest(producer),
      "observer" => Digest::SHA256.hexdigest(observer)
    }
    manifest = {
      "schema" => "hive-release-candidate-offline-gem-cache",
      "schema_version" => 1,
      "lock_sha256s" => lock_sha256s,
      "completeness" => "exact-locked-runtime-transitive-closure",
      "network" => "forbidden",
      "artifacts" => catalog.send(
        :runtime_closure_filenames,
        { "producer" => producer, "observer" => observer }
      ).map do |filename|
        { "filename" => filename, "size" => 4, "sha256" => "a" * 64 }
      end
    }

    assert catalog.verify_dependency_closure!(
      entry,
      lock_contents: { "producer" => producer, "observer" => observer },
      cache_manifest_content: JSON.generate(manifest)
    )
    error = assert_raises(HiveReleaseCandidate::Error) do
      catalog.verify_dependency_closure!(
        entry,
        lock_contents: { "producer" => producer, "observer" => "#{observer}substituted" },
        cache_manifest_content: JSON.generate(manifest)
      )
    end
    assert_includes error.message, "observer dependency lock digest mismatch"
  end

  def test_checked_reviewed_manifests_match_every_runtime_lock_and_catalog_digest
    catalog = HiveReleaseCandidate::BaselineCatalog.load(CATALOG)

    catalog.entries.each do |entry|
      offline = entry.dependency_closure.fetch("offline_cache")
      manifest = File.binread(File.join(ROOT, offline.fetch("manifest_path")))
      assert_equal offline.fetch("manifest_sha256"), Digest::SHA256.hexdigest(manifest)
      locks = {
        "producer" => run_git(
          ROOT, "show", "#{entry.dependency_closure.dig('lock', 'source_tag')}:Gemfile.lock"
        )
      }
      if entry.dependency_closure["observer_lock"]
        locks["observer"] = run_git(
          ROOT,
          "show",
          "#{entry.dependency_closure.dig('observer_lock', 'source_tag')}:Gemfile.lock"
        )
      end

      assert catalog.verify_dependency_closure!(
        entry,
        lock_contents: locks,
        cache_manifest_content: manifest
      )
    end
  end

  def test_current_runtime_closure_includes_exact_bundler_omitted_from_lock_specs
    catalog = HiveReleaseCandidate::BaselineCatalog.load(CATALOG)
    lock = File.binread(File.join(ROOT, "Gemfile.lock"))

    artifacts = catalog.runtime_closure_artifacts("candidate" => lock)
    bundler = artifacts.find { |artifact| artifact["name"] == "bundler" }

    refute_nil bundler
    assert_equal "2.7.2", bundler.fetch("version")
    assert_equal "ruby", bundler.fetch("platform")
    assert_equal "bundler-2.7.2.gem", bundler.fetch("filename")
    assert_includes catalog.runtime_closure_filenames("candidate" => lock),
                    "bundler-2.7.2.gem"
  end

  def test_repository_input_and_plan_bind_committed_catalog_without_downloading
    with_tmp_dir do |repo|
      run_git(repo, "init", "-b", "main")
      run_git(repo, "config", "user.email", "test@example.com")
      run_git(repo, "config", "user.name", "Hive Test")
      FileUtils.mkdir_p(File.join(repo, "packaging/release_candidate"))
      FileUtils.mkdir_p(File.join(repo, "packaging/release_candidate/baseline_manifests"))
      FileUtils.mkdir_p(File.join(repo, "lib/hive"))
      FileUtils.cp(CATALOG, File.join(repo, "packaging/release_candidate/baselines.yml"))
      FileUtils.cp(
        Dir.glob(File.join(ROOT, "packaging/release_candidate/baseline_manifests/*.json")),
        File.join(repo, "packaging/release_candidate/baseline_manifests")
      )
      File.write(
        File.join(repo, "lib/hive/version.rb"),
        "module Hive; VERSION = \"0.6.9\"; end\n"
      )
      run_git(repo, "add", ".")
      run_git(repo, "commit", "-m", "fixture")
      sha = run_git(repo, "rev-parse", "HEAD").strip

      before = Dir.glob(File.join(repo, "tmp", "**", "*"))
      plan = HiveReleaseCandidate::Runner.new(repo_root: repo).plan(ref: sha)
      baseline = plan.fetch("inputs").fetch("baselines")

      assert_equal "available", baseline.fetch("status")
      assert_equal "0.6.9", plan.fetch("baseline_version")
      assert_includes plan.fetch("blockers"), "candidate_not_newer"
      assert_equal catalog_digest, baseline.fetch("sha256")
      assert_match(/\A[0-9a-f]{64}\z/, baseline.fetch("catalog_dependency_closure_sha256"))
      assert_equal "missing", plan.dig("baseline_cache", "status")
      assert_equal "baseline_assets_missing", plan.dig("baseline_cache", "reason")
      assert_equal 12, plan.dig("baseline_cache", "assets").size
      assert_equal 2, plan.dig("baseline_cache", "closures").size
      assert_nil plan.dig("baseline_cache", "verified_dependency_closure_sha256")
      fetch_argv = plan.dig("baseline_cache", "fetch_argv")
      release_fetches = fetch_argv.select { |argv| argv.first(3) == %w[gh release download] }
      closure_fetch = fetch_argv.reject { |argv| argv.first(3) == %w[gh release download] }
      assert_equal 12, release_fetches.length
      assert_equal 1, closure_fetch.length
      assert_equal(
        "packaging/release_candidate/materialize_baseline_cache.rb",
        closure_fetch.first.fetch(1)
      )
      assert_equal sha, closure_fetch.first.fetch(2)
      assert_equal 4, closure_fetch.first.length
      assert_equal(
        %w[v0.4.1 v0.4.2 v0.6.9],
        release_fetches.map { |argv| File.basename(argv.fetch(-1)) }.uniq.sort
      )
      assert_equal before, Dir.glob(File.join(repo, "tmp", "**", "*")),
        "read-only plan must not create a cache or candidate root"

      repository = HiveReleaseCandidate::Repository.new(repo)
      first = repository.baseline_catalog(sha)
      assert_same first, repository.baseline_catalog(sha)
      assert_equal first.latest_stable.version, repository.version(sha)
    end
  end

  def test_runner_accepts_only_exact_catalog_cache_attestation
    with_tmp_dir do |repo|
      cache = File.join(repo, "tmp/release-candidates/baseline-cache")
      FileUtils.mkdir_p(File.join(cache, "attestations"))
      catalog = Struct.new(:digest, :entries).new(
        "a" * 64,
        [
          Struct.new(:id).new("latest-stable"),
          Struct.new(:id).new("legacy-bench-v041")
        ]
      )
      inventory = [
        {
          "status" => "verified", "tag" => "v0.6.9", "filename" => "hive.gem",
          "sha256" => "b" * 64, "size" => 4
        }
      ]
      closures = [
        { "status" => "verified", "row_id" => "latest-stable", "sha256" => "c" * 64 },
        { "status" => "verified", "row_id" => "legacy-bench-v041", "sha256" => "d" * 64 }
      ]
      release_digest = Digest::SHA256.hexdigest(JSON.generate(
        [ [ "v0.6.9", "hive.gem", "b" * 64, 4 ] ]
      ))
      closure_digest = Digest::SHA256.hexdigest(JSON.generate(
        closures.sort_by { |row| row.fetch("row_id") }.map { |row| row.fetch("sha256") }
      ))
      path = File.join(cache, "attestations", "#{'a' * 64}.json")
      File.write(path, JSON.generate(
        "schema" => "hive-release-candidate-baseline-cache-attestation",
        "schema_version" => 1,
        "baseline_catalog_sha256" => "a" * 64,
        "release_assets_sha256" => release_digest,
        "verified_dependency_closure_sha256" => closure_digest,
        "rows" => %w[latest-stable legacy-bench-v041].sort
      ) + "\n")
      runner = HiveReleaseCandidate::Runner.new(repo_root: repo)

      verified = runner.send(
        :baseline_cache_attestation, catalog, cache, inventory, closures
      )
      assert_equal "verified", verified.fetch("status")
      assert_equal release_digest, verified.fetch("release_assets_sha256")
      assert_equal closure_digest, verified.fetch("verified_dependency_closure_sha256")

      document = JSON.parse(File.binread(path))
      document["rows"] = [ "latest-stable" ]
      File.write(path, JSON.generate(document) + "\n")
      invalid = runner.send(
        :baseline_cache_attestation, catalog, cache, inventory, closures
      )
      assert_equal "invalid", invalid.fetch("status")
      assert_equal "baseline_cache_attestation_invalid", invalid.fetch("reason")
    end
  end

  private

  def catalog_digest
    Digest::SHA256.file(CATALOG).hexdigest
  end

  def run_git(repo, *argv)
    stdout, stderr, status = Open3.capture3("git", *argv, chdir: repo)
    assert status.success?, stderr
    stdout
  end
end
