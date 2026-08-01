require "test_helper"
require "digest"
require "json"
require "open3"
require_relative "../../../packaging/release_candidate/artifacts"
require_relative "../../../packaging/release_candidate/runner"

class ReleaseCandidateArtifactsTest < Minitest::Test
  include HiveTestHelper

  def test_rejects_a_non_full_candidate_sha_before_building
    error = assert_raises(HiveReleaseCandidate::Error) do
      HiveReleaseCandidate::Artifacts.new(
        repo_root: Dir.pwd,
        candidate_sha: "main",
        candidate_dir: File.join(Dir.pwd, "tmp", "release-candidates", "main", "candidate")
      )
    end

    assert_includes error.message, "full 40-character commit SHA"
  end

  def test_verifier_rejects_substituted_and_unmanifested_artifacts
    with_tmp_dir do |dir|
      artifacts = fixture_artifacts(dir)
      artifacts.verify!

      gem = File.join(artifacts.candidate_dir, "hive-cli-0.6.9.gem")
      File.open(gem, "ab") { |file| file.write("substitution") }
      error = assert_raises(HiveReleaseCandidate::Error) { artifacts.verify! }
      assert_includes error.message, "size mismatch"

      artifacts = fixture_artifacts(File.join(dir, "extra"))
      File.write(File.join(artifacts.candidate_dir, "unmanifested.txt"), "extra")
      error = assert_raises(HiveReleaseCandidate::Error) { artifacts.verify! }
      assert_includes error.message, "unmanifested"
    end
  end

  def test_verifier_rejects_symlinked_artifact_and_malformed_builder_revision
    with_tmp_dir do |dir|
      artifacts = fixture_artifacts(dir)
      gem = File.join(artifacts.candidate_dir, "hive-cli-0.6.9.gem")
      outside = File.join(dir, "outside.gem")
      FileUtils.mv(gem, outside)
      File.symlink(outside, gem)

      error = assert_raises(HiveReleaseCandidate::Error) { artifacts.verify! }
      assert_includes error.message, "regular file"

      artifacts = fixture_artifacts(File.join(dir, "revision"))
      manifest_path = File.join(artifacts.candidate_dir, "manifest.json")
      manifest = JSON.parse(File.read(manifest_path))
      manifest["builder_revision"] = "drifted"
      File.write(manifest_path, JSON.generate(manifest))
      error = assert_raises(HiveReleaseCandidate::Error) { artifacts.verify! }
      assert_includes error.message, "builder revision"
    end
  end

  def test_artifact_path_collision_fails_before_any_build
    with_tmp_dir do |dir|
      candidate = File.join(dir, "candidate")
      File.write(candidate, "occupied")
      artifacts = HiveReleaseCandidate::Artifacts.new(
        repo_root: dir, candidate_sha: "a" * 40, candidate_dir: candidate
      )

      error = assert_raises(HiveReleaseCandidate::Error) { artifacts.call }
      assert_includes error.message, "collision"
      assert_equal "occupied", File.read(candidate)
    end
  end

  def test_builder_revision_tracks_the_exact_creator_contract_source_closure
    expected = %w[
      packaging/live_agent_skills/proof.rb
      packaging/live_agent_skills/proof_primitives.rb
      packaging/live_agent_skills/workflow_creator.rb
      packaging/live_agent_skills/workflow_creator_contract.rb
      packaging/live_agent_skills/workflow_creator_bundle.rb
      packaging/live_agent_skills/workflow_creator_execution_contract.rb
      packaging/live_agent_skills/build.rb
    ]
    assert_equal expected, HiveReleaseCandidate::Artifacts::LIVE_AGENT_BUILDER_INPUTS

    with_tmp_dir do |dir|
      export = File.join(dir, "export")
      expected.each do |relative|
        path = File.join(export, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "#{relative}\n")
      end
      artifacts = HiveReleaseCandidate::Artifacts.new(
        repo_root: dir, candidate_sha: "a" * 40,
        candidate_dir: File.join(dir, "candidate")
      )
      first = artifacts.send(:builder_revision, export)
      File.open(File.join(export, expected.fetch(4)), "a") { |file| file.write("drift\n") }
      second = artifacts.send(:builder_revision, export)

      refute_equal first, second
    end
  end

  def test_paths_reject_symlinked_root_and_nonblocking_concurrent_lock
    with_tmp_dir do |repo|
      safe_parent = File.join(repo, "tmp", "release-candidates")
      FileUtils.mkdir_p(safe_parent)
      outside = File.join(repo, "outside")
      FileUtils.mkdir_p(outside)
      linked = File.join(safe_parent, "linked")
      File.symlink(outside, linked)

      error = assert_raises(HiveReleaseCandidate::Error) do
        HiveReleaseCandidate::Paths.new(
          repo_root: repo, candidate_sha: "a" * 40, runs_root: linked
        )
      end
      assert_includes error.message, "symlink"

      paths = HiveReleaseCandidate::Paths.new(
        repo_root: repo,
        candidate_sha: "a" * 40,
        runs_root: File.join(safe_parent, "owned")
      )
      paths.prepare!
      File.open(paths.lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        assert lock.flock(File::LOCK_EX | File::LOCK_NB)
        error = assert_raises(HiveReleaseCandidate::TemporaryError) do
          paths.with_lock { flunk "concurrent caller must not enter the lock" }
        end
        assert_includes error.message, "already being operated"
      end
    end
  end

  def test_committed_coverage_identity_ignores_dirty_worktree_bytes
    with_tmp_dir do |repo|
      run_git(repo, "init", "-b", "main")
      run_git(repo, "config", "user.email", "test@example.com")
      run_git(repo, "config", "user.name", "Hive Test")
      FileUtils.mkdir_p(File.join(repo, "test/e2e"))
      FileUtils.mkdir_p(File.join(repo, "lib/hive"))
      FileUtils.mkdir_p(File.join(repo, ".github/workflows"))
      coverage = File.join(repo, "test/e2e/coverage.yml")
      File.write(coverage, "committed coverage\n")
      File.write(
        File.join(repo, "lib/hive/version.rb"),
        "module Hive; VERSION = \"0.6.9\"; end\n"
      )
      File.write(File.join(repo, ".github/workflows/ci.yml"), "name: CI\n")
      run_git(repo, "add", ".")
      run_git(repo, "commit", "-m", "fixture")
      sha = run_git(repo, "rev-parse", "HEAD").strip

      File.write(coverage, "dirty replacement\n")
      input = HiveReleaseCandidate::Repository.new(repo).inputs(sha).fetch("coverage")

      assert_equal "available", input.fetch("status")
      assert_equal Digest::SHA256.hexdigest("committed coverage\n"), input.fetch("sha256")
      refute_equal Digest::SHA256.file(coverage).hexdigest, input.fetch("sha256")
    end
  end

  private

  def fixture_artifacts(dir)
    candidate = File.join(dir, "candidate")
    FileUtils.mkdir_p(candidate)
    files = {
      "hive-cli-0.6.9.gem" => [ "gem", "gem bytes" ],
      "hive-agent-skills-#{'a' * 40}.tar.gz" => [ "skills", "skill bytes" ],
      "hive-web-0.6.9.tar.gz" => [ "web", "web bytes" ]
    }
    files.each do |name, (_kind, bytes)|
      path = File.join(candidate, name)
      File.binwrite(path, bytes)
    end
    source_name = "hive-source-#{'a' * 40}.tar.gz"
    builder_inputs = HiveReleaseCandidate::Artifacts::LIVE_AGENT_BUILDER_INPUTS.to_h do |path|
      [ path, "#{File.basename(path)} fixture\n" ]
    end
    build_source_fixture(
      File.join(candidate, source_name),
      builder_inputs: builder_inputs,
      root: dir
    )
    files[source_name] = [ "source", nil ]
    records = files.to_h do |name, (kind, _bytes)|
      path = File.join(candidate, name)
      [
        name,
        {
          "kind" => kind,
          "sha256" => Digest::SHA256.file(path).hexdigest,
          "size" => File.size(path)
        }
      ]
    end
    builder_digest = Digest::SHA256.new
    builder_inputs.each do |path, bytes|
      builder_digest << path << "\0" << bytes << "\0"
    end
    managed = File.expand_path("../../../packaging/managed_web_archive.rb", __dir__)
    builder_digest << "packaging/managed_web_archive.rb\0" << File.binread(managed) << "\0"
    manifest = {
      "schema" => HiveReleaseCandidate::Artifacts::MANIFEST_SCHEMA,
      "schema_version" => 1,
      "candidate_sha" => "a" * 40,
      "hive_version" => "0.6.9",
      "skill_version" => "1",
      "canonical_digest" => "b" * 64,
      "builder_revision" => builder_digest.hexdigest,
      "files" => records
    }
    File.write(File.join(candidate, "manifest.json"), JSON.generate(manifest))
    HiveReleaseCandidate::Artifacts.new(
      repo_root: dir, candidate_sha: "a" * 40, candidate_dir: candidate
    )
  end

  def build_source_fixture(destination, builder_inputs:, root:)
    stage = File.join(root, "source-stage")
    builder_inputs.each do |relative, bytes|
      path = File.join(stage, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, bytes)
    end
    _stdout, stderr, status = Open3.capture3("tar", "-czf", destination, "-C", stage, ".")
    raise stderr unless status.success?
  end

  def run_git(repo, *argv)
    stdout, stderr, status = Open3.capture3("git", *argv, chdir: repo)
    assert status.success?, stderr
    stdout
  end
end
