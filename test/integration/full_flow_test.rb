require "test_helper"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/run"
require "hive/commands/status"

class FullFlowTest < Minitest::Test
  include HiveTestHelper

  def setup
    @prev_path = ENV["PATH"]
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    @driver_dir = Dir.mktmpdir("flow-driver")
    @driver_log = File.join(@driver_dir, "driver.log")
    write_driver
    @gh_dir = Dir.mktmpdir("flow-gh")
    File.symlink(File.expand_path("../fixtures/fake-gh", __dir__),
                 File.join(@gh_dir, "gh"))
    ENV["PATH"] = "#{@gh_dir}:#{@prev_path}"
    ENV["HIVE_CLAUDE_BIN"] = File.join(@driver_dir, "claude")
    ENV["HIVE_FLOW_DRIVER_LOG"] = @driver_log
  end

  def teardown
    ENV["PATH"] = @prev_path
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    FileUtils.rm_rf(@driver_dir) if @driver_dir
    FileUtils.rm_rf(@gh_dir) if @gh_dir
    %w[HIVE_FLOW_FOLDER HIVE_FLOW_PHASE HIVE_FLOW_FINDINGS HIVE_FLOW_PASS
       HIVE_FLOW_DRIVER_LOG HIVE_FAKE_GH_PR_EXISTS].each { |k| ENV.delete(k) }
    Array(@spawned_worktrees).each { |p| FileUtils.rm_rf(p) }
  end

  def write_driver
    script = File.join(@driver_dir, "driver.rb")
    File.write(script, <<~'RUBY')
      #!/usr/bin/env ruby
      require "fileutils"
      require "yaml"

      log = ENV["HIVE_FLOW_DRIVER_LOG"]
      File.open(log, "a") { |f| f.puts ARGV.inspect } if log

      folder = ENV["HIVE_FLOW_FOLDER"] or abort "HIVE_FLOW_FOLDER unset"
      phase = ENV["HIVE_FLOW_PHASE"] or abort "HIVE_FLOW_PHASE unset"
      pass = (ENV["HIVE_FLOW_PASS"] || "1").to_i
      findings = (ENV["HIVE_FLOW_FINDINGS"] || "0").to_i

      case phase
      when "brainstorm-round1"
        File.write(File.join(folder, "brainstorm.md"),
          "## Round 1\n### Q1. Scope?\n### A1.\n\n<!-- WAITING -->\n")
      when "brainstorm-complete"
        File.write(File.join(folder, "brainstorm.md"),
          "## Round 1\n### Q1.\n### A1. yes\n\n## Requirements\n- foo\n\n<!-- COMPLETE -->\n")
      when "plan-complete"
        File.write(File.join(folder, "plan.md"),
          "## Overview\nstub\n## Implementation Units\n- U1: foo\n<!-- COMPLETE -->\n")
      when "execute-implement"
        task_md = File.join(folder, "task.md")
        if File.exist?(task_md)
          c = File.read(task_md).sub(/<!-- AGENT_WORKING.*-->/, "## Implementation\nstub work pass #{pass}")
          File.write(task_md, c)
        end
      when "execute-review"
        rd = File.join(folder, "reviews"); FileUtils.mkdir_p(rd)
        rf = File.join(rd, "ce-review-%02d.md" % pass)
        body = +"## High\n"
        findings.times { |i| body << "- [ ] f-#{i+1}: stub\n" }
        File.write(rf, body)
      when "pr"
        File.write(File.join(folder, "pr.md"), <<~MD)
          ---
          pr_url: https://example.com/pr/42
          ---

          ## Summary
          stub

          <!-- COMPLETE pr_url=https://example.com/pr/42 -->
        MD
      else
        abort "unknown phase #{phase}"
      end
      exit 0
    RUBY

    bin = File.join(@driver_dir, "claude")
    File.write(bin, <<~SH)
      #!/usr/bin/env bash
      # Auto-detect implement vs review prompts via "ce-review" substring,
      # but only when phase is "execute-*". Otherwise honor whatever phase the
      # test set.
      original_phase="${HIVE_FLOW_PHASE:-}"
      if [[ "$original_phase" == "execute-mixed" ]]; then
        if printf '%s' "$*" | grep -q 'ce-review'; then
          export HIVE_FLOW_PHASE=execute-review
        else
          export HIVE_FLOW_PHASE=execute-implement
        fi
      fi
      exec ruby "#{script}" "$@"
    SH
    File.chmod(0o755, bin)
  end

  def test_full_idea_to_pr_to_done_flow
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        @spawned_worktrees = []
        capture_io { Hive::Commands::Init.new(dir).call }
        # Override worktree_root so tests don't pollute ~/Dev.
        cfg_path = File.join(dir, ".hive-state", "config.yml")
        cfg = YAML.safe_load(File.read(cfg_path))
        worktree_root = Dir.mktmpdir("flow-wt-root-")
        @spawned_worktrees << worktree_root
        cfg["worktree_root"] = worktree_root
        File.write(cfg_path, cfg.to_yaml)
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "fix readme whitespace").call }

        inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
        slug = File.basename(inbox)

        # 1-inbox → 2-brainstorm
        brainstorm_dir = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm_dir))
        FileUtils.mv(inbox, brainstorm_dir)

        ENV["HIVE_FLOW_FOLDER"] = brainstorm_dir
        ENV["HIVE_FLOW_PHASE"] = "brainstorm-round1"
        capture_io { Hive::Commands::Run.new(brainstorm_dir).call }
        assert_equal :waiting, Hive::Markers.current(File.join(brainstorm_dir, "brainstorm.md")).name

        ENV["HIVE_FLOW_PHASE"] = "brainstorm-complete"
        capture_io { Hive::Commands::Run.new(brainstorm_dir).call }
        assert_equal :complete, Hive::Markers.current(File.join(brainstorm_dir, "brainstorm.md")).name

        # 2-brainstorm → 3-plan
        plan_dir = File.join(dir, ".hive-state", "stages", "3-plan", slug)
        FileUtils.mkdir_p(File.dirname(plan_dir))
        FileUtils.mv(brainstorm_dir, plan_dir)
        ENV["HIVE_FLOW_FOLDER"] = plan_dir
        ENV["HIVE_FLOW_PHASE"] = "plan-complete"
        capture_io { Hive::Commands::Run.new(plan_dir).call }
        assert_equal :complete, Hive::Markers.current(File.join(plan_dir, "plan.md")).name

        # 3-plan → 4-execute (init pass with 1 finding)
        execute_dir = File.join(dir, ".hive-state", "stages", "4-execute", slug)
        FileUtils.mkdir_p(File.dirname(execute_dir))
        FileUtils.mv(plan_dir, execute_dir)
        ENV["HIVE_FLOW_FOLDER"] = execute_dir
        ENV["HIVE_FLOW_PHASE"] = "execute-mixed"
        ENV["HIVE_FLOW_PASS"] = "1"
        ENV["HIVE_FLOW_FINDINGS"] = "1"
        capture_io { Hive::Commands::Run.new(execute_dir).call }
        @spawned_worktrees << YAML.safe_load(File.read(File.join(execute_dir, "worktree.yml")))["path"]
        assert_equal :execute_waiting, Hive::Markers.current(File.join(execute_dir, "task.md")).name

        # User accepts the finding (tick [x]).
        review_file = File.join(execute_dir, "reviews", "ce-review-01.md")
        body = File.read(review_file).sub("- [ ] f-1", "- [x] f-1")
        File.write(review_file, body)

        # Iteration pass with 0 findings → execute_complete.
        ENV["HIVE_FLOW_PASS"] = "2"
        ENV["HIVE_FLOW_FINDINGS"] = "0"
        capture_io { Hive::Commands::Run.new(execute_dir).call }
        assert_equal :execute_complete, Hive::Markers.current(File.join(execute_dir, "task.md")).name

        # 4-execute → 5-pr
        pr_dir = File.join(dir, ".hive-state", "stages", "5-pr", slug)
        FileUtils.mkdir_p(File.dirname(pr_dir))
        FileUtils.mv(execute_dir, pr_dir)

        # PR stage will git push to origin; create a bare remote in the worktree.
        worktree_path = YAML.safe_load(File.read(File.join(pr_dir, "worktree.yml")))["path"]
        bare = "#{worktree_path}-remote.git"
        @spawned_worktrees << bare
        run!("git", "init", "--bare", bare, "--quiet")
        run!("git", "-C", worktree_path, "remote", "add", "origin", bare)

        ENV["HIVE_FLOW_FOLDER"] = pr_dir
        ENV["HIVE_FLOW_PHASE"] = "pr"
        capture_io { Hive::Commands::Run.new(pr_dir).call }
        assert_equal :complete, Hive::Markers.current(File.join(pr_dir, "pr.md")).name

        # 5-pr → 6-done (no agent invoked)
        done_dir = File.join(dir, ".hive-state", "stages", "6-done", slug)
        FileUtils.mkdir_p(File.dirname(done_dir))
        FileUtils.mv(pr_dir, done_dir)
        out, _err = capture_io { Hive::Commands::Run.new(done_dir).call }
        assert_includes out, "git worktree remove"
        assert_equal :complete, Hive::Markers.current(File.join(done_dir, "task.md")).name

        # All hive-state commits land on hive/state, not master.
        master_log = `git -C #{dir} log --format=%s master`.strip.split("\n")
        hive_msgs = master_log.select { |m| m.start_with?("hive:") }
        assert_empty hive_msgs, "master must contain no hive: commits"
        hive_state_log = `git -C #{File.join(dir, ".hive-state")} log --format=%s`.strip.split("\n")
        assert(hive_state_log.any? { |m| m.start_with?("hive: 4-execute/") },
               "hive/state log should record execute-stage commits")
      end
    end
  end
end
