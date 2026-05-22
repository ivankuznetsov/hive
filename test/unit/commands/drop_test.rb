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
        yield(dir, ops, File.basename(dir))
      ensure
        if dir
          FileUtils.rm_rf(File.join(File.dirname(dir), "#{File.basename(dir)}.worktrees"))
        end
      end
    end
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
end
