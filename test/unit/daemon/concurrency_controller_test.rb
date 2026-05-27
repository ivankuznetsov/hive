require "test_helper"
require "tmpdir"
require "hive/daemon/concurrency_controller"
require "hive/daemon/dispatch_baselines"

# Pin the concurrency controller's caps + cooldown + quarantine + daily-
# rate semantics. Pure unit — no I/O, no Process.spawn. The controller
# is the daemon's load-bearing budget gate; misclassifying an exit code
# (e.g., consuming a daily slot on TEMPFAIL) breaks fairness across the
# whole pipeline.
class HiveDaemonConcurrencyControllerTest < Minitest::Test
  T0 = Time.utc(2026, 5, 6, 12, 0, 0)

  def make(global: 3, per_project: 1, daily: 50)
    Hive::Daemon::ConcurrencyController.new(
      max_concurrent_runs: global,
      max_concurrent_per_project: per_project,
      max_runs_per_day_per_project: daily
    )
  end

  def dispatch(c, pid, project, slug, mtime: T0 - 60, started_at: T0)
    c.record_dispatch(
      pid: pid, project: project, slug: slug,
      stage: "6-review", command: "hive run #{slug}",
      started_at: started_at, state_file_mtime: mtime
    )
  end

  # ── caps ──────────────────────────────────────────────────────────────

  def test_empty_controller_allows_dispatch
    assert_equal :ok, make.can_dispatch?(project: "p1", slug: "s1", now: T0)
  end

  def test_global_cap_blocks_third_dispatch_when_max_is_two
    c = make(global: 2, per_project: 5)
    dispatch(c, 100, "p1", "s1")
    dispatch(c, 101, "p2", "s2")
    assert_equal :global_cap, c.can_dispatch?(project: "p3", slug: "s3", now: T0)
  end

  def test_per_project_cap_blocks_within_global_room
    c = make(global: 5, per_project: 1)
    dispatch(c, 100, "p1", "s1")
    assert_equal :project_cap, c.can_dispatch?(project: "p1", slug: "s2", now: T0)
    # Another project still allowed
    assert_equal :ok, c.can_dispatch?(project: "p2", slug: "s1", now: T0)
  end

  def test_external_active_agents_count_toward_global_cap
    c = make(global: 1, per_project: 5)
    assert_equal :global_cap,
                 c.can_dispatch?(project: "p1", slug: "s1", now: T0,
                                  external_global_count: 1)
  end

  def test_external_active_agents_count_toward_project_cap
    c = make(global: 5, per_project: 1)
    assert_equal :project_cap,
                 c.can_dispatch?(project: "p1", slug: "s1", now: T0,
                                  external_global_count: 1,
                                  external_project_count: 1)
    assert_equal :ok,
                 c.can_dispatch?(project: "p2", slug: "s1", now: T0,
                                  external_global_count: 1,
                                  external_project_count: 0)
  end

  def test_external_running_counts_consume_global_and_project_capacity
    c = make(global: 2, per_project: 1)
    c.set_external_running_counts(per_project: { "p1" => 1, "p2" => 1 })

    assert_equal 2, c.in_flight_count
    assert_equal :global_cap, c.can_dispatch?(project: "p3", slug: "s3", now: T0)

    c.set_external_running_counts(per_project: { "p1" => 1 })
    assert_equal :project_cap, c.can_dispatch?(project: "p1", slug: "s2", now: T0)
    assert_equal :ok, c.can_dispatch?(project: "p2", slug: "s2", now: T0)
  end

  def test_daily_cap_blocks_after_n_dispatches
    c = make(daily: 2)
    dispatch(c, 100, "p1", "s1")
    c.record_completion(pid: 100, exit_code: Hive::ExitCodes::SUCCESS, completed_at: T0 + 1)
    dispatch(c, 101, "p1", "s2", started_at: T0 + 600)
    c.record_completion(pid: 101, exit_code: Hive::ExitCodes::SUCCESS, completed_at: T0 + 601)
    # Both completed; cooldown only blocks the same slug, not new ones
    # → daily cap is the gate now.
    result = c.can_dispatch?(project: "p1", slug: "s3", now: T0 + 1000)
    assert_equal :daily_cap, result
  end

  def test_daily_counter_rolls_at_midnight
    c = make(daily: 1)
    dispatch(c, 100, "p1", "s1", started_at: T0)
    c.record_completion(pid: 100, exit_code: Hive::ExitCodes::SUCCESS, completed_at: T0 + 1)
    # Same day — daily cap reached.
    assert_equal :daily_cap,
                 c.can_dispatch?(project: "p1", slug: "s2", now: T0 + 600)
    # Next day — cooldown for s1 may persist, but s2 is fresh.
    next_day = T0 + 86_400
    assert_equal :ok, c.can_dispatch?(project: "p1", slug: "s2", now: next_day)
  end

  # ── cooldown after SUCCESS ────────────────────────────────────────────

  def test_success_triggers_cooldown_for_same_slug
    c = make
    cd = Hive::Daemon::ConcurrencyController::SUCCESS_COOLDOWN_SEC
    dispatch(c, 100, "p1", "s1")
    c.record_completion(pid: 100, exit_code: Hive::ExitCodes::SUCCESS, completed_at: T0 + 5)
    # Mid-cooldown: still blocked.
    assert_equal :cooldown, c.can_dispatch?(project: "p1", slug: "s1", now: T0 + 5 + (cd / 2))
    # After cooldown elapses.
    assert_equal :ok, c.can_dispatch?(project: "p1", slug: "s1", now: T0 + 5 + cd + 1)
  end

  # ── transient retry → quarantine after schedule exhausted ──────────────

  def test_transient_failure_backs_off_then_quarantines
    c = make
    pid = 100
    Hive::Daemon::ConcurrencyController::TRANSIENT_BACKOFF_SCHEDULE.each_with_index do |backoff, idx|
      dispatch(c, pid + idx, "p1", "s1")
      c.record_completion(pid: pid + idx, exit_code: Hive::ExitCodes::SOFTWARE,
                          completed_at: T0 + idx)
      # During cooldown the slug is blocked.
      result = c.can_dispatch?(project: "p1", slug: "s1", now: T0 + idx + 1)
      assert_equal :cooldown, result, "after failure ##{idx + 1} must be in cooldown (#{backoff}s)"
    end

    # One more failure past the schedule's last entry → quarantine.
    next_pid = pid + Hive::Daemon::ConcurrencyController::TRANSIENT_BACKOFF_SCHEDULE.size
    dispatch(c, next_pid, "p1", "s1",
             started_at: T0 + Hive::Daemon::ConcurrencyController::TRANSIENT_BACKOFF_SCHEDULE.size + 1000)
    c.record_completion(pid: next_pid, exit_code: Hive::ExitCodes::SOFTWARE,
                        completed_at: T0 + 100_000)
    assert c.quarantined?(project: "p1", slug: "s1"),
           "exhausted backoff schedule must transition to :quarantined"
    assert_equal :quarantined,
                 c.can_dispatch?(project: "p1", slug: "s1", now: T0 + 1_000_000)
  end

  def test_success_after_transient_resets_failure_counter
    c = make
    dispatch(c, 100, "p1", "s1")
    c.record_completion(pid: 100, exit_code: Hive::ExitCodes::SOFTWARE, completed_at: T0 + 1)

    # Re-attempt later (simulate cooldown elapsed by passing future now)
    future = T0 + 10_000
    dispatch(c, 101, "p1", "s1", started_at: future)
    c.record_completion(pid: 101, exit_code: Hive::ExitCodes::SUCCESS, completed_at: future + 1)

    refute c.quarantined?(project: "p1", slug: "s1"),
           "SUCCESS after transient must clear the failure counter, not preserve it"
  end

  def test_wrong_stage_triggers_short_cooldown
    c = make
    dispatch(c, 100, "p1", "s1")

    c.record_completion(pid: 100, exit_code: Hive::ExitCodes::WRONG_STAGE, completed_at: T0 + 1)

    assert_equal :cooldown, c.can_dispatch?(project: "p1", slug: "s1", now: T0 + 2)
    assert_equal :ok, c.can_dispatch?(project: "p1", slug: "s1", now: T0 + 62)
  end

  # ── TEMPFAIL refunds daily slot ───────────────────────────────────────

  def test_tempfail_refunds_daily_slot
    c = make(daily: 1)
    dispatch(c, 100, "p1", "s1")
    assert_equal 1, c.daily_count_for("p1", T0)

    c.record_completion(pid: 100, exit_code: Hive::ExitCodes::TEMPFAIL, completed_at: T0 + 1)
    assert_equal 0, c.daily_count_for("p1", T0),
                 "TEMPFAIL means we didn't do work; refund the slot"
    # And the daily cap should not be reached:
    assert_equal :ok, c.can_dispatch?(project: "p1", slug: "s2", now: T0 + 100)
  end

  def test_tempfail_does_not_quarantine_or_cooldown
    c = make
    dispatch(c, 100, "p1", "s1")
    c.record_completion(pid: 100, exit_code: Hive::ExitCodes::TEMPFAIL, completed_at: T0 + 1)
    assert_equal :ok, c.can_dispatch?(project: "p1", slug: "s1", now: T0 + 2)
    refute c.quarantined?(project: "p1", slug: "s1")
  end

  # ── TASK_IN_ERROR clears running entry but doesn't quarantine ─────────

  def test_task_in_error_does_not_quarantine_in_controller
    # Marker handles the recovery via Policy upstream; controller just
    # cleans up the running entry.
    c = make
    dispatch(c, 100, "p1", "s1")
    c.record_completion(pid: 100, exit_code: Hive::ExitCodes::TASK_IN_ERROR, completed_at: T0 + 1)
    refute c.quarantined?(project: "p1", slug: "s1")
    assert_equal 0, c.in_flight_count
  end

  # ── USAGE quarantines ────────────────────────────────────────────────

  def test_usage_quarantines_for_daemon_lifetime
    c = make
    dispatch(c, 100, "p1", "s1")
    c.record_completion(pid: 100, exit_code: Hive::ExitCodes::USAGE, completed_at: T0 + 1)
    assert c.quarantined?(project: "p1", slug: "s1")
    assert_equal :quarantined, c.can_dispatch?(project: "p1", slug: "s1",
                                               now: T0 + 1_000_000)
  end

  # ── CONFIG drops the project ─────────────────────────────────────────

  def test_config_drops_entire_project
    c = make
    dispatch(c, 100, "p1", "s1")
    c.record_completion(pid: 100, exit_code: Hive::ExitCodes::CONFIG, completed_at: T0 + 1)
    assert c.project_dropped?("p1")
    # Every task in the dropped project is now blocked, regardless of slug.
    assert_equal :project_dropped,
                 c.can_dispatch?(project: "p1", slug: "totally-different-slug", now: T0 + 100)
    # Other projects unaffected.
    assert_equal :ok, c.can_dispatch?(project: "p2", slug: "s1", now: T0 + 100)
  end

  def test_record_project_dropped_direct_api
    c = make
    c.record_project_dropped(project: "p1")
    assert c.project_dropped?("p1")
  end

  def test_dropped_projects_returns_recorded_projects
    c = make
    c.record_project_dropped(project: "p1")
    c.record_project_dropped(project: "p2")

    assert_equal %w[p1 p2], c.dropped_projects.sort
  end

  # ── mtime tracking ────────────────────────────────────────────────────

  def test_record_dispatch_records_state_file_mtime
    c = make
    mtime = T0 - 120
    dispatch(c, 100, "p1", "s1", mtime: mtime)
    assert_equal mtime, c.last_dispatched_state_file_mtime_for(project: "p1", slug: "s1")
  end

  def test_last_dispatched_mtime_returns_nil_when_no_prior_dispatch
    c = make
    assert_nil c.last_dispatched_state_file_mtime_for(project: "p1", slug: "s1")
  end

  def test_dispatch_with_nil_mtime_does_not_overwrite_recorded_value
    # If a later dispatch can't read mtime (status row malformation),
    # don't blow away the previously-recorded value.
    c = make
    mtime = T0 - 120
    dispatch(c, 100, "p1", "s1", mtime: mtime)
    c.record_completion(pid: 100, exit_code: Hive::ExitCodes::SUCCESS, completed_at: T0 + 1)
    # Force a follow-on dispatch with nil mtime
    c.record_dispatch(
      pid: 101, project: "p1", slug: "s1", stage: "6-review",
      command: "hive run", started_at: T0 + 10_000, state_file_mtime: nil
    )
    # The prior recorded value should still be there.
    assert_equal mtime, c.last_dispatched_state_file_mtime_for(project: "p1", slug: "s1")
  end

  # PR-40 review P1 #1: post-completion mtime refresh + first-sight
  # baseline both flow through observe_state_file_mtime.
  def test_observe_state_file_mtime_updates_recorded_value_without_consuming_slot
    c = make
    initial = T0 - 600
    later = T0 - 60
    c.observe_state_file_mtime(project: "p1", slug: "s1", mtime: initial)
    assert_equal initial, c.last_dispatched_state_file_mtime_for(project: "p1", slug: "s1")
    # No daily slot consumed by observation (vs record_dispatch).
    assert_equal 0, c.daily_count_for("p1", T0)

    # Updating to a later mtime works.
    c.observe_state_file_mtime(project: "p1", slug: "s1", mtime: later)
    assert_equal later, c.last_dispatched_state_file_mtime_for(project: "p1", slug: "s1")
  end

  def test_observe_state_file_mtime_with_nil_is_a_no_op
    c = make
    initial = T0 - 600
    c.observe_state_file_mtime(project: "p1", slug: "s1", mtime: initial)
    c.observe_state_file_mtime(project: "p1", slug: "s1", mtime: nil)
    # Prior value preserved.
    assert_equal initial, c.last_dispatched_state_file_mtime_for(project: "p1", slug: "s1")
  end

  # ── in_flight bookkeeping ─────────────────────────────────────────────

  def test_running_count_for_includes_internal_and_external_project_counts
    c = make(global: 5, per_project: 5)
    dispatch(c, 100, "p1", "s1")
    dispatch(c, 101, "p2", "s1")
    c.set_external_running_counts(per_project: { "p1" => 2 })

    assert_equal 3, c.send(:running_count_for, "p1")
    assert_equal 1, c.send(:running_count_for, "p2")
  end

  def test_in_flight_count_tracks_running_entries
    c = make(global: 5, per_project: 5)
    assert_equal 0, c.in_flight_count
    dispatch(c, 100, "p1", "s1")
    dispatch(c, 101, "p1", "s2")
    assert_equal 2, c.in_flight_count

    c.record_completion(pid: 100, exit_code: Hive::ExitCodes::SUCCESS, completed_at: T0 + 1)
    assert_equal 1, c.in_flight_count
    refute_includes c.running_pids, 100
    assert_includes c.running_pids, 101
  end

  def test_running_task_detects_tracked_project_slug
    c = make(global: 5, per_project: 5)
    refute c.running_task?(project: "p1", slug: "s1")

    dispatch(c, 100, "p1", "s1")
    assert c.running_task?(project: "p1", slug: "s1")
    refute c.running_task?(project: "p1", slug: "s2")
    refute c.running_task?(project: "p2", slug: "s1")
  end

  def test_completion_for_unknown_pid_is_a_no_op
    c = make
    # Should not raise / corrupt state.
    c.record_completion(pid: 99_999, exit_code: Hive::ExitCodes::SUCCESS, completed_at: T0)
    assert_equal 0, c.in_flight_count
  end

  # ── integration-style 100-tick smoke test ─────────────────────────────

  def test_simulation_keeps_state_internally_consistent
    c = make(global: 3, per_project: 1, daily: 50)
    seed = 0
    100.times do |i|
      project = "p#{(i % 3) + 1}"
      slug = "task-#{(i % 5) + 1}"
      next unless c.can_dispatch?(project: project, slug: slug, now: T0 + i) == :ok

      pid = 1000 + seed
      dispatch(c, pid, project, slug, mtime: T0 - 60, started_at: T0 + i)
      # Mix of success / transient / tempfail
      code = case i % 4
      when 0 then Hive::ExitCodes::SUCCESS
      when 1 then Hive::ExitCodes::TEMPFAIL
      when 2 then Hive::ExitCodes::SOFTWARE
      else        Hive::ExitCodes::SUCCESS
      end
      c.record_completion(pid: pid, exit_code: code, completed_at: T0 + i + 1)
      seed += 1
    end

    # No leaked running entries.
    assert_equal 0, c.in_flight_count

    # Daily counts should never go negative (TEMPFAIL refund logic).
    %w[p1 p2 p3].each do |proj|
      count = c.daily_count_for(proj, T0)
      assert count >= 0, "#{proj} daily count went negative"
    end
  end

  # ── dispatch-baseline persistence (restart survival) ───────────────────

  def with_store
    Dir.mktmpdir do |dir|
      yield File.join(dir, "baselines.json")
    end
  end

  def controller_with(store)
    Hive::Daemon::ConcurrencyController.new(
      max_concurrent_runs: 3, max_concurrent_per_project: 1,
      max_runs_per_day_per_project: 50, dispatch_state: store
    )
  end

  def test_observe_baseline_survives_a_simulated_restart
    with_store do |path|
      answered = T0 - 30
      controller_with(Hive::Daemon::DispatchBaselines.new(path: path))
        .observe_state_file_mtime(project: "writero", slug: "add-x", mtime: answered)

      # Fresh controller (new process) seeded from the same store on disk.
      revived = controller_with(Hive::Daemon::DispatchBaselines.new(path: path))
      assert_equal answered,
                   revived.last_dispatched_state_file_mtime_for(project: "writero", slug: "add-x"),
                   "baseline must survive a restart so a pre-restart answer isn't re-stranded"
    end
  end

  def test_record_dispatch_baseline_survives_a_simulated_restart
    with_store do |path|
      c = controller_with(Hive::Daemon::DispatchBaselines.new(path: path))
      dispatch(c, 100, "xbookmark", "use-y", mtime: T0 - 90)

      revived = controller_with(Hive::Daemon::DispatchBaselines.new(path: path))
      assert_equal T0 - 90,
                   revived.last_dispatched_state_file_mtime_for(project: "xbookmark", slug: "use-y")
    end
  end

  def test_prune_drops_absent_keys_and_persists
    with_store do |path|
      c = controller_with(Hive::Daemon::DispatchBaselines.new(path: path))
      c.observe_state_file_mtime(project: "p", slug: "keep", mtime: T0)
      c.observe_state_file_mtime(project: "p", slug: "drop", mtime: T0)

      c.prune_dispatch_baselines([ %w[p keep] ])

      assert_equal T0, c.last_dispatched_state_file_mtime_for(project: "p", slug: "keep")
      assert_nil c.last_dispatched_state_file_mtime_for(project: "p", slug: "drop")
      # Prune persisted: a freshly-revived controller doesn't see the dropped key.
      revived = controller_with(Hive::Daemon::DispatchBaselines.new(path: path))
      assert_nil revived.last_dispatched_state_file_mtime_for(project: "p", slug: "drop")
    end
  end

  def test_nil_store_keeps_state_in_memory_and_writes_nothing
    Dir.mktmpdir do |dir|
      # Default `make` has no dispatch_state — pure in-memory, no file I/O.
      c = make
      c.observe_state_file_mtime(project: "p", slug: "s", mtime: T0)
      dispatch(c, 1, "p", "s2", mtime: T0)
      c.prune_dispatch_baselines([ %w[p s] ])

      assert_equal T0, c.last_dispatched_state_file_mtime_for(project: "p", slug: "s")
      assert_empty Dir.glob(File.join(dir, "*")), "nil store must not write any file"
    end
  end

  def test_persistence_error_does_not_crash_dispatch
    raising_store = Object.new
    def raising_store.load = {}
    def raising_store.write(_map) = raise(IOError, "simulated disk failure")
    c = controller_with(raising_store)

    # A store that raises must not propagate out of a controller mutation.
    c.observe_state_file_mtime(project: "p", slug: "s", mtime: T0)
    dispatch(c, 1, "p", "s2", mtime: T0)

    assert_equal T0, c.last_dispatched_state_file_mtime_for(project: "p", slug: "s")
  end
end
