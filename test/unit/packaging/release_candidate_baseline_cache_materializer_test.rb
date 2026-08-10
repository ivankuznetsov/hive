require "test_helper"
require "digest"
require "json"
require "yaml"
require_relative "../../../packaging/release_candidate/baseline_cache_materializer"

class ReleaseCandidateBaselineCacheMaterializerTest < Minitest::Test
  include HiveTestHelper

  ROOT = File.expand_path("../../..", __dir__)
  CATALOG = File.join(ROOT, "packaging/release_candidate/baselines.yml")
  GEM_BYTES = "reviewed-rake-gem".b

  def test_materializes_exact_reviewed_lock_manifest_and_gem_idempotently
    with_repository do |repo, sha, manifest|
      downloads = 0
      downloader = lambda do |url, output|
        downloads += 1
        assert_equal "https://rubygems.org/downloads/rake-13.2.1.gem", url
        File.binwrite(output, GEM_BYTES)
      end
      materializer = HiveReleaseCandidate::BaselineCacheMaterializer.new(
        repo_root: repo,
        cache_root: File.join(repo, "tmp/release-candidates/baseline-cache"),
        candidate_sha: sha,
        downloader: downloader,
        package_authenticator: ->(_entries) { synthetic_packages }
      )

      first = materializer.call
      second = materializer.call

      assert_equal "materialized", first.fetch("status")
      assert_equal first, second
      assert_equal 1, downloads
      attestation_path = first.dig("attestation", "path")
      attestation = JSON.parse(File.binread(attestation_path))
      assert_equal "hive-release-candidate-baseline-cache-attestation",
                   attestation.fetch("schema")
      assert_equal [ "latest-stable" ], attestation.fetch("rows")
      closure = File.join(
        repo, "tmp/release-candidates/baseline-cache/closures/latest-stable"
      )
      assert_equal manifest, File.binread(File.join(closure, "runtime-gems.v1.json"))
      assert_equal GEM_BYTES, File.binread(File.join(closure, "gems/rake-13.2.1.gem"))
      assert_equal minimal_lock, File.binread(File.join(closure, "producer.Gemfile.lock"))
    end
  end

  def test_rejects_candidate_manifest_substitution_before_download
    with_repository(substitute_manifest: true) do |repo, sha, _manifest|
      materializer = HiveReleaseCandidate::BaselineCacheMaterializer.new(
        repo_root: repo,
        cache_root: File.join(repo, "tmp/release-candidates/baseline-cache"),
        candidate_sha: sha,
        downloader: ->(*) { flunk "substituted manifest must fail before download" },
        package_authenticator: ->(_entries) { synthetic_packages }
      )

      error = assert_raises(HiveReleaseCandidate::Error) { materializer.call }
      assert_includes error.message, "reviewed offline cache manifest digest mismatch"
    end
  end

  private

  def with_repository(substitute_manifest: false)
    with_tmp_dir do |repo|
      run_git(repo, "init", "-b", "main")
      run_git(repo, "config", "user.email", "test@example.com")
      run_git(repo, "config", "user.name", "Hive Test")
      File.write(File.join(repo, "Gemfile.lock"), minimal_lock)
      run_git(repo, "add", "Gemfile.lock")
      run_git(repo, "commit", "-m", "baseline")
      run_git(repo, "tag", "v0.6.9")

      artifact = {
        "filename" => "rake-13.2.1.gem",
        "size" => GEM_BYTES.bytesize,
        "sha256" => Digest::SHA256.hexdigest(GEM_BYTES)
      }
      manifest = JSON.pretty_generate(
        "schema" => "hive-release-candidate-offline-gem-cache",
        "schema_version" => 1,
        "lock_sha256s" => { "producer" => Digest::SHA256.hexdigest(minimal_lock) },
        "completeness" => "exact-locked-runtime-transitive-closure",
        "network" => "forbidden",
        "artifacts" => [ artifact ]
      ) + "\n"
      catalog = YAML.safe_load_file(CATALOG, permitted_classes: [ Date ], aliases: false)
      catalog["rows"] = [ catalog.fetch("rows").first ]
      offline = catalog.dig("rows", 0, "dependency_closure", "offline_cache")
      catalog.dig("rows", 0, "dependency_closure", "lock")["sha256"] =
        Digest::SHA256.hexdigest(minimal_lock)
      offline["manifest_filename"] = "runtime-gems.v1.json"
      offline["manifest_path"] =
        "packaging/release_candidate/baseline_manifests/runtime-gems.v1.json"
      offline["manifest_sha256"] = Digest::SHA256.hexdigest(manifest)

      manifest_root = File.join(repo, "packaging/release_candidate/baseline_manifests")
      FileUtils.mkdir_p(manifest_root)
      File.write(File.join(repo, "packaging/release_candidate/baselines.yml"), YAML.dump(catalog))
      committed_manifest = substitute_manifest ? "#{manifest} " : manifest
      File.binwrite(File.join(manifest_root, "runtime-gems.v1.json"), committed_manifest)
      run_git(repo, "add", ".")
      run_git(repo, "commit", "-m", "candidate")
      sha = run_git(repo, "rev-parse", "HEAD").strip

      yield repo, sha, manifest
    end
  end

  def minimal_lock
    <<~LOCK
      PATH
        remote: .
        specs:
          hive-cli (0.6.9)
            rake (= 13.2.1)

      GEM
        remote: https://rubygems.org/
        specs:
          rake (13.2.1)

      PLATFORMS
        ruby

      DEPENDENCIES
        hive-cli!
    LOCK
  end

  def synthetic_packages
    [
      {
        "row_id" => "latest-stable",
        "role" => "producer",
        "tag" => "v0.6.9",
        "filename" => "hive-cli-0.6.9.gem",
        "size" => 1,
        "sha256" => "a" * 64
      }
    ]
  end

  def run_git(repo, *argv)
    stdout, stderr, status = Open3.capture3("git", *argv, chdir: repo)
    assert status.success?, stderr
    stdout
  end
end
