require "test_helper"
require "json_schemer"
require "hive/task_workspace"

class TaskWorkspaceSchemaTest < Minitest::Test
  def test_snapshot_is_deterministic_and_validates_against_v1
    snapshot = Hive::TaskWorkspace::Snapshot.new(
      generated_at: "2026-08-12T12:00:00Z",
      task: {
        "project" => "hive", "slug" => "workspace-task", "id" => 42,
        "stage" => "4-execute", "generation" => 3
      },
      status: {
        "state" => "current", "freshness" => "fresh",
        "observed_at" => "2026-08-12T12:00:00Z", "diagnostics" => []
      },
      decision: {
        "posture" => "wait", "reason" => "attempt is healthy",
        "action" => { "kind" => nil, "label" => nil, "enabled" => false, "reason" => "none" }
      },
      panels: {
        "provenance" => Hive::TaskWorkspace.panel("provenance") { [] }
      }
    )
    document = snapshot.to_h
    schemer = JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-task-workspace")))
    )

    assert_empty schemer.validate(document).to_a
    assert_equal Hive::TaskWorkspace.canonical_json(document), snapshot.to_json
    assert_equal Hive::TaskWorkspace::PANEL_NAMES.sort, document.fetch("panels").keys.sort
    assert_equal "unavailable", document.dig("panels", "attempts", "state")
  end

  def test_schema_rejects_sensitive_keys_absolute_evidence_and_unknown_top_level_data
    document = valid_document
    schemer = JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-task-workspace")))
    )

    refute schemer.valid?(document.merge("raw_argv" => [ "sh" ]))
    document["panels"]["timeline"]["records"] = [ { "capability_token" => "opaque" } ]
    refute schemer.valid?(document)
    document = valid_document
    document["panels"]["timeline"]["records"] = [ {
      "field" => {
        "value" => "x", "state" => "current", "source" => "task_journal",
        "evidence_ref" => "/home/user/task-journal.jsonl", "observed_at" => nil,
        "quality" => nil, "conflicts" => [], "truncated" => false
      }
    } ]
    refute schemer.valid?(document)
  end

  def test_snapshot_rejects_oversized_or_sensitive_values_before_serialization
    error = assert_raises(ArgumentError) do
      Hive::TaskWorkspace::Snapshot.new(
        generated_at: "2026-08-12T12:00:00Z",
        task: { "project" => "hive", "slug" => "task", "id" => nil,
                "stage" => "4-execute", "generation" => nil },
        status: { "state" => "current", "freshness" => "fresh",
                  "observed_at" => nil, "diagnostics" => [] },
        decision: { "posture" => "investigate", "reason" => nil,
                    "action" => { "kind" => nil, "label" => nil, "enabled" => false,
                                  "reason" => nil } },
        panels: { "timeline" => { "records" => [ { "prompt" => "secret" } ] } }
      )
    end
    assert_includes error.message, "forbidden"
  end

  private

  def valid_document
    Hive::TaskWorkspace::Snapshot.new(
      generated_at: "2026-08-12T12:00:00Z",
      task: { "project" => "hive", "slug" => "task", "id" => nil,
              "stage" => "4-execute", "generation" => nil },
      status: { "state" => "current", "freshness" => "fresh",
                "observed_at" => nil, "diagnostics" => [] },
      decision: { "posture" => "investigate", "reason" => "legacy evidence",
                  "action" => { "kind" => nil, "label" => nil, "enabled" => false,
                                "reason" => "unavailable" } },
      panels: {}
    ).to_h
  end
end
