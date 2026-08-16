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
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-task-workspace", version: 1)))
    )

    assert_empty schemer.validate(document).to_a
    assert_equal Hive::TaskWorkspace.canonical_json(document), snapshot.to_json
    assert_equal Hive::TaskWorkspace::PANEL_NAMES.sort, document.fetch("panels").keys.sort
    assert_equal({ "questions" => [], "recovery" => nil, "diagnostic_summary" => nil },
                 document.fetch("operator"))
    assert_equal "unavailable", document.dig("panels", "attempts", "state")
  end

  def test_schema_rejects_sensitive_keys_absolute_evidence_and_unknown_top_level_data
    document = valid_document
    schemer = JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-task-workspace", version: 1)))
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

  def test_each_panel_rejects_untyped_records_and_unknown_panel_properties
    schemer = JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-task-workspace", version: 1)))
    )
    Hive::TaskWorkspace::PANEL_NAMES.each do |panel_name|
      document = valid_document
      document["panels"][panel_name]["records"] = [ { "unexpected" => true } ]
      refute schemer.valid?(document), "#{panel_name} accepted an untyped record"
    end

    document = valid_document
    document["panels"]["attempts"]["unexpected"] = true
    refute schemer.valid?(document)
  end

  def test_schema_accepts_the_documented_per_artifact_string_ceiling
    document = valid_document
    document["panels"]["artifacts"] = {
      "state" => "partial", "records" => [ {
        "name" => "artifact.md", "reference" => "artifact.md",
        "content" => "a" * (400 * 1024), "bytes" => 400 * 1024,
        "truncated" => true, "invalid_encoding" => false, "binary" => false,
        "diagnostics" => []
      } ],
      "diagnostics" => [], "truncated" => true
    }
    schemer = JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-task-workspace", version: 1)))
    )

    assert schemer.valid?(document), schemer.validate(document).to_a.inspect
    assert_raises(ArgumentError) do
      Hive::TaskWorkspace.safe_value!("a" * (Hive::TaskWorkspace::SAFE_STRING_BYTES + 1))
    end
  end

  def test_semantic_v2_snapshot_is_schema_valid_and_rejects_audit_and_secret_fields
    document = Hive::TaskWorkspace::SemanticSnapshot.new(
      generated_at: "2026-08-12T12:00:00Z",
      task: {
        "project" => "hive", "slug" => "task", "id" => 42,
        "stage" => "4-execute", "generation" => 3,
        "workflow" => "content", "archived" => false
      },
      status: {
        "state" => "current", "freshness" => "fresh",
        "observed_at" => "2026-08-12T12:00:00Z"
      },
      headline: {
        "state" => "needs_input", "label" => "Needs your input",
        "explanation" => "The canonical task action needs operator input."
      },
      action: {
        "kind" => "needs_input", "label" => "Answer questions",
        "enabled" => true, "reason" => nil
      },
      result: {
        "kind" => "document", "declared_primary" => "article.md",
        "primary" => nil, "supporting" => [],
        "warning" => nil
      },
      applicability: {
        "worktree" => false, "diff" => false, "publication" => false,
        "media" => false, "dependencies" => false,
        "supporting_artifacts" => true
      },
      usage: {
        "coverage" => "unavailable", "tokens" => nil,
        "harnesses" => [], "actual_providers" => [], "actual_models" => [],
        "billing_route" => "unknown", "api_equivalent" => {
          "coverage" => "unavailable", "subtotal_usd" => nil,
          "observed_subtotal_usd" => nil, "currency" => "USD"
        },
        "groups" => []
      },
      evidence: %w[
        worktree diff publication media dependencies supporting_artifacts
      ].to_h do |name|
        [ name, { "applicable" => false, "state" => "not_applicable" } ]
      end,
      diagnostic: {
        "state" => "not_applicable", "summary" => nil,
        "log" => { "state" => "unavailable", "quality" => nil, "reference" => nil }
      }
    ).to_h
    schemer = JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-task-workspace", version: 2)))
    )

    assert_empty schemer.validate(document).to_a
    refute schemer.valid?(document.merge("attempts" => []))
    refute schemer.valid?(document.merge("prompt" => "hidden"))
    refute schemer.valid?(document.merge(
      "usage" => document.fetch("usage").merge(
        "api_equivalent" => document.dig("usage", "api_equivalent").merge(
          "provider_reported_cost" => "1.25"
        )
      )
    ))
    refute schemer.valid?(document.merge("task" => document.fetch("task").merge(
      "folder" => "/home/operator/task"
    )))
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
