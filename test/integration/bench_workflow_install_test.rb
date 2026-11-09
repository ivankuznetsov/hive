require "test_helper"
require "open3"
require "digest"
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
        %w[isolation.sh isolation_exec.rb].each do |name|
          assert_equal File.binread(File.join(Hive::Workflows::Bench::RUNTIME_DIR, "harness", "lib", name)),
                       File.binread(File.join(runtime_root, "harness", "lib", name))
        end
        assert_includes File.read(File.join(runtime_root, "harness", "lib", "isolation.sh")), "HB_API_KEYS"
        assert_includes File.read(File.join(runtime_root, "harness", "lib", "isolation_exec.rb")), "CREDENTIAL_POLICY_ERROR"
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

  def test_explicit_refresh_and_isolated_commit_revert_preserve_unrelated_state
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        cli = File.expand_path("../../bin/hive", __dir__)
        run!(RbConfig.ruby, cli, "init", project_root, "--workflow", "bench")
        state = File.join(project_root, ".hive-state")
        runtime = File.join(state, "bench-runtime", "harness", "lib")
        legacy = File.expand_path("../fixtures/bench_credential_legacy", __dir__)
        names = %w[isolation.sh isolation_exec.rb]
        names.each { |name| FileUtils.cp(File.join(legacy, name), File.join(runtime, name)) }
        profiles_readme = File.expand_path("../profiles/README.md", runtime)
        operator_guide = File.expand_path("../CREDENTIAL_ISOLATION.md", runtime)
        FileUtils.cp(File.join(legacy, "profiles_README.md"), profiles_readme)
        FileUtils.rm_f(operator_guide)
        run!("git", "-C", state, "add", "bench-runtime")
        run!("git", "-C", state, "commit", "-qm", "install pre-declaration runtime fixture")
        File.write(File.join(state, "operator-note.txt"), "keep this unrelated state\n")
        run!("git", "-C", state, "add", "operator-note.txt")
        run!("git", "-C", state, "commit", "-qm", "record unrelated operator state")
        old_revision = run!("git", "-C", state, "rev-parse", "HEAD").strip
        old_runtime_tree = run!("git", "-C", state, "rev-parse", "HEAD:bench-runtime").strip
        old_bytes = names.to_h { |name| [ name, File.binread(File.join(runtime, name)) ] }
        status_before = run!("git", "-C", state, "status", "--porcelain")
        config_before = File.binread(File.join(state, "config.yml"))

        output, err, status = Open3.capture3(RbConfig.ruby, cli, "init", project_root, "--workflow", "bench")
        assert status.success?, output + err
        refresh = run!("git", "-C", state, "rev-parse", "HEAD").strip
        refute_equal old_revision, refresh
        assert_equal old_revision, run!("git", "-C", state, "rev-parse", "#{refresh}^").strip
        changed = run!("git", "-C", state, "diff-tree", "--no-commit-id", "--name-only", "-r", refresh).lines.map(&:strip)
        expected_changes = names.map { |name| "bench-runtime/harness/lib/#{name}" } +
                           %w[bench-runtime/harness/profiles/README.md bench-runtime/harness/CREDENTIAL_ISOLATION.md]
        assert_equal expected_changes.sort, changed.sort
        new_bytes = names.to_h { |name| [ name, File.binread(File.join(runtime, name)) ] }
        names.each do |name|
          refute_equal old_bytes.fetch(name), new_bytes.fetch(name)
          assert_equal File.binread(File.join(Hive::Workflows::Bench::RUNTIME_DIR, "harness", "lib", name)), new_bytes.fetch(name)
        end
        assert_path_exists operator_guide
        assert_equal "keep this unrelated state\n", File.read(File.join(state, "operator-note.txt"))
        assert_equal status_before, run!("git", "-C", state, "status", "--porcelain")
        assert_equal config_before, File.binread(File.join(state, "config.yml"))

        run!("git", "-C", state, "revert", "--no-edit", refresh)
        reverted = run!("git", "-C", state, "rev-parse", "HEAD").strip
        names.each { |name| assert_equal old_bytes.fetch(name), File.binread(File.join(runtime, name)) }
        refute_path_exists operator_guide
        assert_equal File.binread(File.join(legacy, "profiles_README.md")), File.binread(profiles_readme)
        assert_equal old_runtime_tree, run!("git", "-C", state, "rev-parse", "HEAD:bench-runtime").strip
        assert_equal "keep this unrelated state\n", File.read(File.join(state, "operator-note.txt"))
        assert_empty run!("git", "-C", state, "diff", old_revision, "HEAD", "--", ".", ":(exclude)bench-runtime")
        assert_equal status_before, run!("git", "-C", state, "status", "--porcelain")
        assert_equal config_before, File.binread(File.join(state, "config.yml"))
        evidence = {
          old_revision: old_revision, refresh_commit: refresh, revert_commit: reverted,
          old_runtime_tree: old_runtime_tree, refreshed_paths: changed,
          legacy_source: "966211001e76d53da50879a582668b5b2e381607",
          files: names.to_h do |name|
            [ name, { old_sha256: Digest::SHA256.hexdigest(old_bytes.fetch(name)),
                      refreshed_sha256: Digest::SHA256.hexdigest(new_bytes.fetch(name)),
                      reverted_sha256: Digest::SHA256.file(File.join(runtime, name)).hexdigest } ]
          end
        }
        evidence_dir = File.expand_path("../../tmp", __dir__)
        FileUtils.mkdir_p(evidence_dir)
        File.write(File.join(evidence_dir, "bench-credential-refresh-evidence.json"), JSON.pretty_generate(evidence) + "\n")
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
