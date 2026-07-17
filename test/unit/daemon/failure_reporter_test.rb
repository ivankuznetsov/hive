require "test_helper"
require "hive/daemon/failure_reporter"

class FailureReporterTest < Minitest::Test
  FakeWorkflow = Struct.new(:id)
  FakeTask = Struct.new(
    :folder, :project_root, :state_file, :slug, :stage_index, :stage_name, :workflow,
    keyword_init: true
  )

  class FakeAttempt
    attr_reader :state, :outcome, :receipt, :attempt_id, :task_input_epoch,
                :ownership_generation

    def initialize(state: "lost", outcome: nil, receipt: nil, data: {})
      @state = state
      @outcome = outcome
      @receipt = receipt
      @attempt_id = "attempt-1"
      @task_input_epoch = 7
      @ownership_generation = "owner-7"
      @data = {
        "project" => "demo", "task_id" => "42", "task_slug" => "task-a",
        "intended_stage" => "4-execute", "provider" => "codex",
        "diagnostics" => {}, "loss" => { "reason" => "owner_gone", "at" => "2026-07-17T10:00:00Z" }
      }.merge(data)
    end

    def [](key) = @data[key]
    def final? = %w[lost terminal].include?(state)
  end

  class FakeCoordinator
    attr_reader :failures
    def initialize = @failures = []
    def report_failure(**args) = @failures << args
    def current = nil
  end

  def test_lost_attempt_reports_agent_died_with_sanitized_evidence
    coordinator = FakeCoordinator.new
    task = FakeTask.new(
      folder: "/tmp/task", project_root: "/tmp/demo", state_file: "/does/not/exist.md",
      slug: "task-a", stage_index: 4, stage_name: "execute", workflow: FakeWorkflow.new("coding")
    )
    reporter = Hive::Daemon::FailureReporter.new(
      attempt_store: Object.new, task_resolver: ->(_attempt) { task },
      coordinator_factory: ->(_task, _attempt) { coordinator }
    )

    reporter.observe(
      FakeAttempt.new,
      payload: { "message" => "worker died API_TOKEN=topsecret /home/alice/private.log" }
    )

    failure = coordinator.failures.fetch(0)
    assert_equal "agent_died", failure.fetch(:code)
    assert_equal "agent_died", failure.fetch(:failure_class)
    assert_equal 7, failure.fetch(:generation)
    serialized = JSON.generate(failure.fetch(:evidence))
    refute_includes serialized, "topsecret"
    refute_includes serialized, "/home/alice"
  end

  def test_terminal_auth_diagnostic_is_canonical_and_keeps_provider_tool_context
    coordinator = FakeCoordinator.new
    task = FakeTask.new(
      folder: "/tmp/task", project_root: "/tmp/demo", state_file: "/does/not/exist.md",
      slug: "task-a", stage_index: 4, stage_name: "execute", workflow: FakeWorkflow.new("coding")
    )
    receipt = { "exit_status" => 1, "ended_at" => "2026-07-17T10:00:00Z" }
    attempt = FakeAttempt.new(state: "terminal", outcome: "failed", receipt: receipt)
    reporter = Hive::Daemon::FailureReporter.new(
      attempt_store: Object.new, task_resolver: ->(_attempt) { task },
      coordinator_factory: ->(_task, _attempt) { coordinator }
    )

    reporter.observe(
      attempt, code: "implementer_failed", failure_class: "provider_failure",
      payload: { "provider" => "codex", "tool" => "honeycomb-mcp", "message" => "401 missing bearer auth" }
    )

    failure = coordinator.failures.fetch(0)
    assert_equal "codex_auth", failure.fetch(:code)
    assert_equal "provider_failure", failure.fetch(:failure_class)
    evidence = JSON.generate(failure.fetch(:evidence))
    assert_includes evidence, "honeycomb-mcp"
    assert_includes evidence, "401 missing bearer auth"
  end
end
