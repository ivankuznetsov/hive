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

        assert_equal Hive::Workflows::Bench::DESCRIPTOR, Hive::Task.new(task_dir).workflow
        after_payload = Hive::Commands::Status.new.json_payload([
          { "name" => "legacy-bench", "path" => project_root, "hive_state_path" => hive_state }
        ])
        assert_equal %w[legacy-campaign-260714-abcd shared-instructions-260714-abcd],
                     after_payload.fetch("projects").first.fetch("tasks").map { |task| task.fetch("slug") }.sort

        changed, err, status = Open3.capture3(
          "git", "-C", hive_state, "show", "--pretty=", "--name-only", "HEAD"
        )
        assert status.success?, err
        assert_includes changed, "config.yml"
        assert_includes changed, "bench-runtime/harness/hive_run.rb"
        assert_includes changed, "workflows/bench.legacy.yml.disabled"
        assert_includes changed, "workflows/bench.legacy/generate.md"
      end
    end
  end

  def test_legacy_migration_and_rebind_roll_back_atomically_and_can_retry_when_commit_fails
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root).call }
        hive_state = File.join(project_root, ".hive-state")
        config_path = File.join(hive_state, "config.yml")
        config_before = File.binread(config_path)
        paths = write_legacy_bench_workflow(project_root)
        old_runtime = File.join(hive_state, "bench-runtime")
        FileUtils.mkdir_p(old_runtime)
        File.write(File.join(old_runtime, "sentinel.txt"), "previous runtime\n")
        run!("git", "-C", hive_state, "add", "workflows", "bench-runtime")
        run!("git", "-C", hive_state, "commit", "-qm", "install legacy bench workflow")

        hook = File.join(project_root, ".git", "hooks", "pre-commit")
        File.write(hook, "#!/bin/sh\nexit 1\n")
        FileUtils.chmod(0o755, hook)
        Hive::Workflows::Project.reset!

        error = assert_raises(Hive::GitError) do
          Hive::Commands::Init.new(project_root, workflow: "bench").call
        end
        assert_includes error.message, "commit"
        assert_equal config_before, File.binread(config_path)
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

        unstaged, unstaged_err, unstaged_status = Open3.capture3(
          "git", "-C", hive_state, "diff", "--name-only"
        )
        assert unstaged_status.success?, unstaged_err
        assert_empty unstaged

        FileUtils.rm_f(hook)
        capture_io { Hive::Commands::Init.new(project_root, workflow: "bench").call }
        assert_equal "bench", YAML.safe_load_file(config_path).fetch("default_workflow")
        refute_path_exists paths.fetch(:descriptor)
        assert_path_exists File.join(hive_state, "workflows", "bench.legacy.yml.disabled")
        assert_path_exists File.join(hive_state, "workflows", "bench.legacy", "generate.md")
        assert_path_exists File.join(old_runtime, "harness", "hive_run.rb")
        refute_path_exists File.join(old_runtime, "sentinel.txt")
        Hive::Workflows::Project.load!(project_root)
        assert_same Hive::Workflows::Bench::DESCRIPTOR, Hive::Workflows::Registry.fetch(:bench)
      end
    end
  end

  def test_runtime_install_rolls_back_archive_and_previous_runtime_on_interrupt
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

        assert_raises(Interrupt) do
          Hive::Workflows::Bench.install_runtime!(
            Hive::GitOps.new(project_root),
            before_commit: -> { raise Interrupt }
          )
        end

        assert_path_exists paths.fetch(:descriptor)
        assert_path_exists paths.fetch(:instruction_dir)
        refute_path_exists File.join(hive_state, "workflows", "bench.legacy.yml.disabled")
        refute_path_exists File.join(hive_state, "workflows", "bench.legacy")
        assert_equal "previous runtime\n", File.read(File.join(old_runtime, "sentinel.txt"))
        refute_path_exists File.join(old_runtime, "harness", "hive_run.rb")
        assert_empty run!("git", "-C", hive_state, "diff", "--cached", "--name-only")
        assert_empty run!("git", "-C", hive_state, "diff", "--name-only")
      end
    end
  end

  def test_runtime_install_records_each_move_before_delivering_async_interrupt
    %i[backup install].each do |boundary|
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
          original_mv = FileUtils.method(:mv)
          interrupted = false
          interrupting_mv = lambda do |source, destination, *args, **kwargs|
            result = original_mv.call(source, destination, *args, **kwargs)
            backup_boundary = source == old_runtime && destination.include?(".previous-")
            install_boundary = source.include?(".tmp-") && destination == old_runtime
            is_boundary = boundary == :backup ? backup_boundary : install_boundary
            if is_boundary && !interrupted
              interrupted = true
              Thread.current.raise(Interrupt)
            end
            result
          end

          with_replaced_singleton_method(FileUtils, :mv, interrupting_mv) do
            assert_raises(Interrupt, boundary.to_s) do
              Hive::Workflows::Bench.install_runtime!(Hive::GitOps.new(project_root))
            end
          end

          assert interrupted, "#{boundary} interrupt seam was not exercised"
          assert_path_exists paths.fetch(:descriptor)
          assert_path_exists paths.fetch(:instruction_dir)
          refute_path_exists File.join(hive_state, "workflows", "bench.legacy.yml.disabled")
          refute_path_exists File.join(hive_state, "workflows", "bench.legacy")
          assert_equal "previous runtime\n", File.read(File.join(old_runtime, "sentinel.txt"))
          refute_path_exists File.join(old_runtime, "harness", "hive_run.rb")
          assert_empty run!("git", "-C", hive_state, "diff", "--cached", "--name-only")
          assert_empty run!("git", "-C", hive_state, "diff", "--name-only")
        end
      end
    end
  end

  def test_interrupt_after_commit_preserves_committed_migration_instead_of_rolling_back_worktree
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
        status_before = run!("git", "-C", hive_state, "status", "--short")
        ops = Hive::GitOps.new(project_root)
        original_commit = ops.method(:hive_commit)
        ops.define_singleton_method(:hive_commit) do |**kwargs|
          result = original_commit.call(**kwargs)
          Thread.current.raise(Interrupt)
          result
        end

        assert_raises(Interrupt) { Hive::Workflows::Bench.install_runtime!(ops) }

        refute_path_exists paths.fetch(:descriptor)
        assert_path_exists File.join(hive_state, "workflows", "bench.legacy.yml.disabled")
        assert_path_exists File.join(hive_state, "workflows", "bench.legacy", "generate.md")
        assert_path_exists File.join(old_runtime, "harness", "hive_run.rb")
        refute_path_exists File.join(old_runtime, "sentinel.txt")
        assert_empty Dir.glob("#{old_runtime}.previous-*")
        assert_equal status_before, run!("git", "-C", hive_state, "status", "--short")
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
        File.open(config_path, "a") { |file| file.write("operator_note: keep\n") }
        head_before = run!("git", "-C", hive_state, "rev-parse", "HEAD")

        capture_io { Hive::Commands::Init.new(project_root, workflow: "bench").call }

        assert_equal head_before, run!("git", "-C", hive_state, "rev-parse", "HEAD")
        assert_equal committed_config, run!("git", "-C", hive_state, "show", "HEAD:config.yml")
        assert_includes File.read(config_path), "operator_note: keep"
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

  def test_legacy_migration_rejects_symlinked_instruction_root_without_copying_external_data
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root).call }
        hive_state = File.join(project_root, ".hive-state")
        paths = write_legacy_bench_workflow(project_root)
        Dir.mktmpdir("hive-external-bench") do |external|
          secret = File.join(external, "generate.md")
          HiveWorkflowTestHelper::LEGACY_BENCH_STAGES.each do |stage|
            File.write(File.join(external, "#{stage}.md"), "external #{stage}\n")
          end
          File.write(secret, "external secret\n")
          FileUtils.rm_r(paths.fetch(:instruction_dir))
          File.symlink(external, paths.fetch(:instruction_dir))
          Hive::Workflows::Project.reset!

          error = assert_raises(Hive::ConfigError) do
            Hive::Commands::Init.new(project_root, workflow: "bench").call
          end

          assert_includes error.message, "symlinked directory"
          assert_equal "external secret\n", File.read(secret)
          assert_path_exists paths.fetch(:descriptor)
          assert File.symlink?(paths.fetch(:instruction_dir))
          refute_path_exists File.join(hive_state, "workflows", "bench.legacy.yml.disabled")
          refute_path_exists File.join(hive_state, "workflows", "bench.legacy")
          refute_path_exists File.join(hive_state, "bench-runtime")
        end
      end
    end
  end

  def test_archive_publication_does_not_follow_a_raced_destination_symlink
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root).call }
        hive_state = File.join(project_root, ".hive-state")
        write_legacy_bench_workflow(project_root)
        archived_instructions = File.join(hive_state, "workflows", "bench.legacy")
        Dir.mktmpdir("hive-external-archive") do |external|
          secret = File.join(external, "secret.txt")
          File.write(secret, "keep\n")
          original_rename = File.method(:rename)
          raced = false
          racing_rename = lambda do |source, destination|
            if File.basename(destination) == "bench.legacy" && !raced
              raced = true
              File.symlink(external, destination)
            end
            original_rename.call(source, destination)
          end

          error = with_replaced_singleton_method(File, :rename, racing_rename) do
            assert_raises(Hive::ConfigError) do
              Hive::Workflows::Bench.install_runtime!(Hive::GitOps.new(project_root))
            end
          end

          assert raced, "archive target race seam was not exercised"
          assert_includes error.message, "archive target appeared"
          assert_equal "keep\n", File.read(secret)
          assert_equal [ "secret.txt" ], Dir.children(external)
          assert File.symlink?(archived_instructions)
          assert_path_exists File.join(hive_state, "workflows", "bench.yml")
          refute_path_exists File.join(hive_state, "workflows", "bench.legacy.yml.disabled")
          refute_path_exists File.join(hive_state, "bench-runtime")
        end
      end
    end
  end

  def test_archive_copy_does_not_follow_instruction_root_replaced_after_validation
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root).call }
        hive_state = File.join(project_root, ".hive-state")
        paths = write_legacy_bench_workflow(project_root)
        Dir.mktmpdir("hive-external-instructions") do |external|
          secret = File.join(external, "secret.txt")
          File.write(secret, "keep\n")
          original_cp_r = FileUtils.method(:cp_r)
          raced = false
          racing_cp_r = lambda do |source, destination, *args, **kwargs|
            if File.basename(source) == "bench" && !raced
              raced = true
              FileUtils.rm_r(paths.fetch(:instruction_dir))
              File.symlink(external, paths.fetch(:instruction_dir))
            end
            original_cp_r.call(source, destination, *args, **kwargs)
          end

          error = with_replaced_singleton_method(FileUtils, :cp_r, racing_cp_r) do
            assert_raises(Hive::ConfigError) do
              Hive::Workflows::Bench.install_runtime!(Hive::GitOps.new(project_root))
            end
          end

          assert raced, "instruction source race seam was not exercised"
          assert_includes error.message, "instruction root changed"
          assert_equal "keep\n", File.read(secret)
          assert_equal [ "secret.txt" ], Dir.children(external)
          assert_path_exists paths.fetch(:descriptor)
          assert File.symlink?(paths.fetch(:instruction_dir))
          refute_path_exists File.join(hive_state, "workflows", "bench.legacy.yml.disabled")
          refute_path_exists File.join(hive_state, "workflows", "bench.legacy")
          refute_path_exists File.join(hive_state, "bench-runtime")
        end
      end
    end
  end

  def test_migration_does_not_archive_descriptor_replaced_after_legacy_classification
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root).call }
        hive_state = File.join(project_root, ".hive-state")
        paths = write_legacy_bench_workflow(project_root)
        replacement = <<~YAML
          id: bench
          stages:
            - name: inbox
              kind: terminal
              state_file: task.md
            - name: custom
              kind: agent
              state_file: custom.md
              instruction: ./bench/generate.md
            - name: done
              kind: terminal
              state_file: task.md
        YAML
        original_archive = Hive::Workflows::Bench.method(:archive_descriptor!)
        replaced = false
        replacing_archive = lambda do |source, destination, expected:|
          replacement_path = "#{paths.fetch(:descriptor)}.replacement"
          File.write(replacement_path, replacement)
          File.rename(replacement_path, paths.fetch(:descriptor))
          replaced = true
          original_archive.call(source, destination, expected: expected)
        end

        error = with_replaced_singleton_method(
          Hive::Workflows::Bench, :archive_descriptor!, replacing_archive
        ) do
          assert_raises(Hive::ConfigError) do
            Hive::Workflows::Bench.install_runtime!(Hive::GitOps.new(project_root))
          end
        end

        assert replaced, "descriptor replacement seam was not exercised"
        assert_includes error.message, "descriptor changed during migration"
        assert_equal replacement, File.read(paths.fetch(:descriptor))
        refute_path_exists File.join(hive_state, "workflows", "bench.legacy.yml.disabled")
        refute_path_exists File.join(hive_state, "workflows", "bench.legacy")
        refute_path_exists File.join(hive_state, "bench-runtime")
      end
    end
  end

  def test_descriptor_reappearing_during_quarantine_is_preserved
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root).call }
        hive_state = File.join(project_root, ".hive-state")
        paths = write_legacy_bench_workflow(project_root)
        replacement = "custom descriptor must survive\n"
        original_unlink = File.method(:unlink)
        replaced = false
        replacing_unlink = lambda do |path|
          if path.include?("bench.yml.migrating-") && !replaced
            File.write(paths.fetch(:descriptor), replacement)
            replaced = true
          end
          original_unlink.call(path)
        end

        _out, err = capture_io do
          with_replaced_singleton_method(File, :unlink, replacing_unlink) do
            error = assert_raises(Hive::ConfigError) do
              Hive::Workflows::Bench.install_runtime!(Hive::GitOps.new(project_root))
            end
            assert_includes error.message, "descriptor path reappeared"
          end
        end

        assert replaced, "descriptor reappearance seam was not exercised"
        assert_equal replacement, File.read(paths.fetch(:descriptor))
        assert_path_exists File.join(hive_state, "workflows", "bench.legacy.yml.disabled")
        assert_includes err, "retained legacy bench descriptor recovery copy"
        refute_path_exists File.join(hive_state, "workflows", "bench.legacy")
        refute_path_exists File.join(hive_state, "bench-runtime")
      end
    end
  end

  def test_descriptor_reappearing_at_commit_entry_is_rejected_from_staged_migration
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root).call }
        hive_state = File.join(project_root, ".hive-state")
        paths = write_legacy_bench_workflow(project_root)
        legacy_descriptor = File.read(paths.fetch(:descriptor))
        old_runtime = File.join(hive_state, "bench-runtime")
        FileUtils.mkdir_p(old_runtime)
        File.write(File.join(old_runtime, "sentinel.txt"), "previous runtime\n")
        run!("git", "-C", hive_state, "add", "workflows", "bench-runtime")
        run!("git", "-C", hive_state, "commit", "-qm", "install legacy bench workflow")
        replacement = "custom descriptor must survive\n"
        ops = Hive::GitOps.new(project_root)
        original_commit = ops.method(:hive_commit)
        ops.define_singleton_method(:hive_commit) do |**kwargs|
          File.write(paths.fetch(:descriptor), replacement)
          held_replacement = "#{paths.fetch(:descriptor)}.held"
          original_after_stage = kwargs.fetch(:after_stage)
          kwargs[:after_stage] = lambda do
            File.rename(paths.fetch(:descriptor), held_replacement)
            begin
              original_after_stage.call
            ensure
              File.rename(held_replacement, paths.fetch(:descriptor))
            end
          end
          original_commit.call(**kwargs)
        end

        _out, err = capture_io do
          error = assert_raises(Hive::ConfigError) do
            Hive::Workflows::Bench.install_runtime!(ops)
          end
          assert_includes error.message, "descriptor reappeared in the staged migration"
        end

        assert_equal replacement, File.read(paths.fetch(:descriptor))
        archived_descriptor = File.join(hive_state, "workflows", "bench.legacy.yml.disabled")
        assert_equal legacy_descriptor, File.read(archived_descriptor)
        assert_includes err, "recovery copy remains"
        refute_path_exists File.join(hive_state, "workflows", "bench.legacy")
        assert_equal "previous runtime\n", File.read(File.join(old_runtime, "sentinel.txt"))
        refute_path_exists File.join(old_runtime, "harness", "hive_run.rb")
        assert_empty run!("git", "-C", hive_state, "diff", "--cached", "--name-only")
      end
    end
  end

  def test_migration_pins_workflows_parent_when_logical_path_is_replaced
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root).call }
        hive_state = File.join(project_root, ".hive-state")
        write_legacy_bench_workflow(project_root)
        workflows = File.join(hive_state, "workflows")
        original_workflows = File.join(hive_state, "workflows.original")
        Dir.mktmpdir("hive-external-workflows") do |external|
          sentinel = File.join(external, "sentinel.txt")
          File.write(sentinel, "keep\n")
          original_mktmpdir = Dir.method(:mktmpdir)
          replaced = false
          replacing_mktmpdir = lambda do |prefix = nil, parent = nil, **kwargs, &block|
            if prefix == ".bench.legacy-" && !replaced
              File.rename(workflows, original_workflows)
              File.symlink(external, workflows)
              replaced = true
            end
            original_mktmpdir.call(prefix, parent, **kwargs, &block)
          end

          error = with_replaced_singleton_method(Dir, :mktmpdir, replacing_mktmpdir) do
            assert_raises(Hive::ConfigError) do
              Hive::Workflows::Bench.install_runtime!(Hive::GitOps.new(project_root))
            end
          end

          assert replaced, "workflows parent replacement seam was not exercised"
          assert_includes error.message, "workflows directory changed"
          assert_equal "keep\n", File.read(sentinel)
          assert_equal [ "sentinel.txt" ], Dir.children(external)
          assert File.symlink?(workflows)
          assert_path_exists File.join(original_workflows, "bench.yml")
          refute_path_exists File.join(original_workflows, "bench.legacy.yml.disabled")
          refute_path_exists File.join(original_workflows, "bench.legacy")
          refute_path_exists File.join(hive_state, "bench-runtime")
        end
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
        failing_cp_r = lambda do |source, destination, *args, **kwargs|
          raise Errno::EACCES, source if File.basename(source) == "bench"

          original_cp_r.call(source, destination, *args, **kwargs)
        end

        FileUtils.define_singleton_method(:cp_r, failing_cp_r)
        error = begin
          assert_raises(Errno::EACCES) do
            Hive::Workflows::Bench.install_runtime!(Hive::GitOps.new(project_root))
          end
        ensure
          FileUtils.define_singleton_method(:cp_r, original_cp_r)
        end

        assert_includes error.message, "bench"
        assert_path_exists paths.fetch(:descriptor)
        assert_path_exists paths.fetch(:instruction_dir)
        refute_path_exists File.join(hive_state, "workflows", "bench.legacy.yml.disabled")
        refute_path_exists File.join(hive_state, "workflows", "bench.legacy")
        refute_path_exists File.join(hive_state, "bench-runtime")
      end
    end
  end


  def test_legacy_migration_restores_descriptor_when_instruction_archive_is_interrupted
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root).call }
        hive_state = File.join(project_root, ".hive-state")
        paths = write_legacy_bench_workflow(project_root)
        original_cp_r = FileUtils.method(:cp_r)
        interrupting_cp_r = lambda do |source, destination, *args, **kwargs|
          raise Interrupt if File.basename(source) == "bench"

          original_cp_r.call(source, destination, *args, **kwargs)
        end

        with_replaced_singleton_method(FileUtils, :cp_r, interrupting_cp_r) do
          assert_raises(Interrupt) do
            Hive::Workflows::Bench.install_runtime!(Hive::GitOps.new(project_root))
          end
        end

        assert_path_exists paths.fetch(:descriptor)
        assert_path_exists paths.fetch(:instruction_dir)
        refute_path_exists File.join(hive_state, "workflows", "bench.legacy.yml.disabled")
        refute_path_exists File.join(hive_state, "workflows", "bench.legacy")
        refute_path_exists File.join(hive_state, "bench-runtime")
      end
    end
  end
end
