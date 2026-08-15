require "test_helper"
require "hive/task_workspace/attempts"

class TaskWorkspaceAttemptsTest < Minitest::Test
  NOW = "2026-08-12T10:00:00.000000Z"

  class ExactStore
    attr_reader :fetches

    def initialize(records)
      @records = records
      @fetches = []
    end

    def fetch(id)
      @fetches << id
      @records[id]
    end

    def scan
      raise "attempt workspace must never scan the global store"
    end
  end

  def test_projection_binding_selects_one_current_attempt_and_keeps_concurrent_sessions_distinct
    store = ExactStore.new(
      "attempt-a" => attempt("attempt-a", state: "terminal", outcome: "failed"),
      "attempt-b" => attempt("attempt-b", predecessor: "attempt-a")
    )
    projection = projection(
      current: "attempt-b",
      bindings: [ binding("attempt-a", predecessor: nil), binding("attempt-b", predecessor: "attempt-a") ]
    )
    panel = Hive::TaskWorkspace::Attempts.new(
      projection: projection, attempt_store: store,
      activities: [
        session_event("session-1", "session_started", role: "implementer", provider: "codex"),
        session_event("session-2", "session_started", role: "researcher", provider: "claude"),
        session_event(
          "session-1", "session_finished", role: "implementer", provider: "codex",
          actual_model: "gpt-actual", outcome: "succeeded", live: false
        )
      ]
    ).call

    assert_equal "current", panel.fetch("state")
    attempts = panel.fetch("records")
    assert_equal 2, attempts.length
    assert_equal [ false, true ], attempts.map { |row| row.fetch("current") }
    current = attempts.find { |row| row.fetch("current") }
    assert_equal "attempt-b", current.fetch("attempt_id")
    assert_equal 2, current.fetch("sessions").length
    assert_equal %w[session-1 session-2], current.fetch("sessions").map { |row| row.fetch("session_id") }
    assert_equal "gpt-actual",
                 current.fetch("sessions").first.dig("actual_model", "value")
    assert_equal "unavailable",
                 current.fetch("sessions").last.dig("actual_model", "state")
    assert_equal %w[attempt-b attempt-a], store.fetches
  end

  def test_multiple_live_attempts_without_projection_binding_are_conflicting_not_current
    store = ExactStore.new(
      "attempt-a" => attempt("attempt-a"), "attempt-b" => attempt("attempt-b")
    )
    panel = Hive::TaskWorkspace::Attempts.new(
      projection: projection(
        current: nil,
        bindings: [ binding("attempt-a", predecessor: nil), binding("attempt-b", predecessor: nil) ]
      ),
      attempt_store: store, activities: []
    ).call

    assert_equal "conflicting", panel.fetch("state")
    refute panel.fetch("records").any? { |row| row.fetch("current") }
    assert_includes panel.fetch("diagnostics").map { |row| row.fetch("reason") },
                    "current_attempt_unbound"
  end

  def test_predecessor_lookup_is_exact_bounded_and_missing_nodes_are_partial
    limits = Hive::TaskWorkspace::Limits.new(predecessor_fetches: 1)
    store = ExactStore.new(
      "attempt-c" => attempt("attempt-c", predecessor: "attempt-b"),
      "attempt-b" => attempt("attempt-b", predecessor: "attempt-a"),
      "attempt-a" => attempt("attempt-a")
    )
    panel = Hive::TaskWorkspace::Attempts.new(
      projection: projection(current: "attempt-c", bindings: []),
      attempt_store: store, activities: [], limits: limits
    ).call

    assert_equal "partial", panel.fetch("state")
    assert panel.fetch("truncated")
    assert_equal %w[attempt-c attempt-b], store.fetches
    assert_includes panel.fetch("diagnostics").map { |row| row.fetch("reason") },
                    "predecessor_fetches_exhausted"
  end

  private

  def projection(current:, bindings:)
    {
      "identity" => { "attempt_id" => current, "task_generation" => 3 },
      "journal" => { "attempts" => bindings }
    }
  end

  def binding(id, predecessor:)
    {
      "attempt_id" => id, "predecessor_attempt_id" => predecessor,
      "stage" => "4-execute", "task_generation" => 3
    }
  end

  def attempt(id, predecessor: nil, state: "running", outcome: nil)
    {
      "attempt_id" => id, "predecessor_attempt_id" => predecessor,
      "intended_stage" => "4-execute", "task_input_epoch" => 3,
      "ownership_generation" => "owner-3", "provider" => "codex",
      "routing" => { "mode" => "legacy" }, "state" => state,
      "outcome" => outcome, "accepted_at" => NOW, "started_at" => NOW,
      "ended_at" => outcome && NOW
    }
  end

  def session_event(id, kind, **payload)
    {
      "event_type" => "activity_recorded", "attempt_id" => "attempt-b",
      "occurred_at" => NOW,
      "payload" => {
        "activity_kind" => kind, "session_id" => id,
        "requested_model" => "gpt-requested", "requested_effort" => "high",
        "started_at" => NOW, "ended_at" => kind == "session_finished" ? NOW : nil,
        "health" => kind == "session_finished" ? "completed" : "live",
        "outcome" => nil, "live" => true, "timeout_sec" => 90,
        "guards" => []
      }.merge(payload.transform_keys(&:to_s))
    }
  end
end
