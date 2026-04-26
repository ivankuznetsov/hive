require "test_helper"
require "hive/commands/init"
require "hive/commands/run"

# 4-execute is impl-only since U9. The review iteration moved to the new
# 5-review stage; tests asserting EXECUTE_WAITING / EXECUTE_STALE / multi-
# pass / reviewer behavior moved to test/integration/run_review_test.rb.
class RunExecuteTest < Minitest::Test
  include HiveTestHelper

  def setup
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    @driver_path = Dir.mktmpdir("execute-driver")
    @driver_script = File.join(@driver_path, "driver.rb")
    File.write(@driver_script, driver_script_body)
    @driver_bin = File.join(@driver_path, "claude")
    File.write(@driver_bin, <<~SH)
      #!/usr/bin/env bash
      if [[ "${1:-}" == "--version" ]]; then
        echo "2.1.118 (Claude Code)"
        exit 0
      fi
      exec ruby "#{@driver_script}" "$@"
    SH
    File.chmod(0o755, @driver_bin)
    ENV["HIVE_CLAUDE_BIN"] = @driver_bin
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    FileUtils.rm_rf(@driver_path)
    FileUtils.rm_rf(@local_worktree_root) if @local_worktree_root
    %w[HIVE_EXEC_DRIVER_TASK_DIR HIVE_EXEC_DRIVER_TAMPER].each { |k| ENV.delete(k) }
  end

  # Driver: implementation agent. Edits task.md to confirm the spawn
  # actually ran. Optional plan.md tampering toggled by env.
  def driver_script_body
    <<~RUBY
      #!/usr/bin/env ruby
      require "fileutils"
      task_dir = ENV.fetch("HIVE_EXEC_DRIVER_TASK_DIR")

      # Implementer logs progress under "## Implementation".
      task_md = File.join(task_dir, "task.md")
      content = File.read(task_md)
      content = content.sub(/<!-- AGENT_WORKING.*-->/, "## Implementation\\nstub work")
      File.write(task_md, content)

      if ENV["HIVE_EXEC_DRIVER_TAMPER"]
        File.write(File.join(task_dir, "plan.md"), "TAMPERED CONTENT")
      end
      exit 0
    RUBY
  end

  def setup_execute_task(dir)
    capture_io { Hive::Commands::Init.new(dir).call }
    cfg_path = File.join(dir, ".hive-state", "config.yml")
    cfg = YAML.safe_load(File.read(cfg_path))
    @local_worktree_root = Dir.mktmpdir("worktree-root-")
    cfg["worktree_root"] = @local_worktree_root
    File.write(cfg_path, cfg.to_yaml)

    slug = "feat-x-260424-aaaa"
    folder = File.join(dir, ".hive-state", "stages", "4-execute", slug)
    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, "plan.md"), <<~PLAN)
      # plan
      ## Overview
      stub
      <!-- COMPLETE -->
    PLAN
    [ folder, slug ]
  end

  def test_init_pass_creates_worktree_and_finalizes_execute_complete
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder, _slug = setup_execute_task(dir)
        ENV["HIVE_EXEC_DRIVER_TASK_DIR"] = folder

        capture_io { Hive::Commands::Run.new(folder).call }

        wt_yml = YAML.safe_load(File.read(File.join(folder, "worktree.yml")))
        assert File.directory?(wt_yml["path"]), "worktree directory must exist"

        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :execute_complete, marker.name,
                     "4-execute is impl-only since U9; success → EXECUTE_COMPLETE"

        # Critically: there must be NO review files written. Reviewers
        # moved to 5-review.
        review_files = Dir[File.join(folder, "reviews", "*.md")]
        assert_empty review_files,
                     "4-execute must not produce review files; reviewers moved to 5-review"
      ensure
        FileUtils.rm_rf(wt_yml["path"]) if defined?(wt_yml) && wt_yml
      end
    end
  end

  def test_re_run_after_complete_announces_to_mv_to_5_review
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder, _slug = setup_execute_task(dir)
        ENV["HIVE_EXEC_DRIVER_TASK_DIR"] = folder
        capture_io { Hive::Commands::Run.new(folder).call }
        # Re-run; runner should detect EXECUTE_COMPLETE and short-circuit.
        out, err = capture_io { Hive::Commands::Run.new(folder).call }
        assert_match(/already complete/, err)
        assert_match(/5-review/, out)
      ensure
        wt_path = YAML.safe_load(File.read(File.join(folder, "worktree.yml")))["path"]
        FileUtils.rm_rf(wt_path) if wt_path
      end
    end
  end

  def test_implementer_tampering_protected_files_yields_error
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder, _slug = setup_execute_task(dir)
        ENV["HIVE_EXEC_DRIVER_TASK_DIR"] = folder
        ENV["HIVE_EXEC_DRIVER_TAMPER"] = "1"

        _, _, status = with_captured_exit { Hive::Commands::Run.new(folder).call }
        assert_equal Hive::ExitCodes::TASK_IN_ERROR, status,
                     "marker :error must map to TASK_IN_ERROR (3)"

        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :error, marker.name
        assert_equal "implementer_tampered", marker.attrs["reason"]
      ensure
        wt_path = YAML.safe_load(File.read(File.join(folder, "worktree.yml")))["path"]
        FileUtils.rm_rf(wt_path) if wt_path
      end
    end
  end

  def test_implementation_failure_surfaces_as_error
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder, _slug = setup_execute_task(dir)
        ENV["HIVE_EXEC_DRIVER_TASK_DIR"] = folder
        # Implementer exits non-zero.
        File.write(@driver_bin, <<~SH)
          #!/usr/bin/env bash
          if [[ "${1:-}" == "--version" ]]; then echo "2.1.118 (Claude Code)"; exit 0; fi
          exit 1
        SH
        File.chmod(0o755, @driver_bin)

        _, _, status = with_captured_exit { Hive::Commands::Run.new(folder).call }
        assert_equal Hive::ExitCodes::TASK_IN_ERROR, status

        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :error, marker.name
      ensure
        wt_path = begin
          YAML.safe_load(File.read(File.join(folder, "worktree.yml")))["path"]
        rescue StandardError
          nil
        end
        FileUtils.rm_rf(wt_path) if wt_path
      end
    end
  end

  def test_missing_plan_aborts
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "no-plan-260424-aaaa"
        folder = File.join(dir, ".hive-state", "stages", "4-execute", slug)
        FileUtils.mkdir_p(folder)
        _, err, status = with_captured_exit { Hive::Commands::Run.new(folder).call }
        assert_equal 1, status
        assert_includes err, "plan.md missing"
      end
    end
  end
end
