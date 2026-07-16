require "test_helper"
require "json_schemer"
require "hive/resumable_workflow"

class ResumableWorkflowTest < Minitest::Test
  def test_snapshot_normalizes_the_closed_child_status_contract
    snapshot = Hive::ResumableWorkflow::Snapshot.from_h(
      {
        "schema" => "hive-resumable-workflow",
        "schema_version" => 1,
        "workflow_id" => "project/campaign",
        "kind" => "campaign",
        "checkpoint_generation" => 4,
        "children" => [
          { "child_id" => "done", "status" => "complete", "artifact_ref" => "artifacts/done.json" },
          { "child_id" => "new", "status" => "pending" },
          { "child_id" => "retry", "status" => "provider_retryable", "failed_provider" => "grok" },
          { "child_id" => "bad", "status" => "terminal", "reason" => "semantic failure" }
        ]
      }
    )

    assert_equal %w[new retry], snapshot.retryable_children.map(&:child_id)
    assert snapshot.children.first.immutable?
    assert_match(/\Asha256:/, snapshot.checkpoint_fingerprint)
  end

  def test_snapshot_rejects_invalid_children_and_checkpoint_shapes
    error = assert_raises(Hive::ResumableWorkflow::SnapshotError) do
      snapshot(children: [ child("same", "pending"), child("same", "terminal") ])
    end
    assert_includes error.message, "duplicate child IDs"

    assert_raises(Hive::ResumableWorkflow::SnapshotError) do
      snapshot(children: [ child("retry", "provider_retryable") ])
    end
    assert_raises(Hive::ResumableWorkflow::SnapshotError) do
      snapshot(children: [ child("done", "complete") ])
    end
    assert_raises(Hive::ResumableWorkflow::SnapshotError) do
      snapshot(children: [ child("done", "complete", "artifact_ref" => "../secret") ])
    end
    assert_raises(Hive::ResumableWorkflow::SnapshotError) do
      snapshot(children: [ child("mystery", "invented") ])
    end
  end

  def test_published_schema_matches_runtime_requirements
    schemer = JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-resumable-workflow")))
    )
    valid = {
      "schema" => "hive-resumable-workflow",
      "schema_version" => 1,
      "workflow_id" => "project/campaign",
      "kind" => "campaign",
      "checkpoint_generation" => 1,
      "children" => [
        { "child_id" => "retry", "status" => "provider_retryable", "failed_provider" => "grok" }
      ]
    }

    assert schemer.valid?(valid)
    refute schemer.valid?(valid.merge("children" => [ { "child_id" => "retry", "status" => "provider_retryable" } ]))
    refute schemer.valid?(valid.merge("children" => [ { "child_id" => "done", "status" => "complete" } ]))
  end

  private

  def snapshot(children:)
    Hive::ResumableWorkflow::Snapshot.new(
      workflow_id: "project/campaign", kind: "campaign",
      checkpoint_generation: 1, children: children
    )
  end

  def child(id, status, extras = {})
    { "child_id" => id, "status" => status }.merge(extras)
  end
end
