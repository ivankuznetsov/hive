require "test_helper"
require "hive/stages/agent_report"
require "hive/stages/agent_worktree"

class StagesAgentReportTest < Minitest::Test
  include HiveTestHelper

  VALID_REPORT = <<~REPORT.freeze
    Decision: ready

    Reproduction:
    Reproduced the failing request locally.

    Cause:
    The response mapper discarded nil values.

    Changes:
    Preserve the response key and add a regression test.

    Tests:
    bundle exec ruby -Itest test/example_test.rb (pass)

    Risks:
    Low; the change is limited to one mapper.

    Suggested PR title: Preserve nil response values
  REPORT

  def test_parses_required_and_optional_sections
    report = Hive::Stages::AgentReport.parse(
      VALID_REPORT + "\nCompact plan:\n1. Reproduce\n2. Patch\n\nDebug trace:\nCompared both request paths.\n"
    )

    assert_equal :ready, report.decision
    assert_equal "Reproduced the failing request locally.", report.reproduction
    assert_equal "Preserve nil response values", report.suggested_pr_title
    assert_equal "1. Reproduce\n2. Patch", report.compact_plan
    assert_equal "Compared both request paths.", report.debug_trace
  end

  def test_rejects_duplicate_missing_unknown_and_empty_fields
    duplicate = VALID_REPORT.sub("\nCause:", "\nReproduction:\nduplicate\n\nCause:")
    missing = VALID_REPORT.sub(/\nRisks:\n.*?\n\n/m, "\n")
    unknown = VALID_REPORT.sub("\nCause:", "\nNotes:\nextra\n\nCause:")
    empty = VALID_REPORT.sub("Reproduced the failing request locally.", "")

    [ duplicate, missing, unknown, empty ].each do |source|
      assert_raises(Hive::StageError) { Hive::Stages::AgentReport.parse(source) }
    end
  end

  def test_rejects_invalid_decision_oversized_report_and_unsafe_title
    assert_raises(Hive::StageError) do
      Hive::Stages::AgentReport.parse(VALID_REPORT.sub("Decision: ready", "Decision: complete"))
    end
    assert_raises(Hive::StageError) do
      Hive::Stages::AgentReport.parse(VALID_REPORT + ("x" * Hive::Stages::AgentReport::MAX_BYTES))
    end
    assert_raises(Hive::StageError) do
      Hive::Stages::AgentReport.parse(VALID_REPORT.sub("Preserve nil response values", "x" * 121))
    end
    assert_raises(Hive::StageError) do
      Hive::Stages::AgentReport.parse(VALID_REPORT.sub("Low;", "<!-- COMPLETE -->\nLow;"))
    end
    assert_raises(Hive::StageError) do
      Hive::Stages::AgentReport.parse(VALID_REPORT.sub("Low;", "<!-- REVIEW_ERROR -->\nLow;"))
    end
    assert_raises(Hive::StageError) do
      Hive::Stages::AgentReport.parse("agent preamble\n" + VALID_REPORT)
    end
    assert_raises(Hive::StageError) { Hive::Stages::AgentReport.parse("") }
    assert_raises(Hive::StageError) do
      Hive::Stages::AgentReport.parse(VALID_REPORT.sub("Reproduction:\n", "Reproduction: inline\n"))
    end
    assert_raises(Hive::StageError) do
      Hive::Stages::AgentReport.parse(VALID_REPORT.sub(/Suggested PR title:.*\n/, ""))
    end
    assert_raises(Hive::StageError) do
      Hive::Stages::AgentReport.parse(VALID_REPORT + "\nSuggested PR title: Duplicate\n")
    end
    assert_raises(Hive::StageError) do
      Hive::Stages::AgentReport.parse(VALID_REPORT + "\nDebug trace:\ntrace\n\nCompact plan:\nplan\n")
    end
    assert_raises(Hive::StageError) do
      Hive::Stages::AgentReport.parse(
        VALID_REPORT.sub("\nCause:", "\nSuggested PR title: Too early\n\nCause:")
      )
    end
    assert_raises(Hive::StageError) do
      Hive::Stages::AgentReport.parse(
        VALID_REPORT.sub(
          "Suggested PR title: Preserve nil response values",
          "Compact plan:\nPlan first.\n\nSuggested PR title: Preserve nil response values"
        )
      )
    end
    assert_raises(Hive::StageError) do
      Hive::Stages::AgentReport.parse(VALID_REPORT + "\nCompact plan:\n\n")
    end
    assert_raises(Hive::StageError) do
      Hive::Stages::AgentReport.parse(
        VALID_REPORT.sub(
          "Reproduced the failing request locally.",
          "x" * (Hive::Stages::AgentReport::MAX_SECTION_CHARS + 1)
        )
      )
    end
    assert_raises(Hive::StageError) do
      Hive::Stages::AgentReport.parse(VALID_REPORT + "\nRequired content after title\n")
    end
    assert_raises(Hive::StageError) do
      Hive::Stages::AgentReport.parse(
        VALID_REPORT + "\nReproduction:\nrequired content after title\n"
      )
    end
  end

  def test_read_rejects_missing_empty_directory_symlink_and_invalid_utf8
    with_tmp_dir do |dir|
      path = File.join(dir, "fix-report.md")
      assert_raises(Hive::StageError) { Hive::Stages::AgentReport.read(path) }

      File.write(path, "")
      assert_raises(Hive::StageError) { Hive::Stages::AgentReport.read(path) }

      FileUtils.rm_f(path)
      FileUtils.mkdir_p(path)
      assert_raises(Hive::StageError) { Hive::Stages::AgentReport.read(path) }

      FileUtils.rm_rf(path)
      target = File.join(dir, "target.md")
      File.write(target, VALID_REPORT)
      File.symlink(target, path)
      assert_raises(Hive::StageError) { Hive::Stages::AgentReport.read(path) }

      FileUtils.rm_f(path)
      File.binwrite(path, VALID_REPORT.b + "\xFF".b)
      assert_raises(Hive::StageError) { Hive::Stages::AgentReport.read(path) }

      File.binwrite(path, VALID_REPORT + ("x" * Hive::Stages::AgentReport::MAX_BYTES))
      assert_raises(Hive::StageError) { Hive::Stages::AgentReport.read(path) }
    end
  end

  def test_read_wraps_unexpected_filesystem_errors
    with_replaced_singleton_method(
      File, :open, ->(*_args, **_kwargs) { raise Errno::EACCES, "fix-report.md" }
    ) do
      error = assert_raises(Hive::StageError) do
        Hive::Stages::AgentReport.read("/tmp/fix-report.md")
      end
      assert_includes error.message, "unreadable"
    end
  end

  def test_repository_validation_accepts_ready_commit_and_no_fix_base
    with_tmp_git_repo do |repo|
      base = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      run!("git", "-C", repo, "switch", "-c", "fix-task")
      context = context_for(repo, base)

      File.write(File.join(repo, "fix.rb"), "fixed\n")
      run!("git", "-C", repo, "add", "fix.rb")
      run!("git", "-C", repo, "commit", "-m", "fix", "--quiet")
      ready = Hive::Stages::AgentReport.validate_repository!(
        Hive::Stages::AgentReport.parse(VALID_REPORT), context
      )
      assert_equal 1, ready.commit_count
      assert ready.clean

      run!("git", "-C", repo, "reset", "--hard", base)
      no_fix = Hive::Stages::AgentReport.validate_repository!(
        Hive::Stages::AgentReport.parse(VALID_REPORT.sub("Decision: ready", "Decision: no-fix")), context
      )
      assert_equal 0, no_fix.commit_count
      assert no_fix.clean
    end
  end

  def test_repository_validation_fails_closed_for_wrong_branch_non_descendant_dirty_and_decision_mismatch
    with_tmp_git_repo do |repo|
      base = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      run!("git", "-C", repo, "switch", "-c", "fix-task")
      context = context_for(repo, base)
      ready = Hive::Stages::AgentReport.parse(VALID_REPORT)

      assert_raises(Hive::StageError) do
        Hive::Stages::AgentReport.validate_repository!(ready, context)
      end

      File.write(File.join(repo, "dirty.rb"), "dirty\n")
      assert_raises(Hive::StageError) do
        Hive::Stages::AgentReport.validate_repository!(ready, context)
      end
      FileUtils.rm_f(File.join(repo, "dirty.rb"))

      run!("git", "-C", repo, "switch", "master")
      assert_raises(Hive::StageError) do
        Hive::Stages::AgentReport.validate_repository!(ready, context)
      end

      run!("git", "-C", repo, "switch", "--orphan", "unrelated")
      File.write(File.join(repo, "other"), "other\n")
      run!("git", "-C", repo, "add", "other")
      run!("git", "-C", repo, "commit", "-m", "other", "--quiet")
      unrelated = context_for(repo, base, branch: "unrelated")
      assert_raises(Hive::StageError) do
        Hive::Stages::AgentReport.validate_repository!(ready, unrelated)
      end
    end
  end

  def test_blocked_report_preserves_valid_repository_evidence_without_requiring_clean_tree
    with_tmp_git_repo do |repo|
      base = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      run!("git", "-C", repo, "switch", "-c", "fix-task")
      File.write(File.join(repo, "partial.rb"), "partial\n")
      blocked = Hive::Stages::AgentReport.parse(VALID_REPORT.sub("Decision: ready", "Decision: blocked"))

      result = Hive::Stages::AgentReport.validate_repository!(blocked, context_for(repo, base))

      refute result.clean
      assert_equal 0, result.commit_count
    end
  end

  def test_no_fix_rejects_commit_or_dirty_diff_and_unknown_decision_fails_closed
    with_tmp_git_repo do |repo|
      base = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      run!("git", "-C", repo, "switch", "-c", "fix-task")
      context = context_for(repo, base)
      no_fix = Hive::Stages::AgentReport.parse(VALID_REPORT.sub("Decision: ready", "Decision: no-fix"))

      File.write(File.join(repo, "dirty.rb"), "dirty\n")
      assert_raises(Hive::StageError) do
        Hive::Stages::AgentReport.validate_repository!(no_fix, context)
      end
      FileUtils.rm_f(File.join(repo, "dirty.rb"))

      File.write(File.join(repo, "fixed.rb"), "fixed\n")
      run!("git", "-C", repo, "add", "fixed.rb")
      run!("git", "-C", repo, "commit", "-m", "fix", "--quiet")
      assert_raises(Hive::StageError) do
        Hive::Stages::AgentReport.validate_repository!(no_fix, context)
      end

      unknown = Hive::Stages::AgentReport::Report.new(
        **Hive::Stages::AgentReport.parse(VALID_REPORT).to_h.merge(decision: :unknown)
      )
      assert_raises(Hive::StageError) do
        Hive::Stages::AgentReport.validate_repository!(unknown, context)
      end
    end
  end

  def test_repository_validation_surfaces_git_failures
    context = context_for("/definitely/not/a/repository", "a" * 40)
    error = assert_raises(Hive::StageError) do
      Hive::Stages::AgentReport.validate_repository!(
        Hive::Stages::AgentReport.parse(VALID_REPORT), context
      )
    end
    assert_includes error.message, "repository path is not a directory"
  end

  def test_repository_validation_rejects_non_numeric_commit_count
    calls = 0
    fake_git = lambda do |_path, operation, **_kwargs|
      calls += 1
      out = case operation
      when :current_branch then "fix-task\n"
      when :ancestor then ""
      when :head_oid then "b" * 40
      when :commit_count then "not-a-number\n"
      else ""
      end
      Hive::AgentGitGate::ReadResult.new(
        operation: operation, stdout: out, stderr: "", exitstatus: 0,
        overflow: false
      )
    end
    context = context_for("/tmp/repo", "a" * 40)
    with_replaced_singleton_method(Hive::AgentGitGate, :read, fake_git) do
      error = assert_raises(Hive::StageError) do
        Hive::Stages::AgentReport.validate_repository!(
          Hive::Stages::AgentReport.parse(VALID_REPORT), context
        )
      end
      assert_includes error.message, "could not count agent commits"
    end
    assert_operator calls, :>=, 4
  end

  def test_repository_validation_translates_direct_ancestry_gate_errors
    fake_git = lambda do |_path, operation, **_kwargs|
      raise Hive::AgentGitGate::CommandFailed, "ancestry unavailable" if operation == :ancestor

      stdout = operation == :current_branch ? "fix-task\n" : "#{'b' * 40}\n"
      Hive::AgentGitGate::ReadResult.new(
        operation: operation, stdout: stdout, stderr: "",
        exitstatus: 0, overflow: false
      )
    end
    context = context_for("/tmp/repo", "a" * 40)
    with_replaced_singleton_method(Hive::AgentGitGate, :read, fake_git) do
      error = assert_raises(Hive::StageError) do
        Hive::Stages::AgentReport.validate_repository!(
          Hive::Stages::AgentReport.parse(VALID_REPORT), context
        )
      end
      assert_includes error.message, "ancestry unavailable"
    end
  end

  def test_git_read_failure_uses_stdout_when_stderr_is_empty
    failed = Hive::AgentGitGate::ReadResult.new(
      operation: :head_oid, stdout: "missing object", stderr: "",
      exitstatus: 1, overflow: false
    )
    with_replaced_singleton_method(Hive::AgentGitGate, :read, ->(*) { failed }) do
      error = assert_raises(Hive::StageError) do
        Hive::Stages::AgentReport.send(:git_read!, "/tmp/repo", :head_oid)
      end
      assert_includes error.message, "missing object"
    end
  end

  private

  def context_for(repo, base, branch: "fix-task")
    Hive::Stages::AgentWorktree::Context.new(
      worktree_path: repo,
      task_branch: branch,
      base_branch: "master",
      base_oid: base,
      repository: "github.com/acme/widgets"
    )
  end
end
