require "test_helper"
require "hive/config"
require "hive/resumable_workflows/registry"

class ResumableWorkflowsDeclarativeTest < Minitest::Test
  include HiveTestHelper

  Row = Struct.new(:folder, :stage, :slug, :suggested_command, keyword_init: true)
  Stage = Struct.new(:routing, :agent, :model, :effort, keyword_init: true)
  Workflow = Struct.new(:id, :resumable, :stage, keyword_init: true) do
    def stage_for_dir(_dir) = stage
    def stage_named(_name) = stage
  end

  def test_declarative_adapter_loads_snapshot_configuration_and_default_resume
    with_tmp_dir do |dir|
      path = File.join(dir, "recovery", "snapshot.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate(snapshot_payload))
      workflow = Workflow.new(
        id: "campaign", resumable: { "snapshot" => "recovery/snapshot.json" },
        stage: Stage.new(agent: "claude")
      )
      adapter = Hive::ResumableWorkflows::Registry.resolve(workflow)
      row = Row.new(folder: dir, stage: "2-run", slug: "a slug", suggested_command: nil)

      snapshot = adapter.snapshot(row: row, project_root: dir, config: {})
      configuration = adapter.configuration_for(
        child: snapshot.children.first, row: row, config: Hive::Config.merge_defaults({})
      )

      assert_equal "campaign", snapshot.workflow_id
      assert_equal "claude", configuration.pool.first.agent
      assert_equal "hive run a\\ slug", adapter.resume_command(row: row, snapshot: snapshot)
    end
  end

  def test_declarative_adapter_rejects_escape_invalid_json_and_missing_file
    with_tmp_dir do |dir|
      row = Row.new(folder: dir, stage: "2-run", slug: "campaign", suggested_command: "resume")
      escape = adapter_for("../snapshot.json")
      assert_raises(Hive::ResumableWorkflow::SnapshotError) do
        escape.snapshot(row: row, project_root: dir, config: {})
      end

      File.write(File.join(dir, "bad.json"), "{")
      invalid = adapter_for("bad.json")
      assert_raises(Hive::ResumableWorkflow::SnapshotError) do
        invalid.snapshot(row: row, project_root: dir, config: {})
      end

      missing = adapter_for("missing.json")
      assert_raises(Hive::ResumableWorkflow::SnapshotError) do
        missing.snapshot(row: row, project_root: dir, config: {})
      end
      assert_equal "resume", missing.resume_command(row: row, snapshot: nil)
    end
  end

  def test_registry_introspection_and_reset_contract
    adapter = Object.new
    Hive::ResumableWorkflows::Registry.register("temporary", adapter)
    assert Hive::ResumableWorkflows::Registry.registered?(:temporary)

    Hive::ResumableWorkflows::Registry.reset_for_tests!
    refute Hive::ResumableWorkflows::Registry.registered?(:temporary)
  ensure
    Hive::ResumableWorkflows::Registry.register(
      "bench", ->(workflow) { Hive::ResumableWorkflows::Bench.new(workflow) }
    )
  end

  private

  def adapter_for(snapshot)
    Hive::ResumableWorkflows::Registry.resolve(
      Workflow.new(id: "campaign", resumable: { "snapshot" => snapshot }, stage: Stage.new(agent: "claude"))
    )
  end

  def snapshot_payload
    {
      "schema" => "hive-resumable-workflow",
      "schema_version" => 1,
      "workflow_id" => "campaign",
      "kind" => "campaign",
      "checkpoint_generation" => 1,
      "children" => [ { "child_id" => "pending", "status" => "pending" } ]
    }
  end
end
