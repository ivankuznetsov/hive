require "test_helper"
require "digest"
require "fileutils"
require "open3"
require "tmpdir"
require "hive/workflow_package/canonical_json"
require_relative "patrol_qualification_control_provider"

class E2EPatrolQualificationControlProviderTest <
    Minitest::Test
  PROVIDER =
    Hive::E2E::PatrolQualificationControlProvider

  def test_builds_nonqualifying_identity_from_committed_local_control
    with_repository do |repo, catalog, manifest|
      sha = git(repo, "rev-parse", "HEAD").strip
      control =
        PROVIDER.new(repo_root: repo).call(candidate_sha: sha)

      assert_equal false, control.trusted_remote?
      assert_equal sha,
                   control.payload.fetch("commit_sha")
      assert_equal git(repo, "rev-parse", "HEAD^{tree}").strip,
                   control.payload.fetch("tree_sha")
      assert_nil control.payload.fetch("ref")
      assert_equal "github.com/example/hive",
                   control.payload.fetch("repository")
      assert_equal(
        Digest::SHA256.hexdigest(catalog),
        control.payload.dig("catalog", "sha256")
      )
      assert_equal(
        Digest::SHA256.hexdigest(manifest),
        control.payload.fetch("harness_manifest_sha256")
      )
    end
  end

  def test_detached_checkout_uses_nil_local_ref
    with_repository do |repo, _catalog, _manifest|
      sha = git(repo, "rev-parse", "HEAD").strip
      git(repo, "checkout", "--detach", sha)

      control =
        PROVIDER.new(repo_root: repo).call(candidate_sha: sha)

      assert_nil control.payload.fetch("ref")
      assert_equal(
        %w[
          qualification_control_untrusted
          qualification_control_not_independent
        ],
        control.qualification_issues(sha)
      )
    end
  end

  def test_reads_committed_bytes_and_rejects_local_path_origin
    with_repository do |repo, catalog, _manifest|
      path = File.join(repo, PROVIDER::CATALOG_REF)
      File.binwrite(path, "dirty")

      sha = git(repo, "rev-parse", "HEAD").strip
      control =
        PROVIDER.new(repo_root: repo).call(candidate_sha: sha)
      assert_equal(
        Digest::SHA256.hexdigest(catalog),
        control.payload.dig("catalog", "sha256")
      )

      git(repo, "remote", "set-url", "origin", "/tmp/local-hive")
      error = assert_raises(Hive::ConfigError) do
        PROVIDER.new(repo_root: repo).call(candidate_sha: sha)
      end
      assert_equal(
        "patrol qualification local control is unavailable",
        error.message
      )
    end
  end

  private

  def with_repository
    Dir.mktmpdir("patrol-control") do |repo|
      git(repo, "init", "--quiet", "--initial-branch=main")
      git(
        repo,
        "remote",
        "add",
        "origin",
        "git@github.com:example/hive.git"
      )
      catalog = canonical("schema" => "fixture-catalog")
      manifest = canonical("schema" => "fixture-manifest")
      {
        PROVIDER::CATALOG_REF => catalog,
        PROVIDER::HARNESS_MANIFEST_REF => manifest
      }.each do |ref, bytes|
        path = File.join(repo, ref)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, bytes)
        File.chmod(0o644, path)
      end
      git(repo, "add", ".")
      git(
        repo,
        "-c", "user.name=Hive Test",
        "-c", "user.email=hive@example.invalid",
        "commit", "--quiet", "-m", "fixture"
      )
      yield repo, catalog, manifest
    end
  end

  def canonical(value)
    Hive::WorkflowPackage::CanonicalJSON.generate(value)
  end

  def git(repo, *arguments)
    output, error, status =
      Open3.capture3("git", *arguments, chdir: repo)
    raise error unless status.success?
    output
  end
end
