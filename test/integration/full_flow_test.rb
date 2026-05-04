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
    @prev_codex_bin = ENV["HIVE_CODEX_BIN"]
    @driver_dir = Dir.mktmpdir("flow-driver")
    @driver_log = File.join(@driver_dir, "driver.log")
    write_driver
    @gh_dir = Dir.mktmpdir("flow-gh")
    File.symlink(File.expand_path("../fixtures/fake-gh", __dir__),
                 File.join(@gh_dir, "gh"))
    ENV["PATH"] = "#{@gh_dir}:#{@prev_path}"
    ENV["HIVE_CLAUDE_BIN"] = File.join(@driver_dir, "claude")
    # ADR-023: rendered templates default execute.agent to codex, so the
    # full-pipeline run spawns the codex profile for 4-execute. Point
    # codex at the same fake driver so this end-to-end test still drives
    # one shared script.
    ENV["HIVE_CODEX_BIN"] = File.join(@driver_dir, "claude")
    ENV["HIVE_FLOW_DRIVER_LOG"] = @driver_log
  end

  def teardown
    ENV["PATH"] = @prev_path
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    ENV["HIVE_CODEX_BIN"] = @prev_codex_bin
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
          c = File.read(task_md).sub(/<!-- AGENT_WORKING.*-->/, "## Implementation\nstub work")
          File.write(task_md, c)
        end
      when "review"
        # Stage runner spawns no agents in this minimal review path
        # (zero reviewers + nil ci + browser disabled). Driver should
        # never reach this branch from a hive run; placed here only so
        # the case-statement is exhaustive.
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
      # Hive::Agent.check_version! probes `claude --version` before spawn;
      # short-circuit so the driver Ruby isn't invoked for a non-flow call.
      if [[ "${1:-}" == "--version" ]]; then
        echo "2.1.118 (Claude Code)"
        exit 0
      fi
      # Auto-detect implement vs review prompts via "ce-review" substring,
      # but only when phase is "execute-*". Otherwise honor whatever phase the
      # test set.
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

        # 3-plan → 4-execute (impl-only since U9; success → EXECUTE_COMPLETE)
        execute_dir = File.join(dir, ".hive-state", "stages", "4-execute", slug)
        FileUtils.mkdir_p(File.dirname(execute_dir))
        FileUtils.mv(plan_dir, execute_dir)
        ENV["HIVE_FLOW_FOLDER"] = execute_dir
        ENV["HIVE_FLOW_PHASE"] = "execute-implement"
        capture_io { Hive::Commands::Run.new(execute_dir).call }
        @spawned_worktrees << YAML.safe_load(File.read(File.join(execute_dir, "worktree.yml")))["path"]
        assert_equal :execute_complete, Hive::Markers.current(File.join(execute_dir, "task.md")).name

        # 4-execute → 5-review (autonomous loop). Configure a minimal
        # 5-review setup that exercises the runner's plumbing without
        # requiring real CI / reviewer / triage / browser infrastructure:
        #   - review.ci.command = nil → CI phase skipped
        #   - review.reviewers = []   → Phase 2 skipped (zero reviewers ≠ failure)
        #   - review.browser_test.enabled = false → Phase 5 skipped
        # Loop converges to REVIEW_COMPLETE browser=skipped on first pass.
        review_dir = File.join(dir, ".hive-state", "stages", "5-review", slug)
        FileUtils.mkdir_p(File.dirname(review_dir))
        FileUtils.mv(execute_dir, review_dir)

        cfg = YAML.safe_load(File.read(cfg_path))
        cfg["review"] ||= {}
        cfg["review"]["ci"] ||= {}
        cfg["review"]["ci"]["command"] = nil
        cfg["review"]["reviewers"] = []
        cfg["review"]["browser_test"] ||= {}
        cfg["review"]["browser_test"]["enabled"] = false
        File.write(cfg_path, cfg.to_yaml)

        ENV["HIVE_FLOW_FOLDER"] = review_dir
        ENV["HIVE_FLOW_PHASE"] = "review"
        capture_io { Hive::Commands::Run.new(review_dir).call }
        marker = Hive::Markers.current(File.join(review_dir, "task.md"))
        assert_equal :review_complete, marker.name
        assert_equal "skipped", marker.attrs["browser"]

        # 5-review → 6-pr
        pr_dir = File.join(dir, ".hive-state", "stages", "6-pr", slug)
        FileUtils.mkdir_p(File.dirname(pr_dir))
        FileUtils.mv(review_dir, pr_dir)

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

        # 6-pr → 7-done (no agent invoked)
        done_dir = File.join(dir, ".hive-state", "stages", "7-done", slug)
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
