require "test_helper"
require "hive/daemon/auto_retry_safety"

class HiveDaemonAutoRetrySafetyTest < Minitest::Test
  include HiveTestHelper

  Row = Struct.new(:folder, :stage, :marker, keyword_init: true)
  FakeGit = Struct.new(:status) do
    def status_short
      status
    end
  end

  def row(folder:, stage:, marker: "error")
    Row.new(folder: folder, stage: stage, marker: marker)
  end

  def write_pointer(folder, path)
    File.write(File.join(folder, "worktree.yml"), { "path" => path }.to_yaml)
  end

  def test_refuses_terminal_success_marker
    with_tmp_dir do |dir|
      ok, reason = Hive::Daemon::AutoRetrySafety.safe_to_retry?(
        row(folder: dir, stage: "4-execute", marker: "execute_complete")
      )

      assert_equal false, ok
      assert_includes reason, "terminal success"
    end
  end

  def test_execute_clean_worktree_is_safe
    with_tmp_dir do |dir|
      worktree = File.join(dir, "wt")
      FileUtils.mkdir_p(worktree)
      write_pointer(dir, worktree)

      with_replaced_singleton_method(Hive::GitOps, :new, ->(_path) { FakeGit.new("") }) do
        ok, reason = Hive::Daemon::AutoRetrySafety.safe_to_retry?(row(folder: dir, stage: "4-execute"))

        assert_equal true, ok
        assert_equal "worktree clean", reason
      end
    end
  end

  def test_execute_dirty_worktree_is_unsafe
    with_tmp_dir do |dir|
      worktree = File.join(dir, "wt")
      FileUtils.mkdir_p(worktree)
      write_pointer(dir, worktree)

      with_replaced_singleton_method(Hive::GitOps, :new, ->(_path) { FakeGit.new(" M app.rb\n") }) do
        ok, reason = Hive::Daemon::AutoRetrySafety.safe_to_retry?(row(folder: dir, stage: "4-execute"))

        assert_equal false, ok
        assert_equal "worktree dirty", reason
      end
    end
  end

  def test_execute_missing_worktree_pointer_defers_to_runner_validation
    with_tmp_dir do |dir|
      ok, reason = Hive::Daemon::AutoRetrySafety.safe_to_retry?(row(folder: dir, stage: "4-execute"))

      assert_equal true, ok
      assert_includes reason, "missing worktree pointer"
    end
  end

  def test_brainstorm_answered_content_is_unsafe
    with_tmp_dir do |dir|
      File.write(File.join(dir, "brainstorm.md"), <<~MD)
        ## Round 1
        ### Q1. What?
        ### A1.
        User answer
      MD

      ok, reason = Hive::Daemon::AutoRetrySafety.safe_to_retry?(row(folder: dir, stage: "2-brainstorm"))

      assert_equal false, ok
      assert_includes reason, "answers present"
    end
  end

  def test_brainstorm_without_answers_is_safe
    with_tmp_dir do |dir|
      File.write(File.join(dir, "brainstorm.md"), <<~MD)
        ## Round 1
        ### Q1. What?
        ### A1.
      MD

      ok, reason = Hive::Daemon::AutoRetrySafety.safe_to_retry?(row(folder: dir, stage: "2-brainstorm"))

      assert_equal true, ok
      assert_includes reason, "no brainstorm answers"
    end
  end

  def test_plan_feedback_is_unsafe
    with_tmp_dir do |dir|
      File.write(File.join(dir, "plan.md"), "## User feedback\nPlease change the approach.\n")

      ok, reason = Hive::Daemon::AutoRetrySafety.safe_to_retry?(row(folder: dir, stage: "3-plan"))

      assert_equal false, ok
      assert_includes reason, "feedback"
    end
  end

  def test_inspection_errors_fail_closed
    with_tmp_dir do |dir|
      with_replaced_singleton_method(Hive::Worktree, :read_pointer, ->(_folder) { raise "boom" }) do
        ok, reason = Hive::Daemon::AutoRetrySafety.safe_to_retry?(row(folder: dir, stage: "4-execute"))

        assert_equal false, ok
        assert_includes reason, "inspection failed"
      end
    end
  end

  def test_plan_without_feedback_is_safe
    with_tmp_dir do |dir|
      File.write(File.join(dir, "plan.md"), "## Steps\n1. Build the thing.\n2. Ship it.\n")

      ok, reason = Hive::Daemon::AutoRetrySafety.safe_to_retry?(row(folder: dir, stage: "3-plan"))

      assert_equal true, ok, "a plan with no feedback keywords must be safe to retry"
      assert_equal "no plan feedback detected", reason
    end
  end

  def test_unenumerated_stage_defers_to_runner_validation
    with_tmp_dir do |dir|
      ok, reason = Hive::Daemon::AutoRetrySafety.safe_to_retry?(row(folder: dir, stage: "7-artifacts"))

      assert_equal true, ok, "a stage with no mutable-work guard must remain retryable"
      assert_match(/no mutable work-area guard required for stage 7-artifacts/, reason)
    end
  end
end
