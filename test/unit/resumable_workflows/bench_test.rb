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
      write_result(root, "complete", "cells" => [
                     { "task_id" => "complete", "agent_id" => "all-grok", "run_status" => "generated" }
                   ])
      write_result(root, "retry", "pending" => [
                     { "task_id" => "retry", "agent_id" => "all-grok",
                       "failed_provider" => "grok", "reason" => "credit" }
                   ])
      write_result(root, "failed", "failed" => [
                     { "task_id" => "failed", "agent_id" => "all-grok", "reason" => "tests failed" }
                   ])
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
    end
  end

  private

  def result_path(root, task)
    File.join(root, "runs", "routing", "all-grok--#{task}", "results.json")
  end

  def write_result(root, task, content)
    path = result_path(root, task)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(content))
  end
end
