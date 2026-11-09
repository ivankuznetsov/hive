require "test_helper"
require "hive/secret_scanner"
require "hive/gh"

class SecretScannerTest < Minitest::Test
  include HiveTestHelper

  def test_text_scan_detects_a_secret_after_four_megabytes_without_echoing_it
    assert Hive::SecretScanner.match?("ordinary text\n" * 400_000 + token)
    refute Hive::SecretScanner.match?("operator.password = password\n", path: "setup.rb")
    assert Hive::SecretScanner.match?("\0#{token}\0", path: "screenshot.png")
  end

  def test_missing_scanner_is_unavailable_not_clean
    with_replaced_singleton_method(Open3, :capture3, ->(*) { raise Errno::ENOENT }) do
      error = assert_raises(Hive::SecretScanner::Unavailable) { Hive::SecretScanner.match?(token) }
      refute_includes error.message, token
    end
  end

  def test_scanner_errors_and_malformed_reports_fail_closed_without_echoing_output
    secret = token
    [ [ 1, token ], [ 0, "not json" ], [ 0, "{}" ], [ 42, "[]" ], [ 42, "[{}]" ], [ 42, "[null]" ] ].each do |code, output|
      status = Hive::Gh::CommandStatus.new(exitstatus: code)
      with_replaced_singleton_method(Open3, :capture3, ->(*) { [ output, secret, status ] }) do
        error = assert_raises(Hive::SecretScanner::Unavailable) { Hive::SecretScanner.scan("test") }
        refute_includes error.message, token
      end
    end
  end

  def test_git_scan_covers_removed_secrets_and_ignores_repository_suppressions
    with_tmp_dir do |repo|
      run!("git", "init", "-b", "main", "--quiet", repo)
      run!("git", "-C", repo, "config", "user.name", "Test")
      run!("git", "-C", repo, "config", "user.email", "test@example.com")
      File.write(File.join(repo, "base.txt"), "base\n")
      base = commit(repo)
      File.write(File.join(repo, "secret.txt"), "token=#{token} # betterleaks:allow\n")
      File.write(File.join(repo, ".betterleaks.toml"), "prefilter = 'true'\n")
      leaked = commit(repo)
      File.write(File.join(repo, ".betterleaksignore"), "#{leaked}:secret.txt:github-pat:1\n")
      File.write(File.join(repo, "secret.txt"), "removed\n")
      File.binwrite(File.join(repo, "image.png"), "\0#{token}\0")
      head = commit(repo)

      assert Hive::SecretScanner.git_match?(repo, base_oid: base, head_oid: head)
      assert Hive::SecretScanner.git_match?(repo, base_oid: leaked, head_oid: head),
             "binary-only additions must be scanned even when image files are normally skipped"
      refute Hive::SecretScanner.git_match?(repo, base_oid: head, head_oid: head)
      assert_raises(Hive::SecretScanner::Unavailable) do
        Hive::SecretScanner.git_match?(repo, base_oid: "f" * 40, head_oid: head)
      end
      assert_raises(Hive::SecretScanner::Unavailable) do
        Hive::SecretScanner.git_match?(repo, base_oid: "--help", head_oid: head)
      end
    end
  end

  def test_operator_can_allow_one_exact_git_finding_without_disabling_detection
    with_tmp_dir do |repo|
      run!("git", "init", "-b", "main", "--quiet", repo)
      run!("git", "-C", repo, "config", "user.name", "Test")
      run!("git", "-C", repo, "config", "user.email", "test@example.com")
      File.write(File.join(repo, "base.txt"), "base\n")
      base = commit(repo)
      File.write(File.join(repo, "fixture.txt"), "token=#{token}\n")
      first = commit(repo)
      with_tmp_dir do |policy|
        with_replaced_singleton_method(Hive::Paths, :config_home, -> { policy }) do
          hits = Hive::SecretScanner.git_findings(repo, base_oid: base, head_oid: first)
          assert_equal 1, hits.length
          File.write(File.join(policy, "betterleaks.ignore"), hits.first.fetch(:fingerprint) + "\n")
          refute Hive::SecretScanner.git_match?(repo, base_oid: base, head_oid: first)
          File.write(File.join(repo, "another.txt"), "token=#{token}\n")
          second = commit(repo)
          assert Hive::SecretScanner.git_match?(repo, base_oid: base, head_oid: second)
        end
      end
    end
  end

  def test_upstream_content_merged_into_the_task_branch_is_not_reattributed_to_the_task
    with_task_repo do |repo, base|
      upstream_fixture(repo)
      run!("git", "-C", repo, "update-ref", "refs/remotes/origin/main", "main")
      head = merge_upstream(repo)

      assert Hive::SecretScanner.git_match?(repo, base_oid: base, head_oid: head),
             "the unscoped history scan re-attributes upstream fixtures to the merge commit"
      assert_empty Hive::SecretScanner.git_findings(repo, base_oid: base, head_oid: head, upstream_branch: "main")
      assert_empty Hive::SecretScanner.git_findings(repo, base_oid: merge_base(repo, head), head_oid: head,
                                                    upstream_branch: "main")
    end
  end

  def test_task_commit_secret_is_reported_after_merging_upstream
    with_task_repo do |repo, base|
      upstream_fixture(repo)
      File.write(File.join(repo, "task.txt"), "token=#{other_token}\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "Task secret", "--quiet")
      head = merge_upstream(repo)

      hits = Hive::SecretScanner.git_findings(repo, base_oid: base, head_oid: head, upstream_branch: "main")
      refute_empty hits
      assert hits.all? { |hit| hit.fetch(:path) == "task.txt" }
      assert hits.none? { |hit| hit.key?(:commit) }
    end
  end

  def test_secret_introduced_only_by_merge_conflict_resolution_is_reported
    with_task_repo do |repo, base|
      File.write(File.join(repo, "shared.txt"), "task side\n")
      run!("git", "-C", repo, "commit", "-am", "Task edit", "--quiet")
      run!("git", "-C", repo, "checkout", "--quiet", "main")
      File.write(File.join(repo, "shared.txt"), "upstream side\n")
      run!("git", "-C", repo, "commit", "-am", "Upstream edit", "--quiet")
      run!("git", "-C", repo, "checkout", "--quiet", "task")
      _out, _err, status = Open3.capture3("git", "-C", repo, "merge", "--no-edit", "main")
      refute status.success?, "the fixture must produce a merge conflict"
      File.write(File.join(repo, "shared.txt"), "token=#{other_token}\n")
      head = commit(repo)

      hits = Hive::SecretScanner.git_findings(repo, base_oid: base, head_oid: head, upstream_branch: "main")
      assert_equal [ "shared.txt" ], hits.map { |hit| hit.fetch(:path) }.uniq
    end
  end

  def test_unscopable_upstream_keeps_the_full_history_scan
    with_task_repo do |repo, base|
      upstream_fixture(repo)
      head = merge_upstream(repo)

      [ nil, " ", "missing-branch", "--bad" ].each do |branch|
        assert Hive::SecretScanner.git_match?(repo, base_oid: base, head_oid: head, upstream_branch: branch),
               "upstream #{branch.inspect} must fall back to the full scan"
      end
      run!("git", "-C", repo, "checkout", "--quiet", "--orphan", "unrelated")
      run!("git", "-C", repo, "commit", "--quiet", "--allow-empty", "-m", "Unrelated root")
      assert Hive::SecretScanner.git_match?(repo, base_oid: base, head_oid: head, upstream_branch: "unrelated"),
             "histories without a merge base keep the full scan"
      run!("git", "-C", repo, "update-ref", "refs/remotes/origin/main", head)
      assert Hive::SecretScanner.git_match?(repo, base_oid: base, head_oid: head, upstream_branch: "main"),
             "a head already on upstream keeps the full scan"
    end
  end

  def test_git_failures_while_scoping_fail_closed
    with_task_repo do |repo, base|
      upstream_fixture(repo)
      head = merge_upstream(repo)
      original = Hive::AgentGitGate.method(:read)
      broken = lambda do |result_for|
        lambda do |path, operation, **options|
          result_for.call(operation, options) || original.call(path, operation, **options)
        end
      end

      failed = lambda do |operation, _options|
        next unless operation == :ancestor

        Hive::AgentGitGate::ReadResult.new(operation: :ancestor, stdout: "", stderr: "fatal",
                                          exitstatus: 128, overflow: false)
      end
      with_replaced_singleton_method(Hive::AgentGitGate, :read, broken.call(failed)) do
        assert_raises(Hive::SecretScanner::Unavailable) do
          Hive::SecretScanner.git_findings(repo, base_oid: base, head_oid: head, upstream_branch: "main")
        end
      end

      invalid = ->(operation, _options) { raise Hive::AgentGitGate::InvalidRequest, "bad" if operation == :ancestor }
      with_replaced_singleton_method(Hive::AgentGitGate, :read, broken.call(invalid)) do
        assert_raises(Hive::SecretScanner::Unavailable) do
          Hive::SecretScanner.git_findings(repo, base_oid: base, head_oid: head, upstream_branch: "main")
        end
      end

      unreadable = lambda do |operation, options|
        raise Hive::AgentGitGate::InvalidRequest, "bad" if operation == :object_content && options[:path]
      end
      with_replaced_singleton_method(Hive::AgentGitGate, :read, broken.call(unreadable)) do
        refute_empty Hive::SecretScanner.git_findings(repo, base_oid: base, head_oid: head, upstream_branch: "main"),
                     "an unreadable upstream blob keeps the finding"
      end
    end
  end

  private

  def other_token
    "ghp_" + "Zy9Xw8Vu7Ts6Rq5Po4Nm3Lk2Ji1Hg0FeDcBa"
  end

  def with_task_repo
    with_tmp_dir do |repo|
      run!("git", "init", "-b", "main", "--quiet", repo)
      run!("git", "-C", repo, "config", "user.name", "Test")
      run!("git", "-C", repo, "config", "user.email", "test@example.com")
      File.write(File.join(repo, "base.txt"), "base\n")
      File.write(File.join(repo, "shared.txt"), "shared\n")
      base = commit(repo)
      run!("git", "-C", repo, "checkout", "--quiet", "-b", "task")
      File.write(File.join(repo, "feature.txt"), "feature\n")
      commit(repo)
      yield repo, base
    end
  end

  def upstream_fixture(repo)
    run!("git", "-C", repo, "checkout", "--quiet", "main")
    File.write(File.join(repo, "fixture.txt"), "token=#{token}\n")
    commit(repo)
    run!("git", "-C", repo, "checkout", "--quiet", "task")
  end

  def merge_upstream(repo)
    run!("git", "-C", repo, "merge", "--no-ff", "--no-edit", "--quiet", "main")
    run!("git", "-C", repo, "rev-parse", "HEAD").strip
  end

  def merge_base(repo, head)
    run!("git", "-C", repo, "merge-base", "main", head).strip
  end

  def token
    "ghp_" + "aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hI6"
  end

  def commit(repo)
    run!("git", "-C", repo, "add", ".")
    run!("git", "-C", repo, "commit", "-m", "Test change", "--quiet")
    run!("git", "-C", repo, "rev-parse", "HEAD").strip
  end
end
