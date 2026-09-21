require "test_helper"
require "open3"
require "yaml"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/status"
require "hive/markers"
require "hive/task"
require "hive/task_meta"

class BenchWorkflowInstallTest < Minitest::Test
  include HiveTestHelper

  def setup
    super
    Hive::Workflows::Project.reset!
  end

  def teardown
    Hive::Workflows::Project.reset!
    super
  end

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

  def test_idempotent_bench_refresh_does_not_absorb_dirty_or_staged_config
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root).call }
        capture_io { Hive::Commands::Init.new(project_root, workflow: "bench").call }
        hive_state = File.join(project_root, ".hive-state")
        config_path = File.join(hive_state, "config.yml")
        committed_config = run!("git", "-C", hive_state, "show", "HEAD:config.yml")
        File.open(config_path, "a") { |file| file.write("# operator note: keep\n") }
        head_before = run!("git", "-C", hive_state, "rev-parse", "HEAD")

        capture_io { Hive::Commands::Init.new(project_root, workflow: "bench").call }

        assert_equal head_before, run!("git", "-C", hive_state, "rev-parse", "HEAD")
        assert_equal committed_config, run!("git", "-C", hive_state, "show", "HEAD:config.yml")
        assert_includes File.read(config_path), "# operator note: keep"
        run!("git", "-C", hive_state, "add", "config.yml")

        error = assert_raises(Hive::ConfigError) do
          Hive::Commands::Init.new(project_root, workflow: "bench").call
        end
        assert_includes error.message, "hive-state has staged changes"
        assert_includes error.message, "config.yml"
        assert_equal head_before, run!("git", "-C", hive_state, "rev-parse", "HEAD")
        assert_equal "config.yml\n", run!("git", "-C", hive_state, "diff", "--cached", "--name-only")
      end
    end
  end

  def test_runtime_install_restores_previous_runtime_after_interruption
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root).call }
        hive_state = File.join(project_root, ".hive-state")
        runtime = File.join(hive_state, "bench-runtime")
        FileUtils.mkdir_p(runtime)
        File.write(File.join(runtime, "sentinel.txt"), "previous runtime")
        run!("git", "-C", hive_state, "add", "bench-runtime")
        run!("git", "-C", hive_state, "commit", "-qm", "install previous runtime")
        assert_raises(Interrupt) do
          Hive::Workflows::Bench.install_runtime!(
            Hive::GitOps.new(project_root), before_commit: -> { raise Interrupt }
          )
        end
        assert_equal "previous runtime", File.read(File.join(runtime, "sentinel.txt"))
        refute_path_exists File.join(runtime, "harness", "hive_run.rb")
        assert_empty run!("git", "-C", hive_state, "diff", "--cached", "--name-only")
        assert_empty run!("git", "-C", hive_state, "diff", "--name-only")
      end
    end
  end
end
