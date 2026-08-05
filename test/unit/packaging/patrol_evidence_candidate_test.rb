require "test_helper"
require "digest"
require "json"
require_relative "../../../packaging/patrol_evidence/candidate"

class PatrolEvidenceCandidateTest < Minitest::Test
  include HiveTestHelper

  Candidate = HivePatrolEvidence::Candidate

  def test_archives_one_distinct_commit_and_streams_a_bounded_regular_inventory
    with_candidate_repository do |fixture|
      with_tmp_dir do |run_root|
        owner = Candidate.new(
          repo_root: fixture.fetch(:repo), controller_sha: fixture.fetch(:controller_sha),
          candidate_sha: fixture.fetch(:candidate_sha)
        )

        record = owner.prepare!(run_root:)

        assert_equal fixture.fetch(:candidate_sha), record.fetch("candidate_sha")
        assert_equal Digest::SHA256.file(record.fetch("archive_path")).hexdigest,
                     record.fetch("archive_sha256")
        assert_operator record.fetch("archive_member_count"), :>, 0
        assert_operator record.fetch("archive_total_bytes"), :>, 0
        assert_equal %w[architecture-patrol patrol], record.fetch("module_manifests").keys
        assert record.fetch("module_manifest_sha256").match?(/\A[0-9a-f]{64}\z/)
        assert record.fetch("source_tree_sha256").match?(/\A[0-9a-f]{64}\z/)
        assert_equal 0o555, File.stat(record.fetch("source_path")).mode & 0o777
        source_files = Dir.glob(File.join(record.fetch("source_path"), "**", "*"))
                          .select { |path| File.file?(path) }
        assert source_files.all? { |path| [ 0o444, 0o555 ].include?(File.stat(path).mode & 0o777) }
      end
    end
  end

  def test_verification_binds_the_complete_before_and_after_installed_closure
    with_candidate_repository do |fixture|
      with_tmp_dir do |run_root|
        owner = Candidate.new(
          repo_root: fixture.fetch(:repo), controller_sha: fixture.fetch(:controller_sha),
          candidate_sha: fixture.fetch(:candidate_sha)
        )
        prepared = owner.prepare!(run_root:)
        identity = installed_identity(prepared)
        receipt = {
          "candidate" => {
            "candidate_sha" => fixture.fetch(:candidate_sha),
            "archive_sha256" => prepared.fetch("archive_sha256"),
            "identity_before" => identity,
            "identity_after" => Marshal.load(Marshal.dump(identity))
          }
        }

        admitted = owner.verify!(receipt:)

        assert_equal identity.fetch("dependency_closure_sha256"),
                     admitted.fetch("dependency_closure_sha256")
        assert_equal identity.fetch("installed_hive_sha256"), admitted.fetch("installed_hive_sha256")

        archive_bytes = File.binread(prepared.fetch("archive_path"))
        File.binwrite(prepared.fetch("archive_path"), "changed archive\n")
        error = assert_raises(Candidate::Error) { owner.verify!(receipt:) }
        assert_equal "candidate_identity", error.reason
        File.binwrite(prepared.fetch("archive_path"), archive_bytes)

        receipt["candidate"]["identity_after"]["installed_hive_sha256"] = digest("changed")
        error = assert_raises(Candidate::Error) { owner.verify!(receipt:) }
        assert_equal "candidate_identity", error.reason

        source_file = File.join(prepared.fetch("source_path"), "candidate.txt")
        File.chmod(0o644, source_file)
        File.binwrite(source_file, "changed source\n")
        error = assert_raises(Candidate::Error) { owner.verify!(receipt:) }
        assert_equal "candidate_identity", error.reason
      end
    end
  end

  def test_hostile_archive_campaign_is_opt_in
    skip "set HIVE_HOSTILE_TESTS=1 for archive/path campaign" unless ENV["HIVE_HOSTILE_TESTS"] == "1"

    with_tmp_dir do |root|
      archive = File.join(root, "hostile.tar")
      File.open(archive, "wb") do |file|
        Gem::Package::TarWriter.new(file) { |tar| tar.add_symlink("escape", "../../outside", 0o777) }
      end
      assert_raises(Candidate::Error) do
        Candidate.send(:inspect_archive!, archive)
      end
    end
  end

  private

  def installed_identity(prepared)
    closure = [
      { "basename" => "hive-cli-0.7.0.gemspec", "bytesize" => 12,
        "spec_sha256" => digest("spec") }
    ]
    {
      "gem_sha256" => digest("gem"),
      "installed_hive_sha256" => digest("hive"),
      "module_manifest_sha256" => prepared.fetch("module_manifest_sha256"),
      "source_tree_sha256" => prepared.fetch("source_tree_sha256"),
      "dependency_closure" => closure,
      "dependency_closure_sha256" => digest(canonical_json(closure)),
      "toolchain" => {
        "ruby" => "ruby 3.4", "rubygems" => "3.6", "bundler" => "2.6"
      },
      "toolchain_sha256" => digest(canonical_json(
        "bundler" => "2.6", "ruby" => "ruby 3.4", "rubygems" => "3.6"
      ))
    }
  end

  def with_candidate_repository
    with_tmp_dir do |root|
      repo = File.join(root, "repo")
      FileUtils.mkdir_p(File.join(repo, "modules", "patrol"))
      FileUtils.mkdir_p(File.join(repo, "modules", "architecture-patrol"))
      system("git", "init", "-b", "main", "--quiet", repo) or raise
      File.write(File.join(repo, "README.md"), "controller\n")
      %w[architecture-patrol patrol].each do |name|
        File.write(File.join(repo, "modules", name, "manifest.yml"), <<~YAML)
          name: #{name}
          version: 1.0.0
          release_sha256: #{digest(name)}
          source:
            revision: #{"a" * 40}
        YAML
      end
      commit(repo, "controller")
      controller_sha = git(repo, "rev-parse", "HEAD")
      File.write(File.join(repo, "candidate.txt"), "candidate\n")
      commit(repo, "candidate")
      candidate_sha = git(repo, "rev-parse", "HEAD")
      yield repo:, controller_sha:, candidate_sha:
    end
  end

  def commit(repo, message)
    system("git", "-C", repo, "add", ".") or raise
    system("git", "-C", repo, "-c", "user.name=Hive", "-c", "user.email=hive@example.invalid",
           "commit", "-m", message, "--quiet") or raise
  end

  def git(repo, *argv) = IO.popen([ "git", "-C", repo, *argv ], &:read).strip
  def canonical_json(value)
    normalized = case value
    when Hash then value.keys.sort.to_h { |key| [ key, JSON.parse(canonical_json(value.fetch(key))) ] }
    when Array then value.map { |item| JSON.parse(canonical_json(item)) }
    else value
    end
    JSON.generate(normalized)
  end
  def digest(value) = Digest::SHA256.hexdigest(value)
end
