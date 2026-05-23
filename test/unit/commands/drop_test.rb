require "test_helper"
require "json"
require "open3"
require "hive/commands/drop"
require "hive/git_ops"
require "hive/worktree"

class DropCommandTest < Minitest::Test
  include HiveTestHelper

  def with_drop_project
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        ops = Hive::GitOps.new(dir)
        ops.hive_state_init
        Hive::Config.register_project(name: File.basename(dir), path: dir)
        # Drop validates pointer paths against the project's configured
        # worktree_root before removing a worktree. The fixture creates
        # worktrees under `<dirname>/<basename>.worktrees`, so config
        # has to match or the validation drops the cleanup silently.
        write_project_worktree_root(dir)
        yield(dir, ops, File.basename(dir))
      ensure
        if dir
          FileUtils.rm_rf(File.join(File.dirname(dir), "#{File.basename(dir)}.worktrees"))
        end
      end
    end
  end

  def write_project_worktree_root(dir)
    state_dir = File.join(dir, ".hive-state")
    FileUtils.mkdir_p(state_dir)
    File.write(
      File.join(state_dir, "config.yml"),
      { "worktree_root" => File.join(File.dirname(dir), "#{File.basename(dir)}.worktrees") }.to_yaml
    )
  end

  def create_task(dir, stage, slug, body: nil)
    folder = File.join(dir, ".hive-state", "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    state_name = Hive::Task::STATE_FILES.fetch(stage.split("-", 2).last)
    File.write(File.join(folder, state_name), body || "# #{slug}\n<!-- WAITING -->\n")
    folder
  end

  def commit_hive_state(ops, stage, slug, action = "seeded")
    ops.hive_commit(stage_name: stage, slug: slug, action: action)
  end

  def branch_exists?(dir, branch)
    _out, _err, status = Open3.capture3("git", "-C", dir, "show-ref", "--verify", "refs/heads/#{branch}")
    status.success?
  end

  def test_drop_removes_execute_task_worktree_branch_logs_and_agent
    with_drop_project do |dir, ops, project|
      slug = "drop-me-260522-aaaa"
      folder = create_task(dir, "4-execute", slug, body: "# task\n<!-- AGENT_WORKING pid=999999 -->\n")
      worktree_root = File.join(File.dirname(dir), "#{File.basename(dir)}.worktrees")
      wt = Hive::Worktree.new(dir, slug, worktree_root: worktree_root)
      wt.create!(slug, default_branch: "master")
      wt.write_pointer!(folder, slug)
      log_dir = File.join(dir, ".hive-state", "logs", slug)
      FileUtils.mkdir_p(log_dir)
      File.write(File.join(log_dir, "execute.log"), "running\n")
      commit_hive_state(ops, "4-execute", slug)

      pid = Process.spawn("sleep", "60", pgroup: true, out: File::NULL, err: File::NULL)
      begin
        File.write(File.join(folder, ".lock"), { "claude_pid" => pid }.to_yaml)

        out, _err = capture_io do
          Hive::Commands::Drop.new(slug, project: project, json: true).call
        end
        payload = JSON.parse(out)

        assert_equal "hive-drop", payload["schema"]
        assert_equal true, payload["ok"]
        assert_equal slug, payload["slug"]
        assert_equal [ "4-execute" ], payload["from_stages"]
        assert_equal true, payload["agent_killed"]
        assert_includes payload["agent_killed_pids"], pid
        assert_equal true, payload["worktree_removed"]
        assert_equal true, payload["branch_deleted"]
        refute File.directory?(folder)
        refute File.directory?(log_dir)
        refute File.directory?(wt.path)
        refute branch_exists?(dir, slug)
        log = `git -C #{File.join(dir, ".hive-state")} log --format=%s -1`.strip
        assert_equal "hive: dropped/#{slug} dropped", log
      ensure
        # Reap the helper sleep so a failed assertion doesn't leak a
        # 60s child until the test runner exits.
        reap_spawn(pid)
      end
    end
  end

  # Walk every active stage drop is supposed to clean up so a future
  # stage rename can't silently drop the per-stage assertion.
  Hive::Commands::Drop::ACTIVE_STAGE_DIRS.each do |stage|
    define_method("test_drop_removes_task_from_#{stage.tr('-', '_')}_stage") do
      with_drop_project do |dir, ops, project|
        slug = "stage-cov-260522-aaaa"
        folder = create_task(dir, stage, slug)
        commit_hive_state(ops, stage, slug)

        out, _err = capture_io do
          Hive::Commands::Drop.new(slug, project: project, json: true).call
        end
        payload = JSON.parse(out)

        assert_equal [ stage ], payload["from_stages"]
        refute File.directory?(folder), "task folder under #{stage} should be removed"
      end
    end
  end

  def test_drop_closes_pr_url_from_pr_md_best_effort
    with_drop_project do |dir, ops, project|
      slug = "drop-pr-260522-aaaa"
      folder = create_task(dir, "5-open-pr", slug, body: "---\npr_url: https://example.com/pr/1\n---\n\n<!-- COMPLETE -->\n")
      commit_hive_state(ops, "5-open-pr", slug)
      calls = []
      with_gh_capture_stub(lambda do |*cmd, **_kwargs|
        calls << cmd
        [ "", "", Hive::Gh::CommandStatus.new(exitstatus: 0) ]
      end) do
        out, _err = capture_io { Hive::Commands::Drop.new(slug, project: project, json: true).call }
        payload = JSON.parse(out)
        assert_equal true, payload["pr_closed"]
      end
      assert_equal [ [ "gh", "pr", "close", "https://example.com/pr/1", "--comment", "task dropped" ] ], calls
      refute File.directory?(folder)
    end
  end

  def test_drop_refuses_archived_task_without_side_effects
    with_drop_project do |dir, _ops, project|
      slug = "archived-260522-aaaa"
      folder = create_task(dir, "9-done", slug)

      out, _err, status = with_captured_exit do
        Hive::Commands::Drop.new(slug, project: project, json: true).call
      end
      payload = JSON.parse(out)
      assert_equal Hive::ExitCodes::USAGE, status
      assert_equal "already_archived", payload["error_kind"]
      assert File.directory?(folder)
    end
  end

  def test_drop_unknown_slug_emits_invalid_task_path
    with_drop_project do |_dir, _ops, project|
      out, _err, status = with_captured_exit do
        Hive::Commands::Drop.new("missing-260522-aaaa", project: project, json: true).call
      end
      payload = JSON.parse(out)
      assert_equal Hive::ExitCodes::USAGE, status
      assert_equal "invalid_task_path", payload["error_kind"]
    end
  end

  def test_drop_removes_same_project_multi_stage_leftovers
    with_drop_project do |dir, ops, project|
      slug = "multi-260522-aaaa"
      folder2 = create_task(dir, "2-brainstorm", slug)
      folder3 = create_task(dir, "3-plan", slug)
      commit_hive_state(ops, "2-brainstorm", slug)
      commit_hive_state(ops, "3-plan", slug)

      out, _err = capture_io do
        Hive::Commands::Drop.new(slug, project: project, json: true).call
      end
      payload = JSON.parse(out)
      assert_equal [ "2-brainstorm", "3-plan" ], payload["from_stages"]
      refute File.directory?(folder2)
      refute File.directory?(folder3)
    end
  end

  def test_drop_from_mismatch_emits_wrong_stage
    with_drop_project do |dir, _ops, project|
      slug = "wrong-stage-260522-aaaa"
      create_task(dir, "3-plan", slug)

      out, _err, status = with_captured_exit do
        Hive::Commands::Drop.new(slug, project: project, from: "2-brainstorm", json: true).call
      end
      payload = JSON.parse(out)
      assert_equal Hive::ExitCodes::WRONG_STAGE, status
      assert_equal "wrong_stage", payload["error_kind"]
      assert_equal "3-plan", payload["current_stage"]
      assert_equal "2-brainstorm", payload["target_stage"]
    end
  end

  def test_drop_pid_reuse_guard_refuses_to_signal_recorded_pid
    with_drop_project do |dir, _ops, project|
      slug = "pid-guard-260522-aaaa"
      folder = create_task(dir, "4-execute", slug)
      File.write(
        File.join(folder, ".lock"),
        { "pid" => Process.pid, "process_start_time" => "definitely-not-this-process" }.to_yaml
      )

      out, _err = capture_io do
        Hive::Commands::Drop.new(slug, project: project, json: true).call
      end
      payload = JSON.parse(out)
      assert_equal false, payload["agent_killed"]
      assert_equal Process.pid, payload["agent_pid"]
      assert_equal "pid_reuse_guard", payload["agent_kill_skipped_reason"]
    end
  end

  def test_drop_ambiguous_cross_project_slug_requires_project
    with_tmp_global_config do
      with_tmp_git_repo do |dir1|
        with_tmp_git_repo do |dir2|
          [ dir1, dir2 ].each do |dir|
            ops = Hive::GitOps.new(dir)
            ops.hive_state_init
            Hive::Config.register_project(name: File.basename(dir), path: dir)
            create_task(dir, "2-brainstorm", "shared-260522-aaaa")
          end

          out, _err, status = with_captured_exit do
            Hive::Commands::Drop.new("shared-260522-aaaa", json: true).call
          end
          payload = JSON.parse(out)
          assert_equal Hive::ExitCodes::USAGE, status
          assert_equal "ambiguous_slug", payload["error_kind"]
          assert_equal 2, payload["candidates"].size
        end
      end
    end
  end

  def with_gh_capture_stub(callable)
    original = Hive::Gh.method(:capture3)
    Hive::Gh.define_singleton_method(:capture3, callable)
    yield
  ensure
    Hive::Gh.define_singleton_method(:capture3, original) if original
  end

  # Best-effort kill + reap of a helper child PID. Used to clean up
  # spawned `sleep 60` fixtures so a failed assertion doesn't leak a
  # process until the test runner exits.
  def reap_spawn(pid)
    Process.kill("TERM", pid)
  rescue Errno::ESRCH, Errno::EPERM
    # already gone or out of reach
  ensure
    begin
      Process.waitpid(pid, Process::WNOHANG) || Process.waitpid(pid)
    rescue Errno::ECHILD
      # already reaped
    end
  end

  def test_drop_path_target_refuses_archived_task
    with_drop_project do |dir, _ops, _project|
      slug = "archived-path-260522-aaaa"
      folder = create_task(dir, "9-done", slug)

      out, _err, status = with_captured_exit do
        Hive::Commands::Drop.new(folder, json: true).call
      end
      payload = JSON.parse(out)
      assert_equal Hive::ExitCodes::USAGE, status
      assert_equal "already_archived", payload["error_kind"]
      assert File.directory?(folder), "archived folder must be left intact"
    end
  end

  # R12: a previous run died after deleting some artifacts. Re-running
  # drop must converge — already-missing pieces are treated as already
  # done, no envelope error.
  def test_drop_is_idempotent_after_partial_cleanup
    with_drop_project do |dir, ops, project|
      slug = "idemp-260522-aaaa"
      folder = create_task(dir, "4-execute", slug)
      worktree_root = File.join(File.dirname(dir), "#{File.basename(dir)}.worktrees")
      wt = Hive::Worktree.new(dir, slug, worktree_root: worktree_root)
      wt.create!(slug, default_branch: "master")
      wt.write_pointer!(folder, slug)
      log_dir = File.join(dir, ".hive-state", "logs", slug)
      FileUtils.mkdir_p(log_dir)
      commit_hive_state(ops, "4-execute", slug)

      # Simulate a crashed prior drop that already removed the worktree
      # and branch but left the task folder + logs behind.
      wt.remove_force!(path: wt.path)
      Hive::GitOps.new(dir).delete_branch!(slug)

      out, _err = capture_io do
        Hive::Commands::Drop.new(slug, project: project, json: true).call
      end
      payload = JSON.parse(out)

      assert_equal true, payload["ok"]
      assert_equal [ "4-execute" ], payload["from_stages"]
      # branch and worktree were already gone — drop reports the
      # already-clean state rather than raising.
      assert_equal false, payload["branch_deleted"]
      assert_equal false, payload["worktree_removed"]
      refute File.directory?(folder)
      refute File.directory?(log_dir)
    end
  end

  # Plan U1: when `gh` is not installed, drop must NOT raise — the
  # `gh pr close` step is best-effort. We trigger the rescue arm by
  # making `Hive::Gh.capture3` raise GhError directly.
  def test_drop_skips_pr_close_when_gh_binary_missing
    with_drop_project do |dir, ops, project|
      slug = "gh-missing-260522-aaaa"
      folder = create_task(
        dir, "5-open-pr", slug,
        body: "---\npr_url: https://example.com/pr/1\n---\n\n<!-- COMPLETE -->\n"
      )
      commit_hive_state(ops, "5-open-pr", slug)

      with_gh_capture_stub(lambda do |*_cmd, **_kwargs|
        raise Hive::GhError, "failed to run gh pr close: No such file or directory - gh"
      end) do
        out, err = capture_io do
          Hive::Commands::Drop.new(slug, project: project, json: true).call
        end
        payload = JSON.parse(out)
        assert_equal true, payload["ok"]
        assert_equal false, payload["pr_closed"]
        assert_includes err, "gh pr close skipped",
                        "stderr must warn that gh was skipped"
      end
      refute File.directory?(folder)
    end
  end

  # Plan U1: stray file in worktree dir makes `git worktree remove`
  # without --force fail; drop must retry with --force and succeed.
  def test_drop_worktree_force_fallback_succeeds_with_dirty_worktree
    with_drop_project do |dir, ops, project|
      slug = "force-wt-260522-aaaa"
      folder = create_task(dir, "4-execute", slug)
      worktree_root = File.join(File.dirname(dir), "#{File.basename(dir)}.worktrees")
      wt = Hive::Worktree.new(dir, slug, worktree_root: worktree_root)
      wt.create!(slug, default_branch: "master")
      wt.write_pointer!(folder, slug)
      File.write(File.join(wt.path, "stray-untracked.txt"), "dirty\n")
      commit_hive_state(ops, "4-execute", slug)

      out, _err = capture_io do
        Hive::Commands::Drop.new(slug, project: project, json: true).call
      end
      payload = JSON.parse(out)
      assert_equal true, payload["ok"]
      assert_equal true, payload["worktree_removed"]
      refute File.directory?(wt.path),
             "dirty worktree must be removed via the --force retry path"
    end
  end
end
