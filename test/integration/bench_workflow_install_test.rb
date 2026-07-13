require "test_helper"
require "open3"
require "yaml"
require "hive/commands/init"
require "hive/commands/new"
require "hive/markers"
require "hive/task"
require "hive/task_meta"

class BenchWorkflowInstallTest < Minitest::Test
  include HiveTestHelper

  def test_init_and_new_select_builtin_bench_without_project_workflow_copy
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        project = File.basename(project_root)

        capture_io { Hive::Commands::Init.new(project_root, workflow: "bench").call }
        capture_io { Hive::Commands::New.new(project, "benchmark my task").call }

        config = YAML.safe_load_file(File.join(project_root, ".hive-state", "config.yml"))
        assert_equal "bench", config.fetch("default_workflow")
        refute_path_exists File.join(project_root, ".hive-state", "workflows", "bench.yml"),
                           "a built-in workflow must not require a copied project descriptor"
        runtime_root = File.join(project_root, ".hive-state", "bench-runtime")
        assert_path_exists File.join(runtime_root, "harness", "hive_run.rb"),
                           "bench init must install its runtime without a hive-bench checkout"
        assert_path_exists File.join(runtime_root, "campaign.yml.example")
        assert_path_exists File.join(runtime_root, "Dockerfile.runner")
        tracked_runtime, tracked_runtime_err, tracked_runtime_status = Open3.capture3(
          "git", "-C", File.join(project_root, ".hive-state"), "ls-files", "bench-runtime"
        )
        assert tracked_runtime_status.success?, tracked_runtime_err
        assert_includes tracked_runtime, "bench-runtime/harness/hive_run.rb"

        folders = Dir[File.join(project_root, ".hive-state", "stages", "1-inbox", "benchmark-my-task-*")]
        assert_equal 1, folders.size
        task = Hive::Task.new(folders.first)
        assert_equal :bench, task.workflow.id
        assert_equal "bench", Hive::TaskMeta.read(folders.first)[:workflow]
        assert_equal File.join(folders.first, "task.md"), task.state_file
        assert_equal :complete, Hive::Markers.current(task.state_file).name
      end
    end
  end
end
