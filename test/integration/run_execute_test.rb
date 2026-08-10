require "test_helper"
require "json"
require "hive/commands/init"
require "hive/commands/run"

# 4-execute is impl-only since U9. The review iteration moved to the new
# 6-review stage; tests asserting EXECUTE_WAITING / EXECUTE_STALE / multi-
# pass / reviewer behavior moved to test/integration/run_review_test.rb.
class RunExecuteTest < Minitest::Test
  include HiveTestHelper

  def setup
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    @prev_codex_bin = ENV["HIVE_CODEX_BIN"]
    @driver_path = Dir.mktmpdir("execute-driver")
    @driver_script = File.join(@driver_path, "driver.rb")
    File.write(@driver_script, driver_script_body)
    @driver_bin = File.join(@driver_path, "claude")
    File.write(@driver_bin, <<~SH)
      #!/usr/bin/env bash
      if [[ "${1:-}" == "--version" ]]; then
        # Both claude and codex profiles probe --version; emit a string the
        # SemVer parser accepts for either profile (>= 2.1.118 is fine for
        # claude; codex's min is 0.125.0 so the same string passes).
        echo "2.1.118 (Claude Code)"
        exit 0
      fi
      exec ruby "#{@driver_script}" "$@"
    SH
    File.chmod(0o755, @driver_bin)
    ENV["HIVE_CLAUDE_BIN"] = @driver_bin
    # ADR-023: rendered templates default execute.agent to codex, so the
    # 4-execute spawn resolves the codex profile. Point both bins at the
    # same fake driver so the test doesn't depend on which CLI is picked.
    ENV["HIVE_CODEX_BIN"] = @driver_bin
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    ENV["HIVE_CODEX_BIN"] = @prev_codex_bin
    FileUtils.rm_rf(@driver_path)
    FileUtils.rm_rf(@local_worktree_root) if @local_worktree_root
    %w[
      HIVE_EXEC_DRIVER_TASK_DIR
      HIVE_EXEC_DRIVER_TAMPER
      HIVE_EXEC_DRIVER_SKIP_COMMIT
      HIVE_EXEC_DRIVER_OUTPUT
      HIVE_EXEC_DRIVER_DIRTY
      HIVE_EXEC_DRIVER_CLEAN_DIRTY
      HIVE_EXEC_DRIVER_WRONG_BRANCH
    ].each { |k| ENV.delete(k) }
  end

  # Driver: implementation agent. Edits task.md to confirm the spawn
  # actually ran, writes/commits worktree content by default, and can
  # optionally simulate no-change research runs. Optional plan.md tampering
  # toggled by env.
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

      if ENV["HIVE_EXEC_DRIVER_CLEAN_DIRTY"]
        FileUtils.rm_f("dirty.txt")
      end

      if ENV["HIVE_EXEC_DRIVER_WRONG_BRANCH"]
        system("git", "checkout", "-b", "wrong-execute-branch", "--quiet") || abort("git checkout failed")
      end

      unless ENV["HIVE_EXEC_DRIVER_SKIP_COMMIT"]
        File.write("implementation.txt", "implemented\\n")
        system("git", "add", "implementation.txt") || abort("git add failed")
        system("git", "commit", "-m", "feat: implement test change", "--quiet") || abort("git commit failed")
      end

      if ENV["HIVE_EXEC_DRIVER_DIRTY"]
        File.write("dirty.txt", "left behind\\n")
      end

      output = ENV["HIVE_EXEC_DRIVER_OUTPUT"].to_s
      puts output unless output.empty?
      exit 0
    RUBY
  end

  def setup_execute_task(dir, plan_header: nil)
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
      #{plan_header}
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
        assert_empty marker.attrs

        # Critically: there must be NO review files written. Reviewers
        # moved to 6-review.
        review_files = Dir[File.join(folder, "reviews", "*.md")]
        assert_empty review_files,
                     "4-execute must not produce review files; reviewers moved to 6-review"
      ensure
        FileUtils.rm_rf(wt_yml["path"]) if defined?(wt_yml) && wt_yml
      end
    end
  end

  def test_clean_exit_without_worktree_changes_pauses_with_agent_output
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder, _slug = setup_execute_task(dir)
        ENV["HIVE_EXEC_DRIVER_TASK_DIR"] = folder
        ENV["HIVE_EXEC_DRIVER_SKIP_COMMIT"] = "1"
        ENV["HIVE_EXEC_DRIVER_OUTPUT"] = "Investigation complete; preserve \\1 and \\&."

        capture_io { Hive::Commands::Run.new(folder).call }

        task_md = File.read(File.join(folder, "task.md"))
        assert_includes task_md, "## Execute Output"
        assert_includes task_md, "Investigation complete; preserve \\1 and \\&."

        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :execute_waiting, marker.name
        assert_equal "no_worktree_changes", marker.attrs["reason"]
      ensure
        wt_path = YAML.safe_load(File.read(File.join(folder, "worktree.yml")))["path"] if defined?(folder)
        FileUtils.rm_rf(wt_path) if wt_path
      end
    end
  end

  def test_research_mode_can_complete_without_worktree_commit_when_output_exists
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder, _slug = setup_execute_task(dir, plan_header: <<~YAML)
          ---
          execution_mode: research
          ---
        YAML
        ENV["HIVE_EXEC_DRIVER_TASK_DIR"] = folder
        ENV["HIVE_EXEC_DRIVER_SKIP_COMMIT"] = "1"
        ENV["HIVE_EXEC_DRIVER_OUTPUT"] = JSON.generate(
          "type" => "result",
          "subtype" => "success",
          "result" => "Research complete; use option B."
        )

        capture_io { Hive::Commands::Run.new(folder).call }

        task_md = File.read(File.join(folder, "task.md"))
        assert_includes task_md, "## Execute Output"
        assert_includes task_md, "Research complete; use option B."

        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :execute_complete, marker.name
        assert_equal "research", marker.attrs["mode"]
      ensure
        wt_path = YAML.safe_load(File.read(File.join(folder, "worktree.yml")))["path"] if defined?(folder)
        FileUtils.rm_rf(wt_path) if wt_path
      end
    end
  end

  def test_research_mode_accepts_plain_agent_output_for_completion
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder, _slug = setup_execute_task(dir, plan_header: <<~YAML)
          ---
          execution_mode: research
          ---
        YAML
        ENV["HIVE_EXEC_DRIVER_TASK_DIR"] = folder
        ENV["HIVE_EXEC_DRIVER_SKIP_COMMIT"] = "1"
        ENV["HIVE_EXEC_DRIVER_OUTPUT"] = "warning: transient progress only"

        capture_io { Hive::Commands::Run.new(folder).call }

        task_md = File.read(File.join(folder, "task.md"))
        assert_includes task_md, "warning: transient progress only"

        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :execute_complete, marker.name
        assert_equal "research", marker.attrs["mode"]
      ensure
        wt_path = YAML.safe_load(File.read(File.join(folder, "worktree.yml")))["path"] if defined?(folder)
        FileUtils.rm_rf(wt_path) if wt_path
      end
    end
  end

  def test_research_mode_without_output_still_pauses
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder, _slug = setup_execute_task(dir, plan_header: <<~YAML)
          ---
          execution_mode: research
          ---
        YAML
        ENV["HIVE_EXEC_DRIVER_TASK_DIR"] = folder
        ENV["HIVE_EXEC_DRIVER_SKIP_COMMIT"] = "1"

        capture_io { Hive::Commands::Run.new(folder).call }

        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :execute_waiting, marker.name
        assert_equal "missing_research_output", marker.attrs["reason"]
      ensure
        wt_path = YAML.safe_load(File.read(File.join(folder, "worktree.yml")))["path"] if defined?(folder)
        FileUtils.rm_rf(wt_path) if wt_path
      end
    end
  end

  def test_non_hash_research_frontmatter_is_rejected_before_execute_side_effects
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder, _slug = setup_execute_task(dir, plan_header: <<~YAML)
          ---
          - execution_mode: research
          ---
        YAML
        ENV["HIVE_EXEC_DRIVER_TASK_DIR"] = folder
        ENV["HIVE_EXEC_DRIVER_SKIP_COMMIT"] = "1"
        ENV["HIVE_EXEC_DRIVER_OUTPUT"] = JSON.generate(
          "type" => "result",
          "subtype" => "success",
          "result" => "Research-looking output"
        )

        error = assert_raises(Hive::DependencyAdmissionError) do
          Hive::Commands::Run.new(folder).call
        end

        assert_equal "plan_dependency_invalid", error.reason_code
        refute File.exist?(File.join(folder, "worktree.yml")),
               "malformed plan frontmatter must fail admission before creating a worktree"
        refute File.exist?(File.join(folder, "task.md")),
               "malformed plan frontmatter must fail admission before initializing execute state"
      ensure
        worktree_yml = File.join(folder, "worktree.yml") if defined?(folder)
        wt_path = YAML.safe_load_file(worktree_yml)["path"] if worktree_yml && File.exist?(worktree_yml)
        FileUtils.rm_rf(wt_path) if wt_path
      end
    end
  end

  def test_dirty_worktree_pause_can_complete_after_cleanup_without_another_commit
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder, _slug = setup_execute_task(dir)
        ENV["HIVE_EXEC_DRIVER_TASK_DIR"] = folder
        ENV["HIVE_EXEC_DRIVER_DIRTY"] = "1"
        ENV["HIVE_EXEC_DRIVER_OUTPUT"] = "Committed but left dirty file."

        capture_io { Hive::Commands::Run.new(folder).call }

        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :execute_waiting, marker.name
        assert_equal "dirty_worktree", marker.attrs["reason"]

        ENV.delete("HIVE_EXEC_DRIVER_DIRTY")
        ENV["HIVE_EXEC_DRIVER_SKIP_COMMIT"] = "1"
        ENV["HIVE_EXEC_DRIVER_CLEAN_DIRTY"] = "1"
        ENV["HIVE_EXEC_DRIVER_OUTPUT"] = "Cleaned up dirty file."

        capture_io { Hive::Commands::Run.new(folder).call }

        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :execute_complete, marker.name
      ensure
        wt_path = YAML.safe_load(File.read(File.join(folder, "worktree.yml")))["path"] if defined?(folder)
        FileUtils.rm_rf(wt_path) if wt_path
      end
    end
  end

  def test_wrong_worktree_branch_pauses_instead_of_completing
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder, _slug = setup_execute_task(dir)
        ENV["HIVE_EXEC_DRIVER_TASK_DIR"] = folder
        ENV["HIVE_EXEC_DRIVER_WRONG_BRANCH"] = "1"

        capture_io { Hive::Commands::Run.new(folder).call }

        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :execute_waiting, marker.name
        assert_equal "branch_mismatch", marker.attrs["reason"]
      ensure
        wt_path = YAML.safe_load(File.read(File.join(folder, "worktree.yml")))["path"] if defined?(folder)
        FileUtils.rm_rf(wt_path) if wt_path
      end
    end
  end

  def test_re_run_after_complete_announces_next_step_open_pr
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder, _slug = setup_execute_task(dir)
        ENV["HIVE_EXEC_DRIVER_TASK_DIR"] = folder
        capture_io { Hive::Commands::Run.new(folder).call }
        # Re-run; runner should detect EXECUTE_COMPLETE and short-circuit.
        out, err = capture_io { Hive::Commands::Run.new(folder).call }
        assert_match(/already complete/, err)
        assert_match(/hive open-pr/, out)
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
        original_plan = File.binread(File.join(folder, "plan.md"))
        ENV["HIVE_EXEC_DRIVER_TASK_DIR"] = folder
        ENV["HIVE_EXEC_DRIVER_TAMPER"] = "1"

        _, _, status = with_captured_exit { Hive::Commands::Run.new(folder).call }
        assert_equal Hive::ExitCodes::TASK_IN_ERROR, status,
                     "marker :error must map to TASK_IN_ERROR (3)"

        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :error, marker.name
        assert_equal "implementer_tampered", marker.attrs["reason"]
        assert_equal "true", marker.attrs["restored"]
        assert_equal original_plan, File.binread(File.join(folder, "plan.md")),
                     "tampered plan.md must be restored before the retry is admitted"
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
