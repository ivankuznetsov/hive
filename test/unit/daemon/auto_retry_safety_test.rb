require "test_helper"
require "hive/daemon/auto_retry_safety"

class HiveDaemonAutoRetrySafetyTest < Minitest::Test
  include HiveTestHelper

  Row = Struct.new(:folder, :stage, :marker, :marker_attrs, :state_file, keyword_init: true)
  FakeGit = Struct.new(:status) do
    def status_short
      status
    end
  end

  def row(folder:, stage:, marker: "error", marker_attrs: {})
    Row.new(
      folder: folder, stage: stage, marker: marker,
      marker_attrs: marker_attrs, state_file: File.join(folder, "task.md")
    )
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

  def test_marker_attrs_defaults_to_an_empty_hash_for_unknown_row_shapes
    assert_equal(
      {},
      Hive::Daemon::AutoRetrySafety.send(:marker_attrs, Object.new)
    )
  end

  def test_execute_clean_worktree_is_safe
    with_tmp_dir do |dir|
      worktree = File.join(dir, "wt")
      FileUtils.mkdir_p(worktree)
      write_pointer(dir, worktree)

      with_replaced_singleton_method(
        Hive::Daemon::AutoRetrySafety,
        :owned_worktree_safe?,
        ->(_row) { [ true, "worktree ownership verified", worktree ] }
      ) do
        with_replaced_singleton_method(Hive::GitOps, :new, ->(_path) { FakeGit.new("") }) do
          ok, reason = Hive::Daemon::AutoRetrySafety.safe_to_retry?(row(folder: dir, stage: "4-execute"))

          assert_equal true, ok
          assert_equal "worktree clean", reason
        end
      end
    end
  end

  def test_execute_dirty_worktree_is_unsafe
    with_tmp_dir do |dir|
      worktree = File.join(dir, "wt")
      FileUtils.mkdir_p(worktree)
      write_pointer(dir, worktree)

      with_replaced_singleton_method(
        Hive::Daemon::AutoRetrySafety,
        :owned_worktree_safe?,
        ->(_row) { [ true, "worktree ownership verified", worktree ] }
      ) do
        with_replaced_singleton_method(Hive::GitOps, :new, ->(_path) { FakeGit.new(" M app.rb\n") }) do
          ok, reason = Hive::Daemon::AutoRetrySafety.safe_to_retry?(row(folder: dir, stage: "4-execute"))

          assert_equal false, ok
          assert_equal "worktree dirty", reason
        end
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

  def test_pointer_stages_delegate_to_the_owned_worktree_validator
    with_tmp_dir do |dir|
      File.write(File.join(dir, "worktree.yml"), "path: /trusted/worktree\nbranch: task\n")
      task = Struct.new(:folder, :project_root, :slug)
                   .new(dir, "/trusted/project", "task")
      observed = nil

      with_replaced_singleton_method(Hive::Task, :new, ->(_folder) { task }) do
        with_replaced_singleton_method(
          Hive::Worktree, :canonical_root, ->(_project_root) { "/trusted/root" }
        ) do
          with_replaced_singleton_method(
            Hive::Worktree, :read_owned_pointer, lambda { |folder, **kwargs|
              observed = [ folder, kwargs ]
              { "path" => "/trusted/worktree", "branch" => "task" }
            }
          ) do
            ok, reason = Hive::Daemon::AutoRetrySafety.safe_to_retry?(
              row(folder: dir, stage: "5-open-pr")
            )

            assert_equal true, ok
            assert_equal "worktree ownership verified", reason
          end
        end
      end

      assert_equal(
        [
          dir,
          {
            project_root: "/trusted/project",
            slug: "task",
            expected_root: "/trusted/root"
          }
        ],
        observed
      )
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
      File.write(File.join(dir, "worktree.yml"), "---\n")
      with_replaced_singleton_method(
        Hive::Daemon::AutoRetrySafety, :owned_worktree_safe?, ->(_row) { raise "boom" }
      ) do
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

  def test_unrestored_tamper_is_unsafe_but_restored_tamper_can_retry
    with_tmp_dir do |dir|
      unsafe, unsafe_reason = Hive::Daemon::AutoRetrySafety.safe_to_retry?(
        row(
          folder: dir,
          stage: "7-artifacts",
          marker_attrs: { "reason" => "fix_tampered", "restored" => "false" }
        )
      )
      safe, safe_reason = Hive::Daemon::AutoRetrySafety.safe_to_retry?(
        row(
          folder: dir,
          stage: "7-artifacts",
          marker_attrs: { "reason" => "fix_tampered", "restored" => "true" }
        )
      )

      assert_equal false, unsafe
      assert_includes unsafe_reason, "not restored"
      assert_equal true, safe
      assert_includes safe_reason, "no mutable work-area guard"
    end
  end

  def test_secret_retry_waits_until_the_local_pr_source_is_clean
    with_tmp_dir do |dir|
      state_file = File.join(dir, "task.md")
      File.write(state_file, "token: sk-abcdefghijklmnopqrstuvwxyz1234\n")
      blocked, reason = Hive::Daemon::AutoRetrySafety.safe_to_retry?(
        row(
          folder: dir,
          stage: "7-artifacts",
          marker_attrs: { "reason" => "secret_in_pr_body" }
        )
      )
      File.write(state_file, "credential removed\n")
      safe, safe_reason = Hive::Daemon::AutoRetrySafety.safe_to_retry?(
        row(
          folder: dir,
          stage: "7-artifacts",
          marker_attrs: { "reason" => "secret_in_pr_body" }
        )
      )

      assert_equal false, blocked
      assert_includes reason, "credential pattern remains"
      assert_equal true, safe
      assert_includes safe_reason, "no mutable work-area guard"
    end
  end
end
