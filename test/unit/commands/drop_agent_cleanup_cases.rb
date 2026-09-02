class DropCommandTest < Minitest::Test
  def test_drop_kill_failed_preserves_task_identity_and_every_destructive_resource
    with_drop_project do |dir, ops, project|
      slug = "kill-failed-preserves-260902-abcd"
      runner_pid = 81_101
      runner_start = "recorded-runner-start"
      body = <<~MARKDOWN
        ---
        pr_url: https://example.com/pull/81101
        ---

        # #{slug}
        <!-- AGENT_WORKING pid=#{runner_pid} -->
      MARKDOWN
      folder = create_task(dir, "5-open-pr", slug, body: body)
      pr_path = File.join(folder, "pr.md")
      pr_before = File.read(pr_path)

      worktree_root = File.join(File.dirname(dir), "#{File.basename(dir)}.worktrees")
      worktree = Hive::Worktree.new(dir, slug, worktree_root: worktree_root)
      worktree.create!(slug, default_branch: "master")
      worktree.write_pointer!(folder, slug)

      log_dir = File.join(dir, ".hive-state", "logs", slug)
      FileUtils.mkdir_p(log_dir)
      log_path = File.join(log_dir, "execute.log")
      File.write(log_path, "recorded output\n")
      commit_hive_state(ops, "5-open-pr", slug)
      before_head = run!("git", "-C", File.join(dir, ".hive-state"), "rev-parse", "HEAD").strip

      publish_test_task_lease(
        folder, "pid" => runner_pid, "process_start_time" => runner_start
      )
      lease_before = Hive::Lock.read_task_lock(folder)
      marker_before = Hive::Markers.current(pr_path)

      lease_calls = []
      cleanup_calls = []
      commit_calls = []
      pr_close_calls = []
      kill_calls = []
      drop = Hive::Commands::Drop.new(slug, project: project, json: true)
      drop.define_singleton_method(:with_task_leases) do |folders, &block|
        lease_calls << folders
        block.call
      end
      drop.define_singleton_method(:cleanup_context) do |context, killed:|
        cleanup_calls << [ context, killed ]
        {
          agent: killed, pr_closed: false, worktree_removed: false,
          branch_deleted: false
        }
      end
      drop.define_singleton_method(:record_drop_commit!) do |context|
        commit_calls << context
        "committed"
      end

      failed = Hive::ProcessKill::Result.new(
        pid: runner_pid, killed: false, skipped_reason: "kill_failed"
      )
      with_replaced_singleton_method(
        Hive::ProcessKill, :terminate_process,
        lambda do |pid, recorded_start_time: nil, **_kwargs|
          kill_calls << [ pid, recorded_start_time ]
          failed
        end
      ) do
        with_gh_capture_stub(lambda do |*command, **_kwargs|
          pr_close_calls << command
          raise "PR cleanup must not run after kill_failed"
        end) do
          out, _err, status = with_captured_exit { drop.call }
          payload = JSON.parse(out)

          assert_equal Hive::ExitCodes::TEMPFAIL, status
          assert_equal "hive-drop", payload.fetch("schema")
          assert_equal 2, payload.fetch("schema_version")
          assert_equal false, payload.fetch("ok")
          assert_includes payload.fetch("message"), "kill_failed"
        end
      end

      assert_equal [ [ runner_pid, runner_start ] ], kill_calls
      assert_empty lease_calls, "kill_failed must abort before acquiring task leases"
      assert_empty cleanup_calls, "kill_failed must abort before cleanup_context"
      assert_empty commit_calls, "kill_failed must not write the drop audit commit"
      assert_empty pr_close_calls, "kill_failed must not close a recorded PR"
      assert File.directory?(folder), "task folder must remain available for retry"
      assert_equal pr_before, File.read(pr_path), "recorded PR/marker state must remain byte-identical"
      assert File.directory?(worktree.path), "worktree must remain available for remediation"
      assert branch_exists?(dir, slug), "branch must not be deleted"
      assert File.directory?(log_dir), "task logs must remain available"
      assert_equal "recorded output\n", File.read(log_path)
      assert_equal before_head,
                   run!("git", "-C", File.join(dir, ".hive-state"), "rev-parse", "HEAD").strip

      lease_after = Hive::Lock.read_task_lock(folder)
      assert_equal lease_before.fetch("lock_id"), lease_after.fetch("lock_id")
      assert_equal runner_pid, lease_after.fetch("pid")
      assert_equal runner_start, lease_after.fetch("process_start_time")
      marker_after = Hive::Markers.current(pr_path)
      assert_equal marker_before.raw, marker_after.raw
      assert_equal runner_pid.to_s, marker_after.attrs.fetch("pid")
    end
  end

  def test_drop_mixed_candidates_blocks_cleanup_when_later_result_is_kill_failed
    with_drop_project do |dir, _ops, project|
      slug = "mixed-kill-failed-260902-abcd"
      folder = create_task(dir, "4-execute", slug)
      candidates = [
        { pid: 81_201, process_start_time: "group", group: true },
        { pid: 81_202, process_start_time: "replacement", group: false },
        { pid: 81_203, process_start_time: "unresolved", group: false }
      ]
      results = {
        81_201 => Hive::ProcessKill::Result.new(pid: 81_201, killed: true, skipped_reason: nil),
        81_202 => Hive::ProcessKill::Result.new(
          pid: 81_202, killed: false, skipped_reason: "pid_reuse_guard"
        ),
        81_203 => Hive::ProcessKill::Result.new(
          pid: 81_203, killed: false, skipped_reason: "kill_failed"
        )
      }
      calls = []
      cleanup_calls = []
      lease_calls = []
      commit_calls = []
      drop = Hive::Commands::Drop.new(slug, project: project, json: true)
      drop.define_singleton_method(:process_candidates) { |_folders| candidates }
      drop.define_singleton_method(:with_task_leases) do |folders, &block|
        lease_calls << folders
        block.call
      end
      drop.define_singleton_method(:cleanup_context) do |context, killed:|
        cleanup_calls << [ context, killed ]
        {
          agent: killed, pr_closed: true, worktree_removed: false,
          branch_deleted: false
        }
      end
      drop.define_singleton_method(:record_drop_commit!) do |context|
        commit_calls << context
        "committed"
      end

      terminate_group = lambda do |pid, recorded_start_time: nil, **_kwargs|
        calls << [ :group, pid, recorded_start_time ]
        results.fetch(pid)
      end
      terminate_single = lambda do |pid, recorded_start_time: nil, **_kwargs|
        calls << [ :single, pid, recorded_start_time ]
        results.fetch(pid)
      end
      with_replaced_singleton_method(Hive::ProcessKill, :terminate_process_group, terminate_group) do
        with_replaced_singleton_method(Hive::ProcessKill, :terminate_process, terminate_single) do
          out, _err, status = with_captured_exit { drop.call }
          payload = JSON.parse(out)

          assert_equal Hive::ExitCodes::TEMPFAIL, status
          assert_equal false, payload.fetch("ok")
          assert_includes payload.fetch("message"), "kill_failed"
        end
      end

      assert_equal [
        [ :group, 81_201, "group" ],
        [ :single, 81_202, "replacement" ],
        [ :single, 81_203, "unresolved" ]
      ], calls
      assert_empty lease_calls
      assert_empty cleanup_calls,
                   "a successful candidate and an earlier non-gating reason must not hide kill_failed"
      assert_empty commit_calls
      assert File.directory?(folder)
    end
  end

  def test_drop_retains_distinct_recorded_identities_for_reused_pid
    with_drop_project do |dir, _ops, project|
      slug = "reused-pid-identities-260902-abcd"
      stale_folder = create_task(dir, "3-plan", slug)
      live_folder = create_task(dir, "4-execute", slug)
      reused_pid = 81_204
      locks = {
        stale_folder => { "pid" => reused_pid, "process_start_time" => "stale-start" },
        live_folder => { "pid" => reused_pid, "process_start_time" => "live-start" }
      }
      calls = []
      terminate = lambda do |pid, recorded_start_time: nil, **_kwargs|
        calls << [ pid, recorded_start_time ]
        reason = recorded_start_time == "live-start" ? "kill_failed" : "pid_reuse_guard"
        Hive::ProcessKill::Result.new(pid: pid, killed: false, skipped_reason: reason)
      end

      with_replaced_singleton_method(Hive::Lock, :read_task_lock, ->(folder) { locks.fetch(folder) }) do
        with_replaced_singleton_method(Hive::ProcessKill, :terminate_process, terminate) do
          cleanup = Hive::Commands::Drop.new(slug, project: project, json: true).send(
            :kill_recorded_agents,
            [ { folder: stale_folder }, { folder: live_folder } ]
          )

          assert cleanup.fetch(:kill_failed),
                 "the live identity's kill_failed result must survive a stale record for the reused PID"
          assert_equal "pid_reuse_guard", cleanup.fetch(:skipped_reason)
        end
      end

      assert_equal [ [ reused_pid, "stale-start" ], [ reused_pid, "live-start" ] ], calls
    end
  end

  def test_drop_keeps_replacement_cleanup_in_v2_success_pid_list
    with_drop_project do |dir, _ops, project|
      slug = "replacement-success-260902-abcd"
      folder = create_task(dir, "4-execute", slug)
      recorded_pid = 81_301
      replacement_success = Hive::ProcessKill::Result.new(
        pid: recorded_pid, killed: true, skipped_reason: nil
      )

      with_task_lease_payload(
        "pid" => recorded_pid, "process_start_time" => "recorded-start"
      ) do
        with_replaced_singleton_method(
          Hive::ProcessKill, :terminate_process, ->(*) { replacement_success }
        ) do
          out, _err = capture_io do
            Hive::Commands::Drop.new(slug, project: project, json: true).call
          end
          payload = JSON.parse(out)

          assert_equal 2, payload.fetch("schema_version")
          assert_equal true, payload.fetch("agent_killed")
          assert_equal [ recorded_pid ], payload.fetch("agent_killed_pids")
          assert_nil payload.fetch("agent_kill_skipped_reason")
        end
      end

      refute File.directory?(folder), "successful recorded-identity cleanup must preserve Drop behavior"
    end
  end

end
