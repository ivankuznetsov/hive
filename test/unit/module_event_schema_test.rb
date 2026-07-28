require "test_helper"
require "json_schemer"
require "hive/modules/decision_journal"
require "hive/modules/event_ledger"

class ModuleEventSchemaTest < Minitest::Test
  include HiveTestHelper

  def test_event_and_decision_evidence_validate_against_published_schemas
    with_tmp_dir do |root|
      event = Hive::Modules::EventLedger.new(root: root).record(
        project_id: "project-1", project: "demo", event_name: "task.completed",
        occurred_at: Time.utc(2026, 7, 22), source: { type: "task", id: "task-1" },
        idempotency_key: "task-1", payload: {}, recorded_at: Time.utc(2026, 7, 22)
      ).event
      decision = Hive::Modules::DecisionJournal.new(root: root).append(
        "project_id" => "project-1", "project" => "demo", "module" => "patrol",
        "hook" => "task", "event_id" => event.fetch("event_id"),
        "event_name" => event.fetch("event_name"), "outcome" => "skip", "reason" => "disabled",
        "binding_digest" => "a" * 64, "cursor_before" => nil, "cursor_after" => nil,
        "module_generation" => "b" * 40, "configuration_digest" => "c" * 64,
        "grant_digest" => "d" * 64, "concurrency" => "drop", "attempt_id" => nil,
        "task_id" => nil, "artifacts" => [], "retry" => nil,
        "evaluated_at" => Time.utc(2026, 7, 22)
      )

      event_schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-module-event"))))
      decision_schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-module-decision"))))
      assert event_schema.valid?(event), event_schema.validate(event).to_a.inspect
      assert decision_schema.valid?(decision), decision_schema.validate(decision).to_a.inspect
    end
  end
end
