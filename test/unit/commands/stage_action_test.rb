require "test_helper"
require "hive/commands/stage_action"

class CommandsStageActionTest < Minitest::Test
  def test_call_wraps_unexpected_errors_and_emits_json_error_envelope
    command = Hive::Commands::StageAction.new("plan", "some-slug", json: true)
    command.define_singleton_method(:do_call) do
      raise NoMethodError, "synthetic boom"
    end

    out, _err = capture_io do
      @error = assert_raises(Hive::InternalError) { command.call }
    end

    assert_match(/internal error: NoMethodError: synthetic boom/, @error.message)
    payload = JSON.parse(out)
    assert_equal "hive-stage-action", payload.fetch("schema")
    assert_equal false, payload.fetch("ok")
    assert_equal "plan", payload.fetch("verb")
    assert_equal "error", payload.fetch("error_kind")
    assert_equal Hive::ExitCodes::SOFTWARE, payload.fetch("exit_code")
  end

  def test_call_wraps_unexpected_errors_without_json_envelope
    command = Hive::Commands::StageAction.new("plan", "some-slug", json: false)
    command.define_singleton_method(:do_call) do
      raise ArgumentError, "bad argument"
    end

    out, _err = capture_io do
      @error = assert_raises(Hive::InternalError) { command.call }
    end

    assert_empty out
    assert_match(/internal error: ArgumentError: bad argument/, @error.message)
  end

  def test_wrong_stage_reports_actual_stage_when_current_stage_is_not_source_or_target
    task = Struct.new(:slug, :folder).new("some-slug", "/tmp/some-slug")
    command = Hive::Commands::StageAction.new("plan", "some-slug")
    command.define_singleton_method(:resolve_task) { task }
    command.define_singleton_method(:stage_dir) { |_task| "4-execute" }

    err = assert_raises(Hive::WrongStage) { command.call }

    assert_match(/plan expects 2-brainstorm or 3-plan/, err.message)
    assert_equal "4-execute", err.current_stage
    assert_equal "3-plan", err.target_stage
  end

  def test_resolve_task_reraises_invalid_path_without_from_filter
    resolver = Object.new
    resolver.define_singleton_method(:resolve) do
      raise Hive::InvalidTaskPath, "missing task"
    end
    original = Hive::TaskResolver.method(:new)
    Hive::TaskResolver.define_singleton_method(:new) { |*_args, **_kwargs| resolver }
    command = Hive::Commands::StageAction.new("plan", "some-slug")

    err = assert_raises(Hive::InvalidTaskPath) { command.send(:resolve_task) }

    assert_equal "missing task", err.message
  ensure
    Hive::TaskResolver.define_singleton_method(:new, original) if original
  end

  def test_error_kind_for_maps_typed_stage_action_errors
    command = Hive::Commands::StageAction.new("plan", "some-slug")
    cases = {
      Hive::AmbiguousSlug.new("ambiguous", slug: "s", candidates: []) => "ambiguous_slug",
      Hive::DestinationCollision.new("collision", path: "/tmp/dest") => "destination_collision",
      Hive::FinalStageReached.new("final", stage: "8-done") => "final_stage",
      Hive::WrongStage.new("wrong", current_stage: "1-inbox") => "wrong_stage",
      Hive::RollbackFailed.new("rollback failed") => "rollback_failed",
      Hive::InvalidTaskPath.new("invalid") => "invalid_task_path",
      Hive::DependencyWaitError.new(
        "waiting", offending_ref: "base", safe_correction: "Wait for base."
      ) => "dependency_wait",
      Hive::DependencyAdmissionError.new(
        "invalid", reason_code: "dependency_cycle", offending_ref: "app:a",
        safe_correction: "Break the cycle."
      ) => "admission_error",
      Hive::Error.new("generic") => "error"
    }

    cases.each do |error, expected|
      assert_equal expected, command.send(:error_kind_for, error), error.message
    end
  end

  def test_durable_call_dispatches_stage_worker_without_promoting_in_caller
    task = Struct.new(:folder).new("/tmp/task-folder")
    result = Hive::Attempts::ClientResult.new(
      status: :terminal, exit_status: 0, outcome: "succeeded",
      receipt: {}, attempt_id: "attempt-1"
    )
    calls = []
    entrypoint = Object.new
    entrypoint.define_singleton_method(:dispatch) { |**kwargs| calls << kwargs; result }
    command = Hive::Commands::StageAction.new(
      "plan", "some-slug", from: "2-brainstorm", json: true,
      durable: true, attempt_entrypoint: entrypoint
    )
    command.define_singleton_method(:resolve_task) { task }
    command.define_singleton_method(:do_call) { flunk "durable caller promoted task" }

    assert_same result, command.call
    assert_equal "3-plan", calls.first.fetch(:intended_stage)
    assert_equal [ "hive", "plan", "/tmp/task-folder", "--from", "2-brainstorm", "--json" ],
                 calls.first.fetch(:argv)
  end

  def test_durable_worker_argv_preserves_recovery_reason
    task = Struct.new(:folder).new("/tmp/task-folder")
    command = Hive::Commands::StageAction.new(
      "plan", "some-slug", recover_merged_error_reason: "ci_failed"
    )
    assert_equal [
      "hive", "plan", "/tmp/task-folder",
      "--recover-merged-error-reason", "ci_failed"
    ], command.send(:durable_worker_argv, task)
  end
end
