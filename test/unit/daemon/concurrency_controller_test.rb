require "test_helper"
require "tmpdir"
require "hive/daemon/concurrency_controller"
require "hive/daemon/dispatch_baselines"

# Pin the concurrency controller's caps + backoff + quarantine + daily-
# rate semantics. Pure unit — no I/O, no Process.spawn. The controller
# is the daemon's load-bearing budget gate; misclassifying an exit code
# (e.g., consuming a daily slot on TEMPFAIL) breaks fairness across the
# whole pipeline.
class HiveDaemonConcurrencyControllerTest < Minitest::Test
  T0 = Time.utc(2026, 5, 6, 12, 0, 0)

  def make(global: 3, per_project: 1, daily: 50, patrol_scans: 1)
    Hive::Daemon::ConcurrencyController.new(
      max_concurrent_runs: global,
      max_concurrent_per_project: per_project,
      max_runs_per_day_per_project: daily,
      max_concurrent_patrol_scans: patrol_scans
    )
  end

  def dispatch(c, pid, project, slug, mtime: T0 - 60, started_at: T0, kind: :task)
    c.record_dispatch(
      pid: pid, project: project, slug: slug,
      stage: "6-review", command: "hive run #{slug}",
      started_at: started_at, state_file_mtime: mtime, kind: kind
    )
  end

  # ── patrol-scan separate budget ────────────────────────────────────────

  def test_patrol_scan_does_not_count_against_task_global_cap
    c = make(global: 2, per_project: 5)
    dispatch(c, 100, "hive", "patrol-scan", kind: :patrol_scan)
    # Scan is running, but task slots are untouched: two tasks still fit.
    assert_equal :ok, c.can_dispatch?(project: "p1", slug: "s1", now: T0)
    dispatch(c, 101, "p1", "s1")
    assert_equal :ok, c.can_dispatch?(project: "p2", slug: "s2", now: T0)
    dispatch(c, 102, "p2", "s2")
    # Now both TASK slots are full (scan excluded) → global_cap.
    assert_equal :global_cap, c.can_dispatch?(project: "p3", slug: "s3", now: T0)
  end

  def test_patrol_scan_excluded_from_per_project_cap
    c = make(global: 5, per_project: 1)
    dispatch(c, 100, "hive", "patrol-scan", kind: :patrol_scan)
    # A scan for project "hive" does not consume hive's per-project task slot.
    assert_equal :ok, c.can_dispatch?(project: "hive", slug: "s1", now: T0)
  end

  def test_can_dispatch_patrol_scan_respects_its_own_budget
    c = make(patrol_scans: 1)
    assert_equal :ok, c.can_dispatch_patrol_scan?(project: "hive", now: T0)
    dispatch(c, 100, "hive", "patrol-scan", kind: :patrol_scan)
    assert_equal :patrol_scan_cap, c.can_dispatch_patrol_scan?(project: "hive", now: T0)
  end

  # max_concurrent_patrol_scans is a PER-PROJECT cap: a running scan for one
  # project must NOT block a scan for a DIFFERENT project, so projects patrol
  # in parallel rather than being serialized/starved by a global count.
  def test_patrol_scan_cap_is_per_project
    c = make(patrol_scans: 1)
    dispatch(c, 100, "p1", "patrol-scan", kind: :patrol_scan)

    # A different project is still allowed despite p1's running scan.
    assert_equal :ok, c.can_dispatch_patrol_scan?(project: "p2", now: T0),
                 "different projects must patrol in parallel"

    # A SECOND scan for the SAME project hits the per-project cap.
    assert_equal :patrol_scan_cap, c.can_dispatch_patrol_scan?(project: "p1", now: T0),
                 "second scan for the same project must hit the per-project cap"

    # Once p2's scan is also running, p2 likewise hits its own per-project cap.
    dispatch(c, 101, "p2", "patrol-scan", kind: :patrol_scan)
    assert_equal :patrol_scan_cap, c.can_dispatch_patrol_scan?(project: "p2", now: T0)
  end

  # nil is NOT a wildcard for patrol scans (unlike can_dispatch?'s
  # project-nil="count everything" semantics): a project-less scan must not
  # count against a named project's cap, and vice versa.
  def test_patrol_scan_nil_project_is_not_a_wildcard
    c = make(patrol_scans: 1)
    dispatch(c, 100, nil, "patrol-scan", kind: :patrol_scan)
    assert_equal :ok, c.can_dispatch_patrol_scan?(project: "p1", now: T0),
                 "a nil-project scan must not cap a named project"

    c2 = make(patrol_scans: 1)
    dispatch(c2, 200, "p1", "patrol-scan", kind: :patrol_scan)
    assert_equal :ok, c2.can_dispatch_patrol_scan?(project: nil, now: T0),
                 "a named scan must not cap a nil-project query"
  end

  def test_running_tasks_do_not_block_a_patrol_scan
    c = make(global: 2, patrol_scans: 1)
    dispatch(c, 100, "p1", "s1")
    dispatch(c, 101, "p2", "s2") # task global cap full
    # Task cap is full, but a scan is on its own budget → still allowed.
    assert_equal :ok, c.can_dispatch_patrol_scan?(project: "hive", now: T0)
  end

  def test_patrol_scan_slot_frees_on_completion
    c = make(patrol_scans: 1)
    dispatch(c, 100, "hive", "patrol-scan", kind: :patrol_scan)
    assert_equal :patrol_scan_cap, c.can_dispatch_patrol_scan?(project: "hive", now: T0)
    c.record_completion(pid: 100, exit_code: 0, completed_at: T0)
    assert_equal :ok, c.can_dispatch_patrol_scan?(project: "hive", now: T0)
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
    # Both completed; SUCCESS no longer blocks, so daily cap is the gate now.
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

  # ── SUCCESS completion ────────────────────────────────────────────────

  def test_success_does_not_cool_down_same_slug
    c = make
    dispatch(c, 100, "p1", "s1")

    c.record_completion(pid: 100, exit_code: Hive::ExitCodes::SUCCESS, completed_at: T0 + 5)

    assert_equal :ok, c.can_dispatch?(project: "p1", slug: "s1", now: T0 + 5)
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
    backoff = Hive::Daemon::ConcurrencyController::WRONG_STAGE_BACKOFF_SEC
    dispatch(c, 100, "p1", "s1")

    c.record_completion(pid: 100, exit_code: Hive::ExitCodes::WRONG_STAGE, completed_at: T0 + 1)

    assert_equal :cooldown, c.can_dispatch?(project: "p1", slug: "s1", now: T0 + 2)
    assert_equal :ok, c.can_dispatch?(project: "p1", slug: "s1", now: T0 + 1 + backoff + 1)
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

      c.prune_dispatch_baselines([ %w[p keep] ], scope_projects: %w[p])

      assert_equal T0, c.last_dispatched_state_file_mtime_for(project: "p", slug: "keep")
      assert_nil c.last_dispatched_state_file_mtime_for(project: "p", slug: "drop")
      # Prune persisted: a freshly-revived controller doesn't see the dropped key.
      revived = controller_with(Hive::Daemon::DispatchBaselines.new(path: path))
      assert_nil revived.last_dispatched_state_file_mtime_for(project: "p", slug: "drop")
    end
  end

  def test_prune_dispatch_baselines_requires_scope_projects
    # `scope_projects:` MUST be required — a default of nil would silently
    # re-strand answered tasks on per-project status errors (the bug the
    # whole persistence layer exists to prevent). A future caller forgetting
    # the kwarg must fail loud, not silent.
    with_store do |path|
      c = controller_with(Hive::Daemon::DispatchBaselines.new(path: path))
      c.observe_state_file_mtime(project: "p", slug: "s", mtime: T0)

      assert_raises(ArgumentError) { c.prune_dispatch_baselines([ %w[p s] ]) }
    end
  end

  def test_nil_store_keeps_state_in_memory_and_does_not_raise
    # Default `make` has no dispatch_state — pure in-memory, no file I/O.
    # The original assertion `Dir.glob(File.join(dir, '*')).empty?` was
    # vacuous because the controller never knew about `dir` — a regression
    # that erroneously wrote to e.g. `Hive::Paths.state_home` would still
    # leave that tmpdir empty. The behavior we actually care about: every
    # controller mutation succeeds without raising even when the store is nil.
    c = make
    c.observe_state_file_mtime(project: "p", slug: "s", mtime: T0)
    dispatch(c, 1, "p", "s2", mtime: T0)
    c.prune_dispatch_baselines([ %w[p s] ], scope_projects: %w[p])

    assert_equal T0, c.last_dispatched_state_file_mtime_for(project: "p", slug: "s")
    assert_nil c.last_dispatched_state_file_mtime_for(project: "p", slug: "s2"),
               "prune with empty live keys for the scoped project must drop absent entries"
  end

  # NOTE: defense-in-depth error handling now lives inside DispatchBaselines#write
  # rather than the controller — see dispatch_baselines_test.rb's
  # test_write_catches_unexpected_error_and_logs_typed_event for the contract pin.

  # `hive status --json` skips projects with `error: not_initialised` (NFS
  # hiccup, project being re-bootstrapped, transient race with `hive forget`)
  # — so their tasks disappear from `result.rows` even though the overall
  # fetch is still ok. Without a per-project scope guard the prune would
  # wipe every baseline for that project on the spot, silently re-stranding
  # every answered needs_input row in that project on the next first sight.
  def test_prune_preserves_baselines_for_projects_outside_scope
    with_store do |path|
      c = controller_with(Hive::Daemon::DispatchBaselines.new(path: path))
      c.observe_state_file_mtime(project: "writero", slug: "answered", mtime: T0)
      c.observe_state_file_mtime(project: "errored", slug: "still-here", mtime: T0)

      # Tick saw writero rows but `errored` project hit a per-project error
      # → absent from both rows and projects. Scope tells the controller to
      # leave that project's baselines alone.
      c.prune_dispatch_baselines([ %w[writero answered] ], scope_projects: %w[writero])

      assert_equal T0, c.last_dispatched_state_file_mtime_for(project: "writero", slug: "answered")
      assert_equal T0, c.last_dispatched_state_file_mtime_for(project: "errored", slug: "still-here"),
                   "a project missing from the scope must keep its baselines"
    end
  end
end
