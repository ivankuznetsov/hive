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
    attr_reader :records, :operations

    def initialize
      @records = []
      @operations = []
    end

    def record(**attrs) = @records << attrs

    def reconcile_operations!
      yield({}) if block_given?
      { "processed" => 0, "completed" => 0, "gaps" => 0, "diagnostics" => [] }
    end

    def begin_operation(**attrs)
      @operations << attrs
      activity = self
      Object.new.tap do |operation|
        operation.define_singleton_method(:complete!) do |payload:, evidence:, occurred_at:,
                                                         correlation_id:, **|
          activity.record(
            kind: attrs.fetch(:kind), operation_id: attrs.fetch(:operation_id),
            correlation_id: correlation_id, reason: attrs.fetch(:reason),
            source: attrs.fetch(:source), occurred_at: occurred_at,
            payload: payload, evidence: evidence
          )
        end
      end
    end
  end

  class FlakyTerminalActivity < Activity
    attr_reader :reconciliations

    def initialize
      super
      @reconciliations = 0
      @pending_terminal = nil
    end

    def reconcile_operations!
      @reconciliations += 1
      if @pending_terminal
        record(**@pending_terminal)
        @pending_terminal = nil
        return { "processed" => 1, "completed" => 1, "gaps" => 0, "diagnostics" => [] }
      end
      super
    end

    def begin_operation(**attrs)
      activity = self
      Object.new.tap do |operation|
        committed = false
        operation.define_singleton_method(:complete!) do |payload:, evidence:, occurred_at:,
                                                         correlation_id:, **|
          committed = true
          activity.instance_variable_set(:@pending_terminal, {
            kind: attrs.fetch(:kind), operation_id: attrs.fetch(:operation_id),
            correlation_id: correlation_id, reason: attrs.fetch(:reason),
            source: attrs.fetch(:source), occurred_at: occurred_at,
            payload: payload, evidence: evidence
          })
          raise Hive::TaskActivity::AppendFailed, "first append failed"
        end
        operation.define_singleton_method(:reconcile!) do
          next false unless committed

          activity.reconcile_operations!
          true
        end
      end
    end
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
    assert_equal "session-1", finish.fetch(:correlation_id)
    assert_equal "gpt-requested", start.dig(:payload, "requested_model")
    assert_equal "gpt-actual", finish.dig(:payload, "actual_model")
    assert_equal "succeeded", finish.dig(:payload, "outcome")
    assert_equal({ "input" => 10, "output" => 4, "cached" => 2 },
                 finish.dig(:payload, "usage"))
    assert_equal "session_finished", activity.operations.fetch(0).fetch(:kind)
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

  def test_claude_timeout_status_is_a_timed_out_terminal_fact
    activity = Activity.new
    observation = Hive::AgentObservation.new(
      task: task, context: context, session_id: "session-timeout", role: "execute",
      provider: "claude", timeout_sec: 30, guards: guards,
      activity: activity, clock: -> { NOW }
    )

    assert observation.start!
    assert observation.finish!(status: :timeout, error_message: "deadline reached")

    payload = activity.records.last.fetch(:payload)
    assert_equal true, payload.fetch("timed_out")
    assert_equal "timed_out", payload.fetch("outcome")
    assert_equal "timed_out", payload.fetch("health")
    assert_equal false, payload.fetch("live")
  end

  def test_terminal_append_uses_a_replayable_operation_receipt
    activity = Activity.new
    observation = Hive::AgentObservation.new(
      task: task, context: context, session_id: "session-replay", role: "execute",
      provider: "codex", timeout_sec: 30, guards: guards,
      activity: activity, clock: -> { NOW }
    )

    observation.start!
    observation.finish!(status: :ok)

    operation = activity.operations.fetch(0)
    assert_equal "session:session-replay:finish", operation.fetch(:operation_id)
    assert_equal({ "session_id" => "session-replay", "live" => true },
                 operation.fetch(:precondition))
    assert_equal({ "session_id" => "session-replay", "live" => false },
                 operation.fetch(:expected_postcondition))
  end

  def test_failed_terminal_append_is_reconciled_before_returning
    activity = FlakyTerminalActivity.new
    observation = Hive::AgentObservation.new(
      task: task, context: context, session_id: "session-recovered", role: "execute",
      provider: "codex", timeout_sec: 30, guards: guards,
      activity: activity, clock: -> { NOW }
    )

    assert observation.start!
    assert observation.finish!(status: :ok)

    assert_operator activity.reconciliations, :>=, 2
    assert_equal %w[session_started session_finished],
                 activity.records.map { |record| record.fetch(:kind) }
  end

  def test_finish_refuses_to_append_without_a_durable_start
    activity = Activity.new
    activity.define_singleton_method(:record) do |**attrs|
      raise Hive::TaskActivity::AppendFailed, "start failed" if attrs[:kind] == "session_started"
      super(**attrs)
    end
    observation = Hive::AgentObservation.new(
      task: task, context: context, session_id: "session-no-start", role: "execute",
      provider: "codex", timeout_sec: 30, guards: guards,
      activity: activity, clock: -> { NOW }
    )

    refute observation.finish!(status: :ok)
    assert_empty activity.operations
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
