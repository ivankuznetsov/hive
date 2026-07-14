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

  def test_reinit_migrates_exact_legacy_bench_workflow_without_stranding_tasks
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root).call }
        hive_state = File.join(project_root, ".hive-state")
        paths = write_legacy_bench_workflow(project_root)
        File.write(File.join(hive_state, "workflows", "bench-generate.yml"), <<~YAML)
          id: bench-generate
          stages:
            - name: inbox
              kind: terminal
              state_file: task.md
            - name: generate
              kind: agent
              state_file: generate.md
              instruction: ./bench/generate.md
              advance_verb: generate
            - name: done
              kind: terminal
              state_file: task.md
        YAML
        task_dir = File.join(hive_state, "stages", "3-generate", "legacy-campaign-260714-abcd")
        FileUtils.mkdir_p(task_dir)
        File.write(File.join(task_dir, "generate.md"), "<!-- WAITING -->\n")
        Hive::TaskMeta.write(task_dir, id: 7, slug: File.basename(task_dir), display_name: nil, workflow: "bench")
        sibling_task_dir = File.join(hive_state, "stages", "2-generate", "shared-instructions-260714-abcd")
        FileUtils.mkdir_p(sibling_task_dir)
        File.write(File.join(sibling_task_dir, "generate.md"), "<!-- WAITING -->\n")
        Hive::TaskMeta.write(sibling_task_dir, id: 8, slug: File.basename(sibling_task_dir),
                             display_name: nil, workflow: "bench-generate")
        run!("git", "-C", hive_state, "add", "workflows", "stages/2-generate", "stages/3-generate")
        run!("git", "-C", hive_state, "commit", "-qm", "install legacy bench workflow")
        Hive::Workflows::Project.reset!

        legacy = Hive::Task.new(task_dir).workflow
        assert_equal paths.fetch(:instruction_dir), File.dirname(legacy.stage_named("generate").instruction)
        before_payload = Hive::Commands::Status.new.json_payload([
          { "name" => "legacy-bench", "path" => project_root, "hive_state_path" => hive_state }
        ])
        assert_equal %w[legacy-campaign-260714-abcd shared-instructions-260714-abcd],
                     before_payload.fetch("projects").first.fetch("tasks").map { |task| task.fetch("slug") }.sort

        capture_io { Hive::Commands::Init.new(project_root, workflow: "bench").call }

        refute_path_exists paths.fetch(:descriptor)
        assert_path_exists paths.fetch(:instruction_dir)
        archived_descriptor = File.join(hive_state, "workflows", "bench.legacy.yml.disabled")
        archived_instructions = File.join(hive_state, "workflows", "bench.legacy")
        assert_path_exists archived_descriptor
        assert_path_exists archived_instructions
        assert_equal "Legacy local generate instructions.\n",
                     File.read(File.join(archived_instructions, "generate.md"))
        assert_path_exists File.join(hive_state, "bench-runtime", "harness", "hive_run.rb")

        Hive::Workflows::Project.reset!
        assert_equal Hive::Workflows::Bench::DESCRIPTOR, Hive::Task.new(task_dir).workflow
        after_payload = Hive::Commands::Status.new.json_payload([
          { "name" => "legacy-bench", "path" => project_root, "hive_state_path" => hive_state }
        ])
        assert_equal %w[legacy-campaign-260714-abcd shared-instructions-260714-abcd],
                     after_payload.fetch("projects").first.fetch("tasks").map { |task| task.fetch("slug") }.sort

        changed, err, status = Open3.capture3(
          "git", "-C", hive_state, "show", "--pretty=", "--name-only", "HEAD~2..HEAD"
        )
        assert status.success?, err
        assert_includes changed, "bench-runtime/harness/hive_run.rb"
        assert_includes changed, "workflows/bench.legacy.yml.disabled"
      end
    end
  end

  def test_legacy_migration_rolls_back_files_and_index_when_commit_fails
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root).call }
        hive_state = File.join(project_root, ".hive-state")
        paths = write_legacy_bench_workflow(project_root)
        old_runtime = File.join(hive_state, "bench-runtime")
        FileUtils.mkdir_p(old_runtime)
        File.write(File.join(old_runtime, "sentinel.txt"), "previous runtime\n")
        run!("git", "-C", hive_state, "add", "workflows", "bench-runtime")
        run!("git", "-C", hive_state, "commit", "-qm", "install legacy bench workflow")

        hook = File.join(project_root, ".git", "hooks", "pre-commit")
        File.write(hook, "#!/bin/sh\nexit 1\n")
        FileUtils.chmod(0o755, hook)

        error = assert_raises(Hive::GitError) do
          Hive::Workflows::Bench.install_runtime!(Hive::GitOps.new(project_root))
        end
        assert_includes error.message, "commit"
        assert_path_exists paths.fetch(:descriptor)
        assert_path_exists paths.fetch(:instruction_dir)
        refute_path_exists File.join(hive_state, "workflows", "bench.legacy.yml.disabled")
        refute_path_exists File.join(hive_state, "workflows", "bench.legacy")
        assert_equal "previous runtime\n", File.read(File.join(old_runtime, "sentinel.txt"))
        refute_path_exists File.join(old_runtime, "harness", "hive_run.rb")

        staged, staged_err, staged_status = Open3.capture3(
          "git", "-C", hive_state, "diff", "--cached", "--name-only"
        )
        assert staged_status.success?, staged_err
        assert_empty staged
      end
    end
  end

  def test_legacy_migration_refuses_to_overwrite_an_existing_archive
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root).call }
        hive_state = File.join(project_root, ".hive-state")
        paths = write_legacy_bench_workflow(project_root)
        archived_descriptor = File.join(hive_state, "workflows", "bench.legacy.yml.disabled")
        File.write(archived_descriptor, "existing recovery copy\n")

        error = assert_raises(Hive::ConfigError) do
          Hive::Workflows::Bench.install_runtime!(Hive::GitOps.new(project_root))
        end

        assert_includes error.message, archived_descriptor
        assert_path_exists paths.fetch(:descriptor)
        assert_path_exists paths.fetch(:instruction_dir)
        assert_equal "existing recovery copy\n", File.read(archived_descriptor)
        refute_path_exists File.join(hive_state, "bench-runtime")
      end
    end
  end

  def test_legacy_migration_restores_descriptor_when_instruction_archive_copy_fails
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root).call }
        hive_state = File.join(project_root, ".hive-state")
        paths = write_legacy_bench_workflow(project_root)
        original_cp_r = FileUtils.method(:cp_r)
        failing_cp_r = lambda do |source, destination, *args|
          raise Errno::EACCES, source if source == paths.fetch(:instruction_dir)

          original_cp_r.call(source, destination, *args)
        end

        FileUtils.define_singleton_method(:cp_r, failing_cp_r)
        error = begin
          assert_raises(Errno::EACCES) do
            Hive::Workflows::Bench.install_runtime!(Hive::GitOps.new(project_root))
          end
        ensure
          FileUtils.define_singleton_method(:cp_r, original_cp_r)
        end

        assert_includes error.message, paths.fetch(:instruction_dir)
        assert_path_exists paths.fetch(:descriptor)
        assert_path_exists paths.fetch(:instruction_dir)
        refute_path_exists File.join(hive_state, "workflows", "bench.legacy.yml.disabled")
        refute_path_exists File.join(hive_state, "workflows", "bench.legacy")
        refute_path_exists File.join(hive_state, "bench-runtime")
      end
    end
  end
end
