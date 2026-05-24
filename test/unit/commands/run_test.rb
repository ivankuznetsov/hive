require "test_helper"
require "hive/commands/run"

class CommandsRunTest < Minitest::Test
  include HiveTestHelper
  TaskDouble = Struct.new(
    :slug, :stage_name, :stage_index, :folder, :state_file,
    :hive_state_path, :project_root, :project_name, :worktree_path,
    keyword_init: true
  )
  MarkerDouble = Struct.new(:name, :attrs, keyword_init: true)
  RebaseResultDouble = Struct.new(
    :reason, :attempted, :succeeded, :commits_behind,
    :agent_resolutions, :post_rebase_warnings,
    keyword_init: true
  )

  def command(**kwargs)
    Hive::Commands::Run.new("some-slug", **kwargs)
  end

  def task(folder: "/tmp/hive-task", stage_name: "brainstorm", stage_index: 2)
    TaskDouble.new(
      slug: "some-slug",
      stage_name: stage_name,
      stage_index: stage_index,
      folder: folder,
      state_file: File.join(folder, "brainstorm.md"),
      hive_state_path: File.join(folder, "..", "..", ".."),
      project_root: "/tmp/project",
      project_name: "project",
      worktree_path: "/tmp/worktree"
    )
  end

  def marker(name, attrs = {})
    MarkerDouble.new(name: name, attrs: attrs)
  end

  def rebase_result(**overrides)
    RebaseResultDouble.new({
      reason: :ok,
      attempted: true,
      succeeded: true,
      commits_behind: 0,
      agent_resolutions: 0,
      post_rebase_warnings: []
    }.merge(overrides))
  end

  def test_log_rebase_outcome_reports_success_failure_and_post_warnings
    run = command
    t = task

    _out, err = capture_io do
      run.send(:log_rebase_outcome, t, rebase_result(commits_behind: 2, agent_resolutions: 1))
      run.send(:log_rebase_outcome, t, rebase_result(commits_behind: 3, agent_resolutions: 0))
      run.send(:log_rebase_outcome, t, rebase_result(post_rebase_warnings: [ "worktree.yml stale" ]))
      run.send(:log_rebase_outcome, t, rebase_result(reason: :conflict, succeeded: false))
    end

    assert_includes err, "2 commits"
    assert_includes err, "1 conflict resolved by agent"
    assert_includes err, "3 commits"
    assert_includes err, "post-rebase warning: worktree.yml stale"
    assert_includes err, "rebase attempt failed (conflict)"
  end

  def test_pick_runner_rejects_unknown_stage_name
    err = assert_raises(Hive::StageError) do
      command.send(:pick_runner, TaskDouble.new(stage_name: "mystery"))
    end

    assert_match(/no runner for stage mystery/, err.message)
  end

  def test_quiet_report_still_raises_for_error_markers
    with_tmp_dir do |dir|
      t = task(folder: dir)
      File.write(t.state_file, "# state\n")
      Hive::Markers.set(t.state_file, :review_error, phase: "fix")

      err = assert_raises(Hive::TaskInErrorState) do
        command(quiet: true).send(:report, t, {})
      end

      assert_match(/stage recorded :review_error/, err.message)
    end
  end

  def test_report_json_uses_disabled_rebase_fallback_and_cleanup_instructions
    run = command(json: true)
    t = task

    out, _err = capture_io do
      run.send(
        :report_json,
        t,
        { commit: "done", cleanup_instructions: "remove worktree" },
        marker(:manual_steering)
      )
    end

    payload = JSON.parse(out)
    assert_equal "hive-run", payload.fetch("schema")
    assert_equal "remove worktree", payload.fetch("cleanup_instructions")
    assert_equal "disabled", payload.fetch("rebase").fetch("reason")
    assert_equal({ "kind" => Hive::Schemas::NextActionKind::NO_OP, "reason" => "manual_steering" },
                 payload.fetch("next_action"))
  end

  def test_json_next_action_covers_stale_review_and_unknown_markers
    run = command
    t = task(folder: "/tmp/task-folder")

    execute_stale = run.send(:json_next_action, t, marker(:execute_stale))
    guardrail = run.send(:json_next_action, t, marker(:review_waiting, "reason" => "fix_guardrail", "pass" => "3"))
    partial = run.send(:json_next_action, t, marker(:review_waiting, "reason" => "reviewer_partial_failure", "pass" => "4"))
    unknown = run.send(:json_next_action, t, marker(:surprise_marker))

    assert_equal Hive::Schemas::NextActionKind::RECOVER_STALE, execute_stale.fetch("kind")
    assert_equal "/tmp/task-folder/reviews/fix-guardrail-03.md", guardrail.fetch("target")
    assert_match(/checkbox count/, guardrail.fetch("instructions"))
    assert_equal "/tmp/task-folder/reviews/errors-04.md", partial.fetch("target")
    assert_match(/partial coverage/, partial.fetch("instructions"))
    assert_equal({ "kind" => Hive::Schemas::NextActionKind::NO_OP }, unknown)
  end

  def test_report_text_covers_manual_and_stale_guidance
    run = command
    t = task

    out, _err = capture_io do
      run.send(:report_text, t, {}, marker(:execute_stale))
      run.send(:report_text, t, {}, marker(:manual_steering))
    end

    assert_includes out, "remove EXECUTE_STALE marker"
    assert_includes out, "manual steering active"
  end

  def test_report_text_review_error_prints_phase_and_reason_before_raising
    run = command
    t = task

    _out, err = capture_io do
      @error = assert_raises(Hive::TaskInErrorState) do
        run.send(:report_text, t, {}, marker(:review_error, "phase" => "fix", "reason" => "failed"))
      end
    end

    assert_match(/stage recorded :review_error/, @error.message)
    assert_includes err, "phase: fix"
    assert_includes err, "reason: failed"
  end

  def test_emit_error_envelope_swallows_json_generation_errors
    run = command(json: true)
    original = JSON.method(:generate)
    JSON.define_singleton_method(:generate) do |*_args|
      raise JSON::GeneratorError, "bad json"
    end

    capture_io do
      run.send(:emit_error_envelope, Hive::InternalError.new("bad"))
    end

    assert run.instance_variable_get(:@stdout_written)
  ensure
    JSON.define_singleton_method(:generate, original) if original
  end
end
