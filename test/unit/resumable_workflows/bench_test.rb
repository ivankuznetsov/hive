require "test_helper"
require "json"
require "hive/config"
require "hive/resumable_workflows/registry"
require "hive/workflows/bench"

class ResumableWorkflowsBenchTest < Minitest::Test
  include HiveTestHelper

  Row = Struct.new(:project, :slug, :stage, :folder, :suggested_command, keyword_init: true)

  def test_normalizes_complete_retryable_terminal_and_pending_cells_without_mutating_artifacts
    with_tmp_dir do |root|
      folder = File.join(root, ".hive-state", "stages", "3-generate", "campaign")
      FileUtils.mkdir_p(folder)
      File.write(
        File.join(folder, "campaign.yml"),
        YAML.dump(
          "campaign_id" => "routing",
          "tasks" => %w[complete retry failed missing],
          "candidates" => [ "all-grok" ]
        )
      )
      write_result(root, "complete", { "cells" => [
                     { "task_id" => "complete", "agent_id" => "all-grok", "run_status" => "generated" }
                   ] })
      write_result(root, "retry", { "pending" => [
                     { "task_id" => "retry", "agent_id" => "all-grok",
                       "failed_provider" => "grok", "reason" => "credit" }
                   ] })
      write_result(root, "failed", { "failed" => [
                     { "task_id" => "failed", "agent_id" => "all-grok", "reason" => "tests failed" }
                   ] })
      complete_path = result_path(root, "complete")
      before = File.binread(complete_path)

      adapter = Hive::ResumableWorkflows::Registry.resolve(Hive::Workflows::Bench::DESCRIPTOR)
      config = Hive::Config.merge_defaults({})
      snapshot = adapter.snapshot(
        row: Row.new(project: "demo", slug: "campaign", stage: "3-generate", folder: folder,
                     suggested_command: "hive generate campaign"),
        project_root: root,
        config: config
      )

      assert_equal %w[complete provider_retryable terminal pending],
                   snapshot.children.map(&:status)
      retryable = snapshot.children.fetch(1)
      assert_equal "grok", retryable.failed_provider
      assert_equal "grok", retryable.routing.dig("pool", 0, "provider")
      assert_equal before, File.binread(complete_path)
      assert_equal "hive generate campaign", adapter.resume_command(row: Row.new(suggested_command: "hive generate campaign"), snapshot: snapshot)
      configuration = adapter.configuration_for(
        child: snapshot.children.last,
        row: Row.new(stage: "3-generate"),
        config: config
      )
      assert_equal "codex", configuration.pool.first.agent
    end
  end

  def test_exclusions_missing_provenance_and_bought_patch_are_normalized
    with_tmp_dir do |root|
      folder = campaign_folder(root)
      write_campaign(
        folder,
        "tasks" => %w[excluded unknown bought empty],
        "candidates" => [ "custom" ],
        "exclusions" => [ { "task" => "excluded", "candidate" => "custom" } ]
      )
      write_result(root, "unknown", { "pending" => [
                     { "task_id" => "unknown", "agent_id" => "custom", "reason" => "waiting" }
                   ] }, candidate: "custom")
      write_result(root, "bought", {}, candidate: "custom")
      write_result(root, "empty", {}, candidate: "custom")
      patch = File.join(File.dirname(result_path(root, "bought", candidate: "custom")),
                        "attempt", "run", "target", "candidate.patch")
      FileUtils.mkdir_p(File.dirname(patch))
      File.write(patch, "diff")

      snapshot = adapter.snapshot(row: row(folder), project_root: root, config: Hive::Config.merge_defaults({}))

      assert_equal %w[terminal complete pending], snapshot.children.map(&:status)
      assert_includes snapshot.children.first.reason, "lacks configured provider"
      assert_equal Pathname.new(patch).relative_path_from(Pathname.new(root)).to_s,
                   snapshot.children.fetch(1).artifact_ref
    end
  end

  def test_campaign_and_result_validation_errors_are_visible
    with_tmp_dir do |root|
      folder = campaign_folder(root)
      File.write(File.join(folder, "campaign.yml"), YAML.dump([ "not", "a mapping" ]))
      assert_snapshot_error(root, folder, /YAML mapping/)

      File.write(File.join(folder, "campaign.yml"), "campaign_id: [\n")
      assert_snapshot_error(root, folder, /invalid YAML/)

      File.write(File.join(folder, "campaign.yml"), YAML.dump("campaign_id" => "routing"))
      assert_snapshot_error(root, folder, /missing "tasks"/)

      write_campaign(folder, "tasks" => [ "bad" ], "candidates" => [ "custom" ])
      path = result_path(root, "bad", candidate: "custom")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{")
      assert_snapshot_error(root, folder, /invalid JSON/)

      FileUtils.rm_f(File.join(folder, "campaign.yml"))
      assert_snapshot_error(root, folder, /unavailable/)
    end
  end

  def test_segment_validation_and_provider_inference_cover_supported_candidates
    assert_raises(Hive::ResumableWorkflow::SnapshotError) do
      adapter.send(:unique_segments, [], "tasks")
    end
    assert_raises(Hive::ResumableWorkflow::SnapshotError) do
      adapter.send(:unique_segments, %w[one one], "tasks")
    end
    assert_raises(Hive::ResumableWorkflow::SnapshotError) do
      adapter.send(:segment, "../escape", "tasks")
    end

    inferred = %w[all-grok-4 all-glm all-kimi glm-plan all-opus all-codex].map do |candidate|
      adapter.send(:infer_provider, candidate)
    end
    assert_equal %w[grok pi pi pi claude codex], inferred
    assert_nil adapter.send(:infer_provider, "custom")
  end

  private

  def adapter
    Hive::ResumableWorkflows::Registry.resolve(Hive::Workflows::Bench::DESCRIPTOR)
  end

  def campaign_folder(root)
    folder = File.join(root, ".hive-state", "stages", "3-generate", "campaign")
    FileUtils.mkdir_p(folder)
    folder
  end

  def row(folder)
    Row.new(project: "demo", slug: "campaign", stage: "3-generate", folder: folder,
            suggested_command: "hive generate campaign")
  end

  def write_campaign(folder, overrides = {})
    File.write(
      File.join(folder, "campaign.yml"),
      YAML.dump({ "campaign_id" => "routing" }.merge(overrides))
    )
  end

  def assert_snapshot_error(root, folder, pattern)
    error = assert_raises(Hive::ResumableWorkflow::SnapshotError) do
      adapter.snapshot(row: row(folder), project_root: root, config: Hive::Config.merge_defaults({}))
    end
    assert_match pattern, error.message
  end

  def result_path(root, task, candidate: "all-grok")
    File.join(root, "runs", "routing", "#{candidate}--#{task}", "results.json")
  end

  def write_result(root, task, content, candidate: "all-grok")
    path = result_path(root, task, candidate: candidate)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(content))
  end
end
