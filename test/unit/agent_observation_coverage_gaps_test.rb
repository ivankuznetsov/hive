require "test_helper"
require "hive/agent_observation"

class AgentObservationCoverageGapsTest < Minitest::Test
  include HiveTestHelper

  Task = Struct.new(:slug)
  Context = Struct.new(:task_slug, :attempt_id)

  class FailingActivity
    def reconcile_operations!(*, &)
      raise Hive::TaskActivity::AppendFailed, "reconcile failed"
    end

    def record(**)
      true
    end

    def begin_operation(**)
      Object.new.tap do |operation|
        operation.define_singleton_method(:complete!) do |**|
          raise Hive::TaskActivity::AppendFailed, "append failed"
        end
        operation.define_singleton_method(:reconcile!) do
          raise Hive::TaskActivity::AppendFailed, "reconcile failed"
        end
      end
    end
  end

  def test_terminal_double_failure_returns_false_and_invalid_ids_are_rejected
    observation = Hive::AgentObservation.new(
      task: Task.new("task"), context: Context.new("task", "attempt"),
      session_id: "session", role: "agent", provider: "codex",
      timeout_sec: 1, guards: [], activity: FailingActivity.new
    )
    assert_kind_of Time, observation.instance_variable_get(:@clock).call
    observation.instance_variable_set(:@started, true)
    observation.instance_variable_set(:@started_at, Time.now.utc.iso8601(6))
    refute observation.finish!(status: :ok)

    assert_raises(ArgumentError) do
      Hive::AgentObservation.new(
        task: Task.new("task"), context: Context.new("task", "attempt"),
        session_id: "bad id", role: "agent", provider: "codex",
        timeout_sec: 1, guards: [], activity: FailingActivity.new
      )
    end
  end

  def test_activity_construction_failure_is_unavailable
    replacement = ->(*, **) { raise Hive::TaskActivity::InvalidActivity, "invalid" }
    with_replaced_singleton_method(Hive::TaskActivity, :for_context, replacement) do
      observation = Hive::AgentObservation.new(
        task: Task.new("task"), context: Context.new("task", "attempt"),
        session_id: "session", role: "agent", provider: "codex",
        timeout_sec: 1, guards: []
      )
      refute observation.available?
    end
  end

  def test_billing_and_usage_evidence_are_closed_values
    assert_raises(ArgumentError) do
      Hive::AgentObservation.new(
        task: Task.new("task"), context: Context.new("task", "attempt"),
        session_id: "session", role: "agent", provider: "codex",
        billing_route: "invoice", timeout_sec: 1, guards: [],
        activity: FailingActivity.new
      )
    end

    observation = Hive::AgentObservation.new(
      task: Task.new("task"), context: Context.new("task", "attempt"),
      session_id: "session", role: "agent", provider: "codex",
      timeout_sec: 1, guards: [], activity: FailingActivity.new
    )
    assert_raises(ArgumentError) { observation.send(:optional_boolean, "yes") }
    assert_equal [ "openai", "gpt-5.6-sol" ],
                 observation.send(:split_route, "openai/gpt-5.6-sol")
  end
end
