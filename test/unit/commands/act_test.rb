require "test_helper"
require "json_schemer"
require "hive/commands/act"
require "hive/runtime_control_plane/command_schema_installation"

class CommandsActTest < Minitest::Test
  include HiveTestHelper

  TEST_PACKAGE = {
    version: "0.0.0-test", location: "https://example.invalid/compat.gem", sha256: "a" * 64
  }.freeze

  class FakeExecutor
    attr_reader :calls

    def initialize(error: nil, result: nil)
      @error = error
      @result = result
      @calls = []
    end

    def execute(**kwargs)
      @calls << kwargs
      raise @error if @error

      @result || { "task_state" => "idle", "stage" => "3-plan", "marker" => "complete" }
    end
  end

  def test_json_success_is_one_hive_act_envelope
    executor = FakeExecutor.new
    token = "a" * 64
    stdout, = capture_io do
      Hive::Commands::Act.new(
        "workflow.advance", "demo:task", observation: token, json: true, executor: executor
      ).call
    end
    payload = JSON.parse(stdout)

    assert_equal [ {
      action_id: "workflow.advance", target: "demo:task", observation_token: token
    } ], executor.calls
    assert_equal "hive-act", payload.fetch("schema")
    assert_equal true, payload.fetch("ok")
    assert_equal "workflow.advance", payload.fetch("action_id")
    assert_equal "demo:task", payload.fetch("target")
    assert_equal "idle", payload.dig("result", "task_state")
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-act"))))
    assert schema.valid?(payload), schema.validate(payload).map { |error| error.fetch("error") }.inspect
  end

  def test_inner_stage_stdout_cannot_become_a_second_act_json_document
    executor = FakeExecutor.new
    executor.define_singleton_method(:execute) do |**|
      puts '{"schema":"inner-stage"}'
      { "task_state" => "idle", "stage" => "3-plan", "marker" => "complete" }
    end
    stdout, = capture_io do
      Hive::Commands::Act.new("workflow.advance", "demo:task", observation: "a" * 64,
        json: true, executor: executor).call
    end
    assert_equal "hive-act", JSON.parse(stdout).fetch("schema")
  end

  def test_keyed_json_success_is_not_marked_emitted_before_receipt_finalization
    command = Hive::Commands::Act.new(
      "workflow.advance", "demo:task", observation: "a" * 64, json: true,
      idempotency_key: "key", executor: FakeExecutor.new
    )
    capture_io { command.send(:emit_success, FakeExecutor.new.execute) }
    refute command.instance_variable_get(:@stdout_written)
  end

  def test_failed_attached_stage_emits_one_success_envelope_and_exits_nonzero
    result = { "task_state" => "error", "stage" => "6-review", "marker" => "error",
      "recovery" => Hive::Daemon::RecoveryCoordinator::Receipt.from_h({
        "status" => "terminal", "phase" => "terminal", "owner" => "none",
        "request_id" => "request-1", "attempt_id" => "attempt-1",
        "terminal_outcome" => "failed", "terminal_at" => Time.now.utc.iso8601
      }).to_h }
    stdout, = capture_io do
      assert_raises(Hive::TaskInErrorState) do
        Hive::Commands::Act.new("workflow.retry", "demo:task", observation: "a" * 64,
          json: true, executor: FakeExecutor.new(result: result)).call
      end
    end
    payload = JSON.parse(stdout)
    assert_equal true, payload.fetch("ok")
    assert_equal "failed", payload.dig("result", "recovery", "terminal_outcome")
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-act"))))
    assert schema.valid?(payload), schema.validate(payload).to_a.inspect
  end

  def test_operator_secret_rework_forwards_confirmation_and_reports_the_new_generation
    token = "a" * 64
    result = {
      "task_state" => "ready_to_run", "stage" => "2-fix", "marker" => "none",
      "secret_rework" => { "status" => "reworked", "generation" => 2, "findings" => 3 }
    }
    executor = FakeExecutor.new(result: result)
    stdout, = capture_io do
      Hive::Commands::Act.new(
        "workflow.secret_rework", "demo:task", observation: token, json: true,
        confirm: true, executor: executor
      ).call
    end
    payload = JSON.parse(stdout)

    assert_equal [ {
      action_id: "workflow.secret_rework", target: "demo:task", observation_token: token, confirm: true
    } ], executor.calls
    assert_equal result, payload.fetch("result")
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-act"))))
    assert schema.valid?(payload), schema.validate(payload).map { |error| error.fetch("error") }.inspect

    human, = capture_io do
      Hive::Commands::Act.new(
        "workflow.secret_rework", "demo:task", observation: token, confirm: true, executor: executor
      ).call
    end
    assert_equal "returned demo:task to Fix as generation 2 with 3 redacted secret finding(s) — " \
                 "ready_to_run at 2-fix (none)\n", human

    replayed = result.merge("secret_rework" => result.fetch("secret_rework").merge("status" => "already_reworked"))
    human, = capture_io do
      Hive::Commands::Act.new(
        "workflow.secret_rework", "demo:task", observation: token, confirm: true,
        executor: FakeExecutor.new(result: replayed)
      ).call
    end
    assert_match(/\Aalready returned demo:task to Fix as generation 2/, human)
  end

  def test_human_success_is_concise
    stdout, = capture_io do
      Hive::Commands::Act.new(
        "workflow.advance", "demo:task", observation: "a" * 64, executor: FakeExecutor.new
      ).call
    end

    assert_equal "advanced demo:task — idle at 3-plan (complete)\n", stdout
  end

  def test_structured_call_returns_the_payload_without_output
    payload = nil
    stdout, stderr = capture_io do
      payload = Hive::Commands::Act.new(
        "workflow.advance", "demo:task", observation: "a" * 64,
        structured: true, executor: FakeExecutor.new
      ).call
    end

    assert_empty stdout
    assert_empty stderr
    assert_equal true, payload.fetch("ok")
    assert_equal "idle", payload.dig("result", "task_state")
  end

  def test_keyed_replay_after_task_move_preserves_payload_without_reexecuting_act
    with_command_receipts do |project, store|
      source = File.join(project, ".hive-state", "stages", "1-inbox", "task")
      destination = File.join(project, ".hive-state", "stages", "2-brainstorm", "task")
      FileUtils.mkdir_p(source)
      executor = FakeExecutor.new
      token = "d" * 64
      command = Hive::Commands::Act.new(
        "workflow.advance", "demo:task", observation: token, json: true,
        idempotency_key: "act-move", executor: executor, command_receipt_store: store
      )
      operation = Hive::CommandOperation.new(
        key: "act-move", command: "act", target: "demo:task",
        request: { "action_id" => "workflow.advance", "observation" => token, "project" => nil },
        project_root: project, principal: "owner", json: true, structured: true,
        failure_payload: ->(error) { command.send(:envelope_payload_for, error) },
        text_renderer: ->(payload) { command.send(:text_success, payload.fetch("result")) },
        store: store
      )
      command.define_singleton_method(:command_operation) { operation }

      first, = capture_io { command.call }
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.mv(source, destination)
      replay, = capture_io { command.call }

      assert_equal 1, executor.calls.length
      assert_equal JSON.parse(first), JSON.parse(replay)
    end
  end

  def test_post_effect_persistence_failure_emits_typed_unresolved_envelope
    with_command_receipts do |project, store|
      original_succeed = store.method(:succeed)
      fail_once = true
      store.define_singleton_method(:succeed) do |claim, result:, status: 0|
        if fail_once
          fail_once = false
          raise Sequel::DatabaseError, "simulated final receipt failure"
        end
        original_succeed.call(claim, result: result, status: status)
      end
      command = Hive::Commands::Act.new(
        "workflow.advance", "demo:task", observation: "e" * 64, json: true,
        idempotency_key: "act-persistence", executor: FakeExecutor.new,
        command_receipt_store: store
      )
      operation = Hive::CommandOperation.new(
        key: "act-persistence", command: "act", target: "demo:task",
        request: {
          "action_id" => "workflow.advance", "observation" => "e" * 64, "project" => nil
        },
        project_root: project, principal: "owner", json: true, structured: true,
        failure_payload: ->(error) { command.send(:envelope_payload_for, error) },
        text_renderer: ->(payload) { command.send(:text_success, payload.fetch("result")) },
        store: store
      )
      command.define_singleton_method(:command_operation) { operation }

      output, = capture_io do
        assert_raises(Hive::CommandUnresolved) { command.call }
      end
      envelope = JSON.parse(output)
      assert_equal false, envelope.fetch("ok")
      assert_equal "command_unresolved_pending", envelope.fetch("error_kind")
      assert_equal Hive::ExitCodes::COMMAND_UNRESOLVED, envelope.fetch("exit_code")
      assert_equal "unresolved", envelope.dig("command_receipt", "state")
    end
  end

  def test_keyed_rejected_action_replays_the_typed_envelope_and_original_status_once
    with_command_receipts do |project, store|
      executor = FakeExecutor.new(error: Hive::WrongStage.new("stage changed"))
      resolver = Struct.new(:resolve).new(Struct.new(:project_root).new(project))
      with_replaced_singleton_method(Hive::TaskResolver, :new, ->(*) { resolver }) do
        with_replaced_singleton_method(Hive::CommandOperation, :registered_project_roots, ->(**) { [ project ] }) do
          outputs = [ Hive::WrongStage, Hive::CommandReplayFailure ].map do |error_class|
            stdout, = capture_io do
              error = assert_raises(error_class) do
                Hive::Commands::Act.new("workflow.retry", "demo:task", observation: "a" * 64,
                  json: true, executor: executor, idempotency_key: "rejected-action",
                  command_receipt_store: store, principal: "owner").call
              end
              assert_equal Hive::ExitCodes::WRONG_STAGE, error.exit_code
            end
            payload = JSON.parse(stdout)
            assert_equal "stale_observation", payload.fetch("error_kind")
            assert_equal "workflow.retry", payload.fetch("action_id")
            assert_equal "demo:task", payload.fetch("target")
            stdout
          end
          assert_equal outputs.first, outputs.last
          assert_equal 1, executor.calls.length
        end
      end
    end
  end

  def test_retry_renders_and_validates_the_canonical_recovery_receipt
    result = {
      "task_state" => "error",
      "stage" => "4-execute",
      "marker" => "error",
      "recovery" => {
        "status" => "cooldown",
        "request_id" => nil,
        "attempt_id" => nil,
        "phase" => nil,
        "failure_origin" => "implementer_failed",
        "next_eligible_at" => "2026-07-20T11:00:00.000000Z",
        "owner" => "scheduler",
        "reason" => "shared_cooldown",
        "remediation" => "retry remains available after the shared cooldown",
        "retry_count" => 0,
        "terminal_outcome" => nil,
        "terminal_at" => nil,
        "provider_hint" => {
          "retry_after" => "2026-07-20T14:00:00Z",
          "display_only" => true
        }
      }
    }
    executor = FakeExecutor.new(result: result)
    token = "c" * 64
    stdout, = capture_io do
      Hive::Commands::Act.new(
        "workflow.retry", "demo:task", observation: token, executor: executor
      ).call
    end
    assert_equal(
      "Retry available later — eligible 2026-07-20T11:00:00.000000Z; shared cooldown; " \
      "retry remains available after the shared cooldown\n",
      stdout
    )

    json_stdout, = capture_io do
      Hive::Commands::Act.new(
        "workflow.retry", "demo:task", observation: token, json: true, executor: executor
      ).call
    end
    payload = JSON.parse(json_stdout)
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-act"))))
    assert schema.valid?(payload), schema.validate(payload).map { |error| error.fetch("error") }.inspect
  end

  def test_terminal_retry_human_output_includes_outcome_and_time
    recovery = {
      "status" => "terminal",
      "request_id" => "recovery-1",
      "attempt_id" => "attempt-1",
      "phase" => "terminal",
      "failure_origin" => "implementer_failed",
      "next_eligible_at" => nil,
      "owner" => "none",
      "reason" => nil,
      "remediation" => nil,
      "retry_count" => 1,
      "provider_hint" => nil,
      "terminal_outcome" => "succeeded",
      "terminal_at" => "2026-07-25T15:00:00.000000Z"
    }
    executor = FakeExecutor.new(
      result: {
        "task_state" => "idle", "stage" => "4-execute",
        "marker" => "complete", "recovery" => recovery
      }
    )

    stdout, = capture_io do
      Hive::Commands::Act.new(
        "workflow.retry", "demo:task", observation: "d" * 64,
        executor: executor
      ).call
    end

    assert_equal(
      "Completed — request recovery-1; attempt attempt-1; succeeded; " \
      "at 2026-07-25T15:00:00.000000Z\n",
      stdout
    )
  end

  def test_stale_observation_emits_typed_json_error_and_performs_no_action
    error = Hive::StaleOperationalObservation.new("task changed; take a fresh operational snapshot")
    executor = FakeExecutor.new(error: error)
    raised = nil
    stdout, = capture_io do
      begin
        Hive::Commands::Act.new(
          "workflow.advance", "demo:task", observation: "b" * 64,
          json: true, executor: executor
        ).call
      rescue Hive::StaleOperationalObservation => e
        raised = e
      end
    end

    assert_equal error, raised
    payload = JSON.parse(stdout)
    assert_equal false, payload.fetch("ok")
    assert_equal "stale_observation", payload.fetch("error_kind")
    assert_equal Hive::ExitCodes::TEMPFAIL, payload.fetch("exit_code")
  end

  def test_error_envelope_serialization_failure_is_raised
    executor = FakeExecutor.new(error: Hive::ConfigError.new("bad config"))
    command = Hive::Commands::Act.new(
      "workflow.advance", "demo:task", observation: "b" * 64,
      json: true, executor: executor
    )

    out, err = capture_io do
      with_replaced_singleton_method(JSON, :generate, lambda { |_payload|
        raise JSON::GeneratorError, "forced generator failure"
      }) do
        error = assert_raises(JSON::GeneratorError) { command.call }
        assert_equal "forced generator failure", error.message
      end
    end

    assert_empty out
    assert_empty err
    assert_equal 1, executor.calls.length
  end

  def test_missing_observation_is_a_usage_error_before_executor_call
    executor = FakeExecutor.new

    error = assert_raises(Hive::OperationalActionUsageError) do
      Hive::Commands::Act.new("workflow.advance", "demo:task", observation: nil, executor: executor).call
    end

    assert_match(/--observation/, error.message)
    assert_empty executor.calls
  end

  def test_missing_action_or_target_is_a_usage_error_before_executor_call
    [ [ "", "demo:task" ], [ "workflow.advance", "" ] ].each do |action_id, target|
      executor = FakeExecutor.new

      error = assert_raises(Hive::OperationalActionUsageError) do
        Hive::Commands::Act.new(action_id, target, observation: "a" * 64, executor: executor).call
      end

      assert_match(/ACTION_ID and TARGET are required/, error.message)
      assert_empty executor.calls
    end
  end

  def test_keyed_target_must_be_an_exact_project_slug_and_match_the_project_filter
    invalid = Hive::Commands::Act.new(
      "workflow.advance", "task", observation: "a" * 64, idempotency_key: "key"
    )
    error = assert_raises(Hive::OperationalActionUsageError) do
      invalid.send(:qualified_target)
    end
    assert_includes error.message, "exact project:slug"

    mismatched = Hive::Commands::Act.new(
      "workflow.advance", "demo:task", observation: "a" * 64,
      project: "other", idempotency_key: "key"
    )
    error = assert_raises(Hive::OperationalActionUsageError) do
      mismatched.send(:qualified_target)
    end
    assert_includes error.message, "--project must match"
  end

  def test_error_kinds_cover_the_closed_operational_failure_vocabulary
    command = Hive::Commands::Act.new("workflow.advance", "demo:task", observation: "a" * 64)
    errors = {
      Hive::OperationalActionUsageError.new("usage") => "usage",
      Hive::InvalidTaskPath.new("path") => "usage",
      Hive::StaleOperationalObservation.new("stale") => "stale_observation",
      Hive::WrongStage.new("wrong") => "stale_observation",
      Hive::AmbiguousSlug.new("ambiguous", slug: "task", candidates: []) => "ambiguous_target",
      Hive::ConcurrentRunError.new("locked") => "concurrent_run",
      Hive::DependencyWaitError.new("wait", offending_ref: "dep", safe_correction: "retry") => "dependency_wait",
      Hive::DependencyAdmissionError.new(
        "rejected", reason_code: "bad_dependency", offending_ref: "dep", safe_correction: "fix config"
      ) => "admission_error",
      Hive::ConfigError.new("config") => "config",
      Hive::InternalError.new("internal") => "internal",
      StandardError.new("unexpected") => "error"
    }

    errors.each do |error, kind|
      assert_equal kind, command.envelope_error_kind(error), error.class.name
    end
  end

  private

  def with_command_receipts
    Dir.mktmpdir("act-command-receipts") do |dir|
      project = File.join(dir, "project")
      FileUtils.mkdir_p(File.join(project, ".hive-state"))
      File.write(
        File.join(project, ".hive-state", "config.yml"),
        { "command_receipts" => { "keyed_intake_enabled" => true } }.to_yaml
      )
      system("git", "init", "--quiet", project, exception: true)
      database = Hive::RuntimeControlPlane::Database.new(
        path: File.join(dir, "runtime.sqlite3")
      ).migrate!
      Hive::RuntimeControlPlane::CommandSchemaInstallation.install!(
        database: database, package_coordinates: TEST_PACKAGE
      )
      yield project, Hive::CommandReceiptStore.new(database: database)
    ensure
      database&.disconnect
    end
  end
end
