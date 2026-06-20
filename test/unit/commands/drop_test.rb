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

  def test_drop_without_a_pr_reports_pr_cleanup_as_clean
    with_drop_project do |dir, ops, project|
      slug = "no-pr-idea-260612-aaaa"
      create_task(dir, "1-inbox", slug, body: "# idea\n")
      commit_hive_state(ops, "1-inbox", slug)

      out, _err = capture_io { Hive::Commands::Drop.new(slug, project: project, json: true).call }
      payload = JSON.parse(out)
      assert_equal true, payload["pr_closed"],
                   "no PR recorded means PR cleanup is CLEAN - false is reserved for "                    "'a PR existed and could not be closed' so web notices stay honest"
    end
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
      assert_equal [ [ "gh", "pr", "close", "https://example.com/pr/1", "--comment", "task dropped (hive drop #{slug})" ] ], calls,
                   "gh pr close --comment must include the slug so reviewers can link back to the dropped task"
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

  def seed_generic_task(dir, ops, stage_dir, slug)
    folder = File.join(dir, ".hive-state", "stages", stage_dir, slug)
    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, "meta.yml"), { "slug" => slug, "workflow" => "research" }.to_yaml)
    File.write(File.join(folder, "notes.md"), "# #{slug}\n<!-- WAITING -->\n")
    commit_hive_state(ops, stage_dir, slug)
    folder
  end

  # U6.4: a generic-workflow task folder lives in a stage dir outside the
  # coding Hive::Stages::DIRS, so a slug-only `hive drop` that scans only the
  # coding dirs can't find it. Scanning Workflows.all_stage_dirs makes it
  # droppable by slug.
  def test_drop_finds_and_removes_generic_workflow_task_by_slug
    with_drop_project do |dir, ops, project|
      with_registered_workflow(research_workflow) do
        slug = "generic-drop-260620-aaaa"
        folder = seed_generic_task(dir, ops, "2-gather", slug)

        out, _err = capture_io do
          Hive::Commands::Drop.new(slug, project: project, json: true).call
        end
        payload = JSON.parse(out)
        assert_equal [ "2-gather" ], payload["from_stages"]
        refute File.directory?(folder), "generic task folder must be removed by `hive drop <slug>`"
      end
    end
  end

  # U6.4: a generic `--from <stage>` must resolve (the CLI accepts it), not be
  # rejected as an unknown stage by the coding-only Stages.resolve.
  def test_drop_accepts_generic_from_stage
    with_drop_project do |dir, ops, project|
      with_registered_workflow(research_workflow) do
        slug = "generic-from-260620-aaaa"
        folder = seed_generic_task(dir, ops, "2-gather", slug)

        out, _err = capture_io do
          Hive::Commands::Drop.new(slug, project: project, from: "2-gather", json: true).call
        end
        payload = JSON.parse(out)
        assert_equal [ "2-gather" ], payload["from_stages"]
        refute File.directory?(folder), "generic --from must resolve and drop the generic task folder"
      end
    end
  end

  def test_drop_pid_reuse_guard_refuses_to_signal_recorded_pid
    with_drop_project do |dir, _ops, project|
      slug = "pid-guard-260522-aaaa"
      folder = create_task(dir, "4-execute", slug)
      # Pin a live start-time lookup so the guard can compare against
      # the divergent recorded value. Without this stub the test could
      # silently degrade to "process_start_time returned blank" and
      # the guard would short-circuit to trust-the-pid, hiding a
      # regression in the start-time path.
      with_lock_start_time_stub("live-start-time-fixture") do
        File.write(
          File.join(folder, ".lock"),
          { "pid" => Process.pid,
            "process_start_time" => "definitely-not-this-process" }.to_yaml
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
  end

  # `<!-- AGENT_WORKING pid=N -->` marker without a `.lock` file is a
  # legitimate path (lock was removed by a crashed run, or the daemon
  # stamped a marker but the agent hadn't taken the lock yet). Drop
  # must still surface a kill candidate from the marker alone.
  def test_drop_picks_up_pid_from_marker_without_lock_file
    with_drop_project do |dir, _ops, project|
      slug = "marker-only-260522-aaaa"
      # Create an execute task with an AGENT_WORKING marker but NO .lock.
      folder = create_task(
        dir, "4-execute", slug,
        body: "# #{slug}\n<!-- AGENT_WORKING pid=999999 -->\n"
      )
      refute File.exist?(File.join(folder, ".lock")), "fixture must omit .lock"

      out, _err = capture_io do
        Hive::Commands::Drop.new(slug, project: project, json: true).call
      end
      payload = JSON.parse(out)
      # PID 999999 is essentially never alive; we expect a marker-only
      # candidate to be surfaced with skipped_reason: "not_alive"
      # rather than the no-candidate path's "no_pid".
      assert_equal 999_999, payload["agent_pid"],
                   "marker-only PID must surface as agent_pid"
      assert_equal false, payload["agent_killed"]
      assert_equal "not_alive", payload["agent_kill_skipped_reason"],
                   "marker-only PID should be picked up but skipped as not_alive"
    end
  end

  # `gh pr close` returning non-zero (e.g. PR already closed, network
  # error) must be a soft failure: drop continues, pr_closed:false,
  # exit 0, and a warning hits stderr so the operator sees the signal.
  def test_drop_handles_gh_pr_close_non_zero_exit_as_soft_failure
    with_drop_project do |dir, ops, project|
      slug = "gh-fail-260522-aaaa"
      folder = create_task(
        dir, "5-open-pr", slug,
        body: "---\npr_url: https://example.com/pr/9\n---\n\n<!-- COMPLETE -->\n"
      )
      commit_hive_state(ops, "5-open-pr", slug)

      with_gh_capture_stub(lambda do |*_cmd, **_kwargs|
        [ "", "PR is already closed\n", Hive::Gh::CommandStatus.new(exitstatus: 1) ]
      end) do
        out, err = capture_io do
          Hive::Commands::Drop.new(slug, project: project, json: true).call
        end
        payload = JSON.parse(out)
        assert_equal true, payload["ok"],
                     "non-zero gh pr close must NOT abort drop"
        assert_equal false, payload["pr_closed"]
        assert_includes err, "gh pr close",
                        "stderr must warn when gh pr close fails so silence is impossible"
      end
      refute File.directory?(folder)
    end
  end

  # Worktree pointer validation is a plan-stated security guard:
  # an out-of-root path in worktree.yml must be rejected (treated
  # as no-worktree) so a tampered pointer cannot trick drop into
  # removing a sibling worktree. Drop must converge to ok=true.
  def test_drop_rejects_out_of_root_worktree_pointer_path
    with_drop_project do |dir, ops, project|
      slug = "bad-pointer-260522-aaaa"
      folder = create_task(dir, "4-execute", slug)
      # Hand-write a pointer that escapes the worktree_root entirely.
      escape_path = File.join(Dir.tmpdir, "hive-escape-#{Process.pid}-#{rand(1_000_000)}")
      File.write(
        File.join(folder, "worktree.yml"),
        { "path" => escape_path, "branch" => slug, "created_at" => Time.now.utc.iso8601 }.to_yaml
      )
      commit_hive_state(ops, "4-execute", slug)

      out, err = capture_io do
        Hive::Commands::Drop.new(slug, project: project, json: true).call
      end
      payload = JSON.parse(out)
      assert_equal true, payload["ok"],
                   "out-of-root pointer must not abort drop — converge silently"
      assert_equal false, payload["worktree_removed"],
                   "tampered pointer must NOT be honoured; no worktree removed"
      assert_includes err, "rejecting out-of-root worktree pointer",
                      "stderr must warn about rejected pointer paths for security forensics"
      refute File.directory?(folder)
    end
  end

  # When the same slug exists in BOTH active and 9-done (race between
  # archive and the operator running drop), drop must silently focus
  # on the active stage and leave the 9-done copy alone. Inverting
  # this would accidentally remove the archive record.
  def test_drop_leaves_9_done_copy_intact_when_slug_spans_active_and_archive
    with_drop_project do |dir, ops, project|
      slug = "span-260522-aaaa"
      active_folder = create_task(dir, "2-brainstorm", slug)
      done_folder = create_task(dir, "9-done", slug)
      commit_hive_state(ops, "2-brainstorm", slug)
      commit_hive_state(ops, "9-done", slug)

      out, _err = capture_io do
        Hive::Commands::Drop.new(slug, project: project, json: true).call
      end
      payload = JSON.parse(out)
      assert_equal [ "2-brainstorm" ], payload["from_stages"],
                   "from_stages must reflect the active copy only — 9-done must not be touched"
      refute File.directory?(active_folder), "active copy must be removed"
      assert File.directory?(done_folder),
             "9-done archive copy must NOT be removed"
    end
  end

  # When a slug exists in TWO projects and --from doesn't match either
  # project's actual stage, the contract falls through to
  # InvalidTaskPath (cross-project --from-mismatch is not WrongStage
  # because the slug isn't pinned to a single project yet).
  def test_drop_cross_project_slug_with_wrong_from_yields_invalid_task_path
    with_tmp_global_config do
      with_tmp_git_repo do |dir1|
        with_tmp_git_repo do |dir2|
          [ dir1, dir2 ].each do |dir|
            ops = Hive::GitOps.new(dir)
            ops.hive_state_init
            Hive::Config.register_project(name: File.basename(dir), path: dir)
            create_task(dir, "2-brainstorm", "x-share-260522-aaaa")
          end

          out, _err, status = with_captured_exit do
            Hive::Commands::Drop.new(
              "x-share-260522-aaaa", from: "4-execute", json: true
            ).call
          end
          payload = JSON.parse(out)
          assert_equal Hive::ExitCodes::USAGE, status
          assert_equal "invalid_task_path", payload["error_kind"],
                       "cross-project slug with wrong --from must report invalid_task_path, not wrong_stage"
        end
      end
    end
  end

  # `record_drop_commit!` runs inside `Hive::Lock.with_commit_lock` so
  # commit-lock contention surfaces as a documented exit code 75
  # (TEMPFAIL). Pin this so a regression that removed or rewrapped the
  # lock would fail here instead of breaking the documented contract
  # silently.
  def test_drop_surfaces_commit_lock_contention_as_exit_75
    with_drop_project do |dir, _ops, project|
      slug = "lock-conflict-260522-aaaa"
      create_task(dir, "2-brainstorm", slug)

      with_commit_lock_stub_raising_concurrent_run do
        out, _err, status = with_captured_exit do
          Hive::Commands::Drop.new(slug, project: project, json: true).call
        end
        payload = JSON.parse(out)
        assert_equal Hive::ExitCodes::TEMPFAIL, status,
                     "commit-lock contention must exit 75 (TEMPFAIL) per docs/wiki"
        assert_equal false, payload["ok"]
      end
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

  # Pin Hive::Lock.process_start_time so tests of the PID-reuse guard
  # don't silently degrade to the "live empty" short-circuit when the
  # platform's start-time source is unavailable.
  def with_lock_start_time_stub(value)
    original = Hive::Lock.method(:process_start_time)
    Hive::Lock.define_singleton_method(:process_start_time) { |_pid| value }
    yield
  ensure
    Hive::Lock.define_singleton_method(:process_start_time, original) if original
  end

  # Force `Hive::Lock.with_commit_lock` to raise ConcurrentRunError so
  # we can pin drop's exit-code contract for lock contention.
  def with_commit_lock_stub_raising_concurrent_run
    original = Hive::Lock.method(:with_commit_lock)
    Hive::Lock.define_singleton_method(:with_commit_lock) do |path, &_block|
      raise Hive::ConcurrentRunError.new(
        "commit lock at #{path} held longer than fixture",
        lock_path: File.join(path, ".commit-lock")
      )
    end
    yield
  ensure
    Hive::Lock.define_singleton_method(:with_commit_lock, original) if original
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
  def test_drop_prints_human_success_without_json
    with_drop_project do |dir, ops, project|
      slug = "plain-drop-260525-aaaa"
      folder = create_task(dir, "3-plan", slug)
      commit_hive_state(ops, "3-plan", slug)

      out, _err = capture_io do
        Hive::Commands::Drop.new(slug, project: project).call
      end

      assert_includes out, "dropped #{slug} from #{project} (3-plan)"
      refute File.directory?(folder)
    end
  end

  def test_drop_ignores_corrupt_lock_payload_as_no_pid
    with_drop_project do |dir, ops, project|
      slug = "bad-lock-260525-aaaa"
      folder = create_task(dir, "4-execute", slug)
      File.write(File.join(folder, ".lock"), "pid: [unterminated\n")
      commit_hive_state(ops, "4-execute", slug)

      out, _err = capture_io do
        Hive::Commands::Drop.new(slug, project: project, json: true).call
      end
      payload = JSON.parse(out)

      assert_equal true, payload["ok"]
      assert_equal "no_pid", payload["agent_kill_skipped_reason"]
    end
  end

  def test_collect_stage_folders_collapses_concurrent_unlink
    with_drop_project do |dir, _ops, _project|
      slug = "gone-during-realpath-260525-aaaa"
      folder = create_task(dir, "3-plan", slug)
      original = File.method(:realpath)

      with_replaced_singleton_method(File, :realpath, lambda { |path, *args, **kwargs|
        raise Errno::ENOENT if path == folder

        original.call(path, *args, **kwargs)
      }) do
        drop = Hive::Commands::Drop.new(slug)
        assert_equal [], drop.send(:collect_stage_folders, File.join(dir, ".hive-state"), slug, [ "3-plan" ])
      end
    end
  end

  def test_marker_for_returns_none_for_malformed_task_folder
    state = Hive::Commands::Drop.new("bad-folder-260525-aaaa").send(:marker_for, "/tmp/not-a-hive-task")

    assert_equal :none, state.name
    assert_equal({}, state.attrs)
  end

  def test_remove_one_worktree_treats_already_removed_path_as_false
    drop = Hive::Commands::Drop.new("missing-wt-260525-aaaa")
    path = File.join(Dir.tmpdir, "hive-missing-worktree-#{Process.pid}")
    FileUtils.rm_rf(path)
    fake_wt = Object.new
    fake_wt.define_singleton_method(:remove!) { |path:| raise Hive::WorktreeError, "git worktree remove failed: #{path}" }
    fake_wt.define_singleton_method(:remove_force!) { |path:| raise Hive::WorktreeError, "force failed: #{path}" }

    refute drop.send(:remove_one_worktree, fake_wt, path, registered_paths: [ path ])
  end

  def test_remove_one_worktree_reraises_force_error_when_path_still_exists
    drop = Hive::Commands::Drop.new("dirty-wt-260525-aaaa")
    Dir.mktmpdir("hive-force-wt-") do |path|
      fake_wt = Object.new
      fake_wt.define_singleton_method(:remove!) { |path:| raise Hive::WorktreeError, "git worktree remove failed: #{path}" }
      fake_wt.define_singleton_method(:remove_force!) { |path:| raise Hive::WorktreeError, "force failed: #{path}" }

      err = assert_raises(Hive::WorktreeError) do
        drop.send(:remove_one_worktree, fake_wt, path, registered_paths: [ path ])
      end
      assert_match(/force failed/, err.message)
    end
  end

  def test_drop_error_kind_maps_typed_operational_errors
    drop = Hive::Commands::Drop.new("kind-260525-aaaa")

    assert_equal Hive::Schemas::DropErrorKind::CONFIG,
                 drop.send(:error_kind_for, Hive::ConfigError.new("bad config"))
    assert_equal Hive::Schemas::DropErrorKind::GIT,
                 drop.send(:error_kind_for, Hive::GitError.new("git failed"))
    assert_equal Hive::Schemas::DropErrorKind::WORKTREE,
                 drop.send(:error_kind_for, Hive::WorktreeError.new("worktree failed"))
    assert_equal Hive::Schemas::DropErrorKind::INTERNAL,
                 drop.send(:error_kind_for, Hive::InternalError.new("boom"))
  end
end
