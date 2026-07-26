require "test_helper"
require "hive/commands/stage_action"

class CommandsStageActionTest < Minitest::Test
  include HiveTestHelper

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

  def test_execute_condition_guard_runs_before_stage_action_accepts_complete_marker
    with_tmp_dir do |dir|
      state_file = File.join(dir, "task.md")
      File.write(state_file, "<!-- EXECUTE_COMPLETE -->\n")
      task = Struct.new(:state_file).new(state_file)
      command = Hive::Commands::StageAction.new("open-pr", "some-slug")
      calls = []
      guard = lambda do |observed, force:|
        calls << [ observed, force ]
        raise Hive::WrongStage, "condition gate blocked"
      end

      with_replaced_singleton_method(Hive::Conditions::TransitionGuard, :validate!, guard) do
        error = assert_raises(Hive::WrongStage) do
          command.send(
            :validate_marker!, task,
            { force_source: false, target: "5-open-pr" }
          )
        end
        assert_includes error.message, "condition gate blocked"
      end
      assert_equal [ [ task, false ] ], calls
    end
  end

  def test_force_source_bypasses_execute_condition_guard_explicitly
    command = Hive::Commands::StageAction.new("open-pr", "some-slug")
    called = false
    guard = ->(*) { called = true }

    with_replaced_singleton_method(Hive::Conditions::TransitionGuard, :validate!, guard) do
      command.send(
        :validate_marker!, Struct.new(:state_file).new("/does/not/matter"),
        { force_source: true, target: "5-open-pr" }
      )
    end
    refute called
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

  def test_durable_call_uses_attempts_api_without_promoting_in_caller
    task = Struct.new(:folder).new("/tmp/task-folder")
    result = Hive::Attempts::ClientResult.new(
      status: :terminal, exit_status: 0, outcome: "succeeded",
      receipt: {}, attempt_id: "attempt-1"
    )
    calls = []
    entrypoint = Object.new
    entrypoint.define_singleton_method(:dispatch) { |**kwargs| calls << kwargs; result }
    command = Hive::Commands::StageAction.new(
      "plan", "some-slug", from: "2-brainstorm", json: true, durable: true
    )
    command.define_singleton_method(:resolve_task) { task }
    command.define_singleton_method(:do_call) { flunk "durable caller promoted task" }

    with_replaced_singleton_method(Hive::Attempts::API, :new, -> { entrypoint }) do
      assert_same result, command.call
    end
    assert_equal "3-plan", calls.first.fetch(:intended_stage)
    assert_equal [ "hive", "plan", "/tmp/task-folder", "--from", "2-brainstorm", "--json" ],
                 calls.first.fetch(:argv)
  end

  def test_lost_durable_attempt_emits_versioned_json_error_envelope
    task = Struct.new(:folder, :slug, :project_root, :project_name).new(
      "/tmp/task-folder", "some-slug", "/tmp/project", "demo"
    )
    attempt = Struct.new(:attempt_id).new("attempt-lost")
    dispatch_result = Hive::Attempts::DispatchResult.new(
      status: :accepted, attempt: attempt, receipt: nil,
      attach_descriptor: { "attempt_id" => attempt.attempt_id }, reason: nil
    )
    dispatcher = Object.new
    dispatcher.define_singleton_method(:dispatch) { |**_kwargs| dispatch_result }
    client = Object.new
    client.define_singleton_method(:attach) do |id|
      Hive::Attempts::ClientResult.new(
        status: :lost, exit_status: Hive::ExitCodes::TEMPFAIL,
        outcome: "lost", receipt: nil, attempt_id: id
      )
    end
    entrypoint = Hive::Attempts::Entrypoint.new(
      store: Object.new, dispatcher: dispatcher, client: client,
      config_loader: ->(_root) { Hive::Config.merge_defaults({}) }
    )
    command = Hive::Commands::StageAction.new(
      "plan", "some-slug", json: true, durable: true,
      attempt_entrypoint: entrypoint
    )
    command.define_singleton_method(:resolve_task) { task }

    out, = capture_io do
      @lost_error = assert_raises(Hive::ConcurrentRunError) { command.call }
    end

    payload = JSON.parse(out)
    assert_equal "hive-stage-action", payload.fetch("schema")
    assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-stage-action"), payload.fetch("schema_version")
    assert_equal "plan", payload.fetch("verb")
    assert_equal "error", payload.fetch("error_kind")
    assert_equal Hive::ExitCodes::TEMPFAIL, payload.fetch("exit_code")
    assert_includes payload.fetch("message"), "attempt-lost"
  end

  def test_condition_gate_error_envelope_preserves_gate_and_recovery_action
    error = Hive::ConditionGateBlocked.new(
      "blocked",
      current_stage: "4-execute", target_stage: "5-open-pr",
      condition_gate: {
        "status" => "blocked", "transition" => "execute_to_open_pr",
        "diagnostics" => [ { "condition" => "AgentHealthy", "state" => "unsatisfied" } ],
        "waivers" => []
      },
      next_action: {
        "kind" => Hive::Schemas::NextActionKind::RUN,
        "reason" => "attempt_lost"
      }
    )
    command = Hive::Commands::StageAction.new("open-pr", "task", json: true)

    out, = capture_io { command.send(:emit_envelope, error) }
    payload = JSON.parse(out)
    assert_equal "blocked", payload.dig("condition_gate", "status")
    assert_equal "AgentHealthy",
                 payload.dig("condition_gate", "diagnostics", 0, "condition")
    assert_equal Hive::Schemas::NextActionKind::RUN, payload.dig("next_action", "kind")
    assert_equal "4-execute", payload.fetch("current_stage")
    assert_equal "5-open-pr", payload.fetch("target_stage")
  end


  def test_failed_durable_json_attempt_without_stdout_emits_one_error_document
    task = Struct.new(:folder).new("/tmp/task-folder")
    result = Hive::Attempts::ClientResult.new(
      status: :terminal, exit_status: Hive::ExitCodes::SOFTWARE, outcome: "failed",
      receipt: {}, attempt_id: "attempt-empty", stdout_bytes: 0
    )
    entrypoint = Object.new
    entrypoint.define_singleton_method(:dispatch) { |**_kwargs| result }
    command = Hive::Commands::StageAction.new(
      "plan", "some-slug", json: true, durable: true, attempt_entrypoint: entrypoint
    )
    command.define_singleton_method(:resolve_task) { task }

    out, = capture_io do
      error = assert_raises(Hive::AttemptExecutionError) { command.call }
      assert_equal Hive::ExitCodes::SOFTWARE, error.exit_code
    end

    assert_equal 1, out.lines.length
    payload = JSON.parse(out)
    assert_equal "hive-stage-action", payload.fetch("schema")
    assert_equal "error", payload.fetch("error_kind")
    assert_equal Hive::ExitCodes::SOFTWARE, payload.fetch("exit_code")
    assert_includes payload.fetch("message"), "attempt-empty"
  end

  def test_lost_durable_json_attempt_with_worker_stdout_does_not_duplicate_it
    task = Struct.new(:folder).new("/tmp/task-folder")
    result = Hive::Attempts::ClientResult.new(
      status: :lost, exit_status: Hive::ExitCodes::TEMPFAIL, outcome: "lost",
      receipt: nil, attempt_id: "attempt-lost-output", stdout_bytes: 12
    )
    entrypoint = Object.new
    entrypoint.define_singleton_method(:dispatch) { |**_kwargs| result }
    command = Hive::Commands::StageAction.new(
      "plan", "some-slug", json: true, durable: true, attempt_entrypoint: entrypoint
    )
    command.define_singleton_method(:resolve_task) { task }

    out, = capture_io do
      exit_error = assert_raises(SystemExit) { command.call }
      assert_equal Hive::ExitCodes::TEMPFAIL, exit_error.status
    end
    assert_empty out
  end

  def test_failed_durable_json_attempt_with_worker_stdout_exits_without_duplicate_output
    task = Struct.new(:folder).new("/tmp/task-folder")
    result = Hive::Attempts::ClientResult.new(
      status: :terminal, exit_status: 7, outcome: "failed",
      receipt: {}, attempt_id: "attempt-failed-output", stdout_bytes: 12
    )
    entrypoint = Object.new
    entrypoint.define_singleton_method(:dispatch) { |**_kwargs| result }
    command = Hive::Commands::StageAction.new(
      "plan", "some-slug", json: true, durable: true, attempt_entrypoint: entrypoint
    )
    command.define_singleton_method(:resolve_task) { task }

    out, = capture_io do
      exit_error = assert_raises(SystemExit) { command.call }
      assert_equal 7, exit_error.status
    end
    assert_empty out
  end

  def test_failed_durable_text_attempt_preserves_exit_without_json
    task = Struct.new(:folder).new("/tmp/task-folder")
    result = Hive::Attempts::ClientResult.new(
      status: :terminal, exit_status: 7, outcome: "failed",
      receipt: {}, attempt_id: "attempt-text", stdout_bytes: 0
    )
    entrypoint = Object.new
    entrypoint.define_singleton_method(:dispatch) { |**_kwargs| result }
    command = Hive::Commands::StageAction.new(
      "plan", "some-slug", json: false, durable: true, attempt_entrypoint: entrypoint
    )
    command.define_singleton_method(:resolve_task) { task }

    out, = capture_io do
      exit_error = assert_raises(SystemExit) { command.call }
      assert_equal 7, exit_error.status
    end
    assert_empty out
  end
end
