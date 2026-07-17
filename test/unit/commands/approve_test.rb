require "test_helper"
require "hive/commands/approve"
require "fileutils"

class HiveCommandsApproveTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Struct.new(:slug, :stage_index, :stage_name, :folder, :hive_state_path, :project_root, :workflow)

  def command(**kwargs)
    Hive::Commands::Approve.new("slug", **kwargs)
  end

  def task(folder: "/tmp/task", hive_state_path: "/tmp/state", project_root: "/tmp/project",
           stage_index: 2, stage_name: "brainstorm", workflow: Hive::Workflows::Registry.default)
    FakeTask.new("slug-260522-abcd", stage_index, stage_name, folder, hive_state_path, project_root, workflow)
  end

  def failing_status
    status = Object.new
    status.define_singleton_method(:success?) { false }
    status
  end

  def successful_status
    status = Object.new
    status.define_singleton_method(:success?) { true }
    status
  end

  def test_force_cannot_bypass_finalize_archive_ready_guard
    with_tmp_dir do |dir|
      state_file = File.join(dir, "pr.md")
      File.write(state_file, "---\npr_url: https://github.com/acme/demo/pull/12\n---\n<!-- COMPLETE -->\n")
      guarded_task = Data.define(
        :slug, :stage_index, :stage_name, :folder, :hive_state_path,
        :project_root, :workflow, :state_file
      ).new(
        slug: "durable-task", stage_index: 8, stage_name: "finalize", folder: dir,
        hive_state_path: dir, project_root: dir, workflow: Hive::Workflows::Registry.default,
        state_file: state_file
      )
      cmd = command(force: true)

      error = assert_raises(Hive::WrongStage) do
        cmd.send(:validate_move!, guarded_task, "9-done", Hive::Markers.current(state_file))
      end
      assert_includes error.message, "archive_ready"
    end
  end

  def test_call_wraps_internal_errors_with_json_envelope
    cmd = command(json: true)
    cmd.define_singleton_method(:do_call) { raise RuntimeError, "boom" }
    error = nil

    out, _err = capture_io do
      error = assert_raises(Hive::InternalError) { cmd.call }
    end

    assert_match(/internal error: RuntimeError: boom/, error.message)
    payload = JSON.parse(out)
    assert_equal "hive-approve", payload.fetch("schema")
    assert_equal "error", payload.fetch("error_kind")
    assert_equal Hive::ExitCodes::SOFTWARE, payload.fetch("exit_code")
  end

  def test_call_wraps_internal_errors_without_quiet_json_envelope
    cmd = command(json: true, quiet: true)
    cmd.define_singleton_method(:do_call) { raise RuntimeError, "boom" }

    out, _err = capture_io do
      error = assert_raises(Hive::InternalError) { cmd.call }
      assert_match(/internal error: RuntimeError: boom/, error.message)
    end

    assert_equal "", out
  end

  def test_direction_of_reports_same_stage
    current = task(stage_index: 3, stage_name: "plan")

    assert_equal "same", command.send(:direction_of, current, "3-plan")
  end

  def test_resolve_destination_uses_task_workflow_sequence
    current = task(stage_index: 2, stage_name: "gather", workflow: research_workflow)

    assert_equal "3-report", command.send(:resolve_destination, current)
  end

  def test_resolve_destination_raises_at_descriptor_terminal_stage
    current = task(stage_index: 3, stage_name: "report", workflow: research_workflow)

    error = assert_raises(Hive::FinalStageReached) { command.send(:resolve_destination, current) }

    assert_equal "3-report", error.stage
  end

  def test_resolve_explicit_to_uses_task_workflow_refs
    current = task(stage_index: 2, stage_name: "gather", workflow: research_workflow)

    assert_equal "3-report", command(to: "report").send(:resolve_destination, current)
  end

  def test_resolve_explicit_to_lists_descriptor_stages
    current = task(stage_index: 2, stage_name: "gather", workflow: research_workflow)

    error = assert_raises(Hive::InvalidTaskPath) do
      command(to: "plan").send(:resolve_destination, current)
    end

    assert_includes error.message, "1-intake, 2-gather, 3-report"
    assert_includes error.message, "intake, gather, report"
  end

  def test_validate_from_uses_task_workflow_refs
    current = task(stage_index: 2, stage_name: "gather", workflow: research_workflow)

    command(from: "gather").send(:validate_from!, current)
  end

  def test_validate_from_unknown_stage_lists_descriptor_dirs
    current = task(stage_index: 2, stage_name: "gather", workflow: research_workflow)

    error = assert_raises(Hive::InvalidTaskPath) do
      command(from: "brainstorm").send(:validate_from!, current)
    end

    assert_includes error.message, "unknown --from stage 'brainstorm'"
    assert_includes error.message, "1-intake, 2-gather, 3-report"
  end

  def test_move_task_uses_cross_device_fallback_on_exdev
    Dir.mktmpdir("hive-approve-unit") do |root|
      state = File.join(root, ".hive-state")
      source = File.join(state, "stages", "2-brainstorm", "slug-260522-abcd")
      FileUtils.mkdir_p(source)
      File.write(File.join(source, "task.md"), "body
")
      approve_task = task(folder: source, hive_state_path: state, project_root: root)
      original = File.singleton_class.instance_method(:rename)

      File.define_singleton_method(:rename) do |from, to|
        raise Errno::EXDEV, "cross-device" if from == source

        original.bind_call(File, from, to)
      end

      new_folder = command.send(:move_task!, approve_task, "3-plan")

      assert_equal File.join(state, "stages", "3-plan", "slug-260522-abcd"), new_folder
      assert File.exist?(File.join(new_folder, "task.md"))
      refute Dir.exist?(source)
    ensure
      File.singleton_class.define_method(:rename, original) if original
    end
  end

  def test_move_task_reports_destination_collision_when_rename_loses_race
    Dir.mktmpdir("hive-approve-unit") do |root|
      state = File.join(root, ".hive-state")
      source = File.join(state, "stages", "2-brainstorm", "slug-260522-abcd")
      FileUtils.mkdir_p(source)
      approve_task = task(folder: source, hive_state_path: state, project_root: root)
      cmd = command
      cmd.define_singleton_method(:destination_exists?) { |_path| false }
      original = File.singleton_class.instance_method(:rename)
      File.define_singleton_method(:rename) do |from, _to|
        raise Errno::ENOTEMPTY, "destination appeared" if from == source

        original.bind_call(File, from, _to)
      end

      error = assert_raises(Hive::DestinationCollision) do
        cmd.send(:move_task!, approve_task, "3-plan")
      end

      assert_equal File.join(state, "stages", "3-plan", "slug-260522-abcd"), error.path
    ensure
      File.singleton_class.define_method(:rename, original) if original
    end
  end

  def test_cross_device_move_cleans_partial_destination_on_copy_failure
    Dir.mktmpdir("hive-approve-unit") do |root|
      src = File.join(root, "src")
      dst = File.join(root, "dst")
      FileUtils.mkdir_p(src)
      FileUtils.mkdir_p(dst)
      original = FileUtils.singleton_class.instance_method(:cp_r)
      FileUtils.define_singleton_method(:cp_r) do |*_args|
        raise Errno::ENOSPC, "full"
      end

      error = assert_raises(Hive::Error) { command.send(:cross_device_move!, src, dst) }

      assert_match(/cross-device move failed/, error.message)
      assert Dir.exist?(src), "failed copy must leave source in place"
      refute Dir.exist?(dst), "partial destination must be cleaned"
    ensure
      FileUtils.singleton_class.define_method(:cp_r, original) if original
    end
  end

  def test_source_has_tracked_files_reports_git_failures_from_stdout_or_stderr
    cmd = command
    original = Open3.singleton_class.instance_method(:capture3)
    failed = failing_status

    Open3.define_singleton_method(:capture3) { |*_args| [ "stdout detail", "", failed ] }
    stdout_error = assert_raises(Hive::GitError) do
      cmd.send(:source_has_tracked_files?, "/tmp/state", "stages/2-brainstorm/slug")
    end
    assert_includes stdout_error.message, "stdout detail"

    Open3.define_singleton_method(:capture3) { |*_args| [ "", "fatal index", failed ] }
    stderr_error = assert_raises(Hive::GitError) do
      cmd.send(:source_has_tracked_files?, "/tmp/state", "stages/2-brainstorm/slug")
    end
    assert_includes stderr_error.message, "fatal index"
  ensure
    Open3.singleton_class.define_method(:capture3, original) if original
  end

  def test_record_hive_commit_skips_source_and_commit_when_index_has_no_diff
    cmd = command
    approve_task = task(hive_state_path: "/tmp/state", project_root: "/tmp/project")
    calls = []
    fake_ops = Object.new
    fake_ops.define_singleton_method(:run_git!) { |*args| calls << args }
    original_git_ops = Hive::GitOps.singleton_class.instance_method(:new)
    original_capture3 = Open3.singleton_class.instance_method(:capture3)
    ok = successful_status

    cmd.define_singleton_method(:source_has_tracked_files?) { |_state, _source| false }
    Hive::GitOps.define_singleton_method(:new) { |_project_root| fake_ops }
    Open3.define_singleton_method(:capture3) { |*_args| [ "", "", ok ] }

    cmd.send(:record_hive_commit, approve_task, "3-plan", "approve 2-brainstorm -> 3-plan")

    assert_equal 1, calls.size
    assert_equal [ "-C", "/tmp/state", "add", "-A", "stages/3-plan/slug-260522-abcd" ], calls.first
  ensure
    Hive::GitOps.singleton_class.define_method(:new, original_git_ops) if original_git_ops
    Open3.singleton_class.define_method(:capture3, original_capture3) if original_capture3
  end

  def test_attempt_rollback_messages_include_original_and_rollback_errors
    Dir.mktmpdir("hive-approve-unit") do |root|
      source = File.join(root, "source")
      moved = File.join(root, "moved")
      FileUtils.mkdir_p(moved)
      approve_task = task(folder: source)
      captured = {}
      original = Hive::CommitOrRollback.singleton_class.instance_method(:attempt!)
      Hive::CommitOrRollback.define_singleton_method(:attempt!) do |_error, on_undo:, rolled_back_message:, rollback_failed_message:|
        captured[:rolled_back] = rolled_back_message.call(StandardError.new("commit nope"))
        captured[:rollback_failed] = rollback_failed_message.call(
          StandardError.new("commit nope"),
          StandardError.new("undo nope")
        )
        on_undo
      end

      command.send(:attempt_rollback!, approve_task, moved, Hive::GitError.new("commit"))

      assert_includes captured.fetch(:rolled_back), "underlying: StandardError: commit nope"
      assert_includes captured.fetch(:rollback_failed), "rollback error: StandardError: undo nope"
    ensure
      Hive::CommitOrRollback.singleton_class.define_method(:attempt!, original) if original
    end
  end

  def test_json_next_action_falls_back_when_new_folder_is_not_a_task
    action = nil
    _out, err = capture_io do
      action = command.send(
        :json_next_action,
        "/tmp/not-a-hive-task",
        Hive::Workflows::Registry.default,
        "2-brainstorm"
      )
    end

    assert_equal Hive::Schemas::NextActionKind::RUN, action.fetch("kind")
    assert_equal "hive run /tmp/not-a-hive-task", action.fetch("command")
    # The dropped re-parse must reach stderr — the code comment promises a
    # "genuine post-move failure isn't silent".
    assert_includes err, "could not compute next_action"
  end

  # Companion to the not-a-task case above: a moved task whose meta.yml carries
  # an UNREGISTERABLE workflow re-parses past PATH_RE but raises InvalidTaskPath
  # in resolve_workflow — the deeper trigger the finding names. It must hit the
  # same degrade-and-warn rescue (hive run fallback + stderr warning), not a
  # silent drop.
  def test_json_next_action_degrades_on_unregisterable_meta_workflow
    Dir.mktmpdir("hive-approve-unit") do |dir|
      folder = File.join(dir, ".hive-state", "stages", "2-gather", "x-260620-aaaa")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "meta.yml"), "workflow: bogus-unregistered\n")

      action = nil
      _out, err = capture_io do
        action = command.send(:json_next_action, folder, research_workflow, "2-gather")
      end

      assert_equal Hive::Schemas::NextActionKind::RUN, action.fetch("kind")
      assert_equal "hive run #{folder}", action.fetch("command")
      assert_includes err, "could not compute next_action"
    end
  end

  def test_stage_for_dest_raises_on_unresolved_dir
    # Failure arm of the defensive guard: a dir the descriptor can't resolve
    # surfaces a typed InvalidTaskPath, not a NoMethodError on nil. Unreachable
    # on live paths (callers pass resolve_destination output) but pinned so the
    # guard is covered regardless of the coverage gate's branch awareness.
    error = assert_raises(Hive::InvalidTaskPath) do
      command.send(:stage_for_dest!, task, "99-bogus")
    end

    assert_includes error.message, "unknown destination stage '99-bogus'"
  end

  def test_same_stage_is_falsy_on_unresolved_dir
    # The nil-tolerant sibling of stage_for_dest!: an unresolved dir is treated
    # as "not the same stage" (falsy) rather than raising, so the pipeline falls
    # through to validate_move!'s loud backstop. Pin the nil-guard arm directly.
    refute command.send(:same_stage?, task, "99-bogus"),
           "an unresolved dir must read as not-same-stage without raising"
  end

  def test_json_next_action_uses_descriptor_terminal_stage
    action = command.send(:json_next_action, "/tmp/not-used", research_workflow, "3-report")

    assert_equal Hive::Schemas::NextActionKind::NO_OP, action.fetch("kind")
    assert_equal "final_stage", action.fetch("reason")
  end

  def test_workflow_command_for_falls_back_without_stage_or_arriving_verb
    cmd = command
    approve_task = task

    assert_equal "hive run slug-260522-abcd", cmd.send(:workflow_command_for, approve_task, "99-missing")
    assert_equal "hive run slug-260522-abcd", cmd.send(:workflow_command_for, approve_task, "1-inbox")
  end

  def test_workflow_command_for_uses_descriptor_advance_verb
    current = task(stage_index: 2, stage_name: "brainstorm")

    assert_equal "hive plan slug-260522-abcd --from 3-plan",
                 command.send(:workflow_command_for, current, "3-plan")
  end

  def test_workflow_command_for_mv_only_stage_falls_back_to_run
    current = task(stage_index: 2, stage_name: "gather", workflow: research_workflow)

    assert_equal "hive run slug-260522-abcd",
                 command.send(:workflow_command_for, current, "3-report")
  end

  def test_error_envelope_and_classifier_cover_remaining_error_kinds
    cmd = command

    assert_equal "rollback_failed", cmd.send(:error_kind_for, Hive::RollbackFailed.new("rollback"))
    assert_equal "invalid_task_path", cmd.send(:error_kind_for, Hive::InvalidTaskPath.new("bad"))
    assert_equal "error", cmd.send(:error_kind_for, Hive::Error.new("generic"))

    out, _err = capture_io do
      cmd.send(:emit_error_envelope, StandardError.new("plain"))
    end
    payload = JSON.parse(out)
    assert_equal "error", payload.fetch("error_kind")
    assert_equal Hive::ExitCodes::GENERIC, payload.fetch("exit_code")
  end
end
