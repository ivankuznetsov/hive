require "test_helper"
require "json"
require "hive/daemon/status_consumer"
require "hive/daemon/workflow_recovery"
require "hive/provider_routing/store"

class ResumableWorkflowRecoveryIntegrationTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)

  def test_two_coordinators_dispatch_one_outer_resume_and_preserve_complete_artifacts
    with_tmp_dir do |root|
      folder = File.join(root, ".hive-state", "stages", "2-run", "campaign")
      artifact = File.join(folder, "artifacts", "paid.json")
      snapshot_path = File.join(folder, "recovery", "snapshot.json")
      FileUtils.mkdir_p(File.dirname(artifact))
      FileUtils.mkdir_p(File.dirname(snapshot_path))
      File.write(artifact, "paid-and-immutable\n")
      File.write(snapshot_path, JSON.pretty_generate(snapshot_document))
      artifact_before = File.binread(artifact)

      leases = Hive::AttemptLeaseStore.new(path: File.join(root, "leases.json"), clock: -> { NOW })
      circuits = Hive::ProviderRouting::Store.new(path: File.join(root, "circuits.json"), clock: -> { NOW })
      router = Hive::ProviderRouting::Router.new(
        circuit_store: circuits, lease_store: leases, clock: -> { NOW }
      )
      workflow = declarative_workflow
      row = status_row(folder)
      build = lambda do
        Hive::Daemon::WorkflowRecovery.new(
          router: router,
          lease_store: leases,
          project_resolver: ->(_name) { { "path" => root } },
          config_loader: ->(_path) { {} },
          workflow_resolver: ->(_name, _path) { workflow }
        )
      end

      first = build.call.candidates([ row ], now: NOW)
      racing = build.call.candidates([ row ], now: NOW)

      assert_equal 1, first.length
      assert_empty racing
      build.call.finish(first.first, dispatched: true, now: NOW)
      assert_empty build.call.candidates([ row ], now: NOW)
      assert_equal artifact_before, File.binread(artifact)
      assert_equal "hive run campaign", first.first.command
    end
  end

  private

  def declarative_workflow
    Hive::Workflow.new(
      id: :campaign,
      resumable: { "snapshot" => "recovery/snapshot.json", "resume" => "run" },
      stages: [
        Hive::Workflow::Stage.new(
          name: "run", index: 1, state_file: "run.md", kind: :agent, agent: "claude"
        )
      ]
    )
  end

  def status_row(folder)
    Hive::Daemon::StatusConsumer::Row.new(
      project: "demo", slug: "campaign", stage: "1-run", workflow: "campaign",
      folder: folder, state_file: File.join(folder, "run.md"),
      state_file_mtime: NOW, action: "error", suggested_command: "hive run campaign",
      live_task_lock: false
    )
  end

  def snapshot_document
    {
      "schema" => "hive-resumable-workflow",
      "schema_version" => 1,
      "workflow_id" => "demo/campaign",
      "kind" => "campaign",
      "checkpoint_generation" => 9,
      "children" => [
        { "child_id" => "paid", "status" => "complete", "artifact_ref" => "artifacts/paid.json" },
        { "child_id" => "retry", "status" => "provider_retryable", "failed_provider" => "claude" },
        { "child_id" => "terminal", "status" => "terminal", "reason" => "semantic failure" }
      ]
    }
  end
end
