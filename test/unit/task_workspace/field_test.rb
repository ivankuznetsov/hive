require "test_helper"
require "hive/task_workspace"

class TaskWorkspaceFieldTest < Minitest::Test
  def test_serializes_a_typed_field_with_safe_provenance
    field = Hive::TaskWorkspace::Field.new(
      value: "abc123",
      state: "current",
      source: "task_projection",
      evidence_ref: "task-journal.jsonl#event-1",
      observed_at: "2026-08-12T12:00:00Z",
      quality: "authoritative"
    )

    assert_equal "abc123", field.to_h.fetch("value")
    assert_equal "current", field.to_h.fetch("state")
    assert_equal "task_projection", field.to_h.fetch("source")
    assert_equal [], field.to_h.fetch("conflicts")
    assert_equal false, field.to_h.fetch("truncated")
  end

  def test_resolve_uses_source_precedence_and_preserves_conflicts
    field = Hive::TaskWorkspace::Field.resolve([
      { value: "observed", source: "current_observation", observed_at: "2026-08-12T12:00:01Z" },
      { value: "captured", source: "controller_receipt", observed_at: "2026-08-12T12:00:00Z" }
    ])

    assert_equal "captured", field.value
    assert_equal "conflicting", field.state
    assert_equal %w[controller_receipt current_observation],
                 field.conflicts.map { |candidate| candidate.fetch("source") }
  end

  def test_rejects_invalid_state_source_timestamp_and_reference
    assert_raises(ArgumentError) do
      Hive::TaskWorkspace::Field.new(value: nil, state: "invented", source: "legacy")
    end
    assert_raises(ArgumentError) do
      Hive::TaskWorkspace::Field.new(value: nil, state: "missing", source: "raw argv")
    end
    assert_raises(ArgumentError) do
      Hive::TaskWorkspace::Field.new(
        value: nil, state: "missing", source: "legacy", observed_at: "yesterday"
      )
    end
    assert_raises(ArgumentError) do
      Hive::TaskWorkspace::Field.new(
        value: nil, state: "missing", source: "legacy", evidence_ref: "/etc/passwd"
      )
    end
    assert_raises(ArgumentError) do
      Hive::TaskWorkspace::Field.new(
        value: nil, state: "missing", source: "legacy", evidence_ref: "../task.md"
      )
    end
  end
end
