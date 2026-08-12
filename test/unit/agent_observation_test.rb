require "test_helper"
require "hive/agent_observation"

class AgentObservationTest < Minitest::Test
  NOW = Time.utc(2026, 8, 12, 10, 0, 0)
  TaskStub = Struct.new(:id, :slug, :folder, :project_name, :stage_name, keyword_init: true)
  ContextStub = Struct.new(
    :attempt_id, :task_generation, :ownership_generation, :project,
    :task_slug, :intended_stage, keyword_init: true
  )

  class Activity
    attr_reader :records

    def initialize = @records = []
    def record(**attrs) = @records << attrs
  end

  def test_emits_one_start_and_one_terminal_record_with_requested_and_actual_identity
    activity = Activity.new
    observation = Hive::AgentObservation.new(
      task: task, context: context, session_id: "session-1", role: "reviewer",
      provider: "codex", requested_model: "gpt-requested", requested_effort: "high",
      timeout_sec: 90, guards: guards, activity: activity, clock: -> { NOW }
    )

    assert observation.start!
    assert observation.finish!(
      status: :ok, model: "gpt-actual", usage: { input: 10, output: 4, cached: 2 }
    )
    refute observation.finish!(status: :error)

    assert_equal %w[session_started session_finished], activity.records.map { |row| row.fetch(:kind) }
    start = activity.records.first
    finish = activity.records.last
    assert_equal "session-1", start.fetch(:correlation_id)
    assert_equal "gpt-requested", start.dig(:payload, "requested_model")
    assert_equal "gpt-actual", finish.dig(:payload, "actual_model")
    assert_equal "succeeded", finish.dig(:payload, "outcome")
    assert_equal({ "input" => 10, "output" => 4, "cached" => 2 },
                 finish.dig(:payload, "usage"))
  end

  def test_exception_timeout_and_resource_exhaustion_are_distinct_terminal_facts
    activity = Activity.new
    observation = Hive::AgentObservation.new(
      task: task, context: context, session_id: "session-2", role: "execute",
      provider: "claude", timeout_sec: 30, guards: guards,
      activity: activity, clock: -> { NOW }
    )
    observation.start!
    observation.finish!(
      { status: :error, timed_out: true,
        resource_exhaustion: { reason: "token_limit", limit: 100, observed: 105 } },
      exception: RuntimeError.new("provider failed")
    )

    payload = activity.records.last.fetch(:payload)
    assert_equal "timed_out", payload.fetch("outcome")
    assert_equal false, payload.fetch("live")
    assert_equal "token_limit", payload.dig("resource_observation", "kind")
    assert_equal 105, payload.dig("resource_observation", "observed")
    refute_includes payload.to_s, "provider failed"
  end

  def test_missing_durable_attempt_context_is_explicitly_unavailable
    activity = Activity.new
    observation = Hive::AgentObservation.new(
      task: task, context: nil, session_id: "session-3", role: "execute",
      provider: "codex", timeout_sec: 30, guards: guards, activity: activity
    )

    refute observation.available?
    refute observation.start!
    refute observation.finish!(status: :ok)
    assert_empty activity.records
  end

  def test_missing_timeout_remains_unavailable
    activity = Activity.new
    observation = Hive::AgentObservation.new(
      task: task, context: context, session_id: "session-4", role: "execute",
      provider: "codex", timeout_sec: nil, guards: guards, activity: activity,
      clock: -> { NOW }
    )

    assert observation.start!
    assert_nil activity.records.first.dig(:payload, "timeout_sec")
  end

  private

  def task
    @task ||= TaskStub.new(
      id: 7, slug: "task-260812-abcd", folder: "/safe/task",
      project_name: "demo", stage_name: "execute"
    )
  end

  def context
    @context ||= ContextStub.new(
      attempt_id: "attempt-1", task_generation: 3,
      ownership_generation: "owner-3", project: "demo",
      task_slug: task.slug, intended_stage: "4-execute"
    )
  end

  def guards
    [
      {
        "kind" => "budget_equivalent_guard", "unit" => "usd",
        "scope" => "session", "source" => "workflow_descriptor",
        "enforcement" => "provider_cli", "billing_semantics" => "subscription_backed",
        "configured" => 50, "observed" => nil
      },
      {
        "kind" => "timeout", "unit" => "seconds", "scope" => "session",
        "source" => "workflow_descriptor", "enforcement" => "controller",
        "billing_semantics" => "not_applicable", "configured" => 90,
        "observed" => nil
      }
    ]
  end
end
