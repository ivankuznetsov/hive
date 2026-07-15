require "test_helper"
require "hive/honeycomb/registry"

class HoneycombRegistryTest < Minitest::Test
  include HiveTestHelper

  def test_refreshes_local_bare_registry_and_verifies_release_tag
    with_registry_fixture do |remote, sha, digest|
      with_tmp_dir do |cache|
        registry = Hive::Honeycomb::Registry.new(remote_url: remote, cache_dir: cache)
        catalog = registry.refresh!
        pin = registry.resolve("honeycomb/demo", refresh: false)

        assert_equal [ "demo" ], catalog.workflow_names
        assert_equal sha, pin.sha
        assert_equal digest, pin.digest
        assert File.file?(File.join(cache, "catalog.yml"))
        assert File.directory?(File.join(cache, "registry.git"))
      end
    end
  end

  def test_malformed_refresh_keeps_last_valid_snapshot
    with_registry_fixture do |remote, _sha, _digest, work|
      with_tmp_dir do |cache|
        registry = Hive::Honeycomb::Registry.new(remote_url: remote, cache_dir: cache)
        registry.refresh!
        snapshot = File.binread(File.join(cache, "catalog.yml"))

        File.write(File.join(work, "catalog.yml"), "version: 99\n")
        run!("git", "-C", work, "add", "catalog.yml")
        run!("git", "-C", work, "commit", "-m", "bad catalog", "--quiet")
        run!("git", "-C", work, "push", "origin", "HEAD:main", "--quiet")

        assert_raises(Hive::Honeycomb::CatalogError) { registry.refresh! }
        assert_equal snapshot, File.binread(File.join(cache, "catalog.yml"))
        assert_equal [ "demo" ], registry.catalog.workflow_names
      end
    end
  end

  def test_rejects_a_tag_that_does_not_peel_to_recorded_commit
    with_registry_fixture do |remote, sha, digest, work|
      File.write(File.join(work, "other.txt"), "different\n")
      run!("git", "-C", work, "add", "other.txt")
      run!("git", "-C", work, "commit", "-m", "other", "--quiet")
      other_sha = run!("git", "-C", work, "rev-parse", "HEAD").strip
      write_catalog(work, sha: other_sha, digest: digest)
      run!("git", "-C", work, "add", "catalog.yml")
      run!("git", "-C", work, "commit", "-m", "mismatch", "--quiet")
      run!("git", "-C", work, "push", "origin", "HEAD:main", "--quiet")

      with_tmp_dir do |cache|
        registry = Hive::Honeycomb::Registry.new(remote_url: remote, cache_dir: cache)
        registry.refresh!
        error = assert_raises(Hive::Honeycomb::ResolutionError) do
          registry.resolve("honeycomb/demo", refresh: false)
        end
        assert_includes error.message, "tag"
      end
    end
  end

  private

  def with_registry_fixture
    with_tmp_dir do |root|
      remote = File.join(root, "remote.git")
      work = File.join(root, "work")
      run!("git", "init", "--bare", "--quiet", remote)
      run!("git", "init", "-b", "main", "--quiet", work)
      run!("git", "-C", work, "config", "user.email", "test@example.com")
      run!("git", "-C", work, "config", "user.name", "Test")
      run!("git", "-C", work, "config", "commit.gpgsign", "false")
      File.write(File.join(work, "payload.txt"), "payload\n")
      run!("git", "-C", work, "add", "payload.txt")
      run!("git", "-C", work, "commit", "-m", "release", "--quiet")
      sha = run!("git", "-C", work, "rev-parse", "HEAD").strip
      digest = "d" * 64
      write_catalog(work, sha: sha, digest: digest)
      run!("git", "-C", work, "add", "catalog.yml")
      run!("git", "-C", work, "commit", "-m", "catalog", "--quiet")
      run!("git", "-C", work, "tag", "demo/v1.0.0", sha)
      run!("git", "-C", work, "remote", "add", "origin", remote)
      run!("git", "-C", work, "push", "origin", "HEAD:main", "--tags", "--quiet")
      yield remote, sha, digest, work
    end
  end

  def write_catalog(work, sha:, digest:)
    File.write(File.join(work, "catalog.yml"), {
      "version" => 1,
      "workflows" => {
        "demo" => {
          "latest" => "1.0.0",
          "releases" => [
            { "version" => "1.0.0", "tag" => "demo/v1.0.0", "sha" => sha, "digest" => digest }
          ]
        }
      }
    }.to_yaml)
  end
end
