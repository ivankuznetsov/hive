require "test_helper"
require "json_schemer"
require "hive/commands/act"

class CommandsActTest < Minitest::Test
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

  def test_human_success_is_concise
    stdout, = capture_io do
      Hive::Commands::Act.new(
        "workflow.advance", "demo:task", observation: "a" * 64, executor: FakeExecutor.new
      ).call
    end

    assert_equal "advanced demo:task — idle at 3-plan (complete)\n", stdout
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
      "Retry available later — eligible 2026-07-20T11:00:00.000000Z; shared cooldown\n",
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
end
