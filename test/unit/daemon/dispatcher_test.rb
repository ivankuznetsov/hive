require "test_helper"
require "fileutils"
require "tmpdir"
require "hive/markers"
require "hive/daemon/dispatcher"
require "hive/daemon/concurrency_controller"
require "hive/daemon/dispatch_baselines"
require "hive/daemon/logger"

# Pin Dispatcher#tick logic with mocked collaborators. The point of
# these tests is the routing decisions: which Policy outcome maps to
# which Logger event, which dispatches consume capacity, which rows
# fall through to the merge watcher.
class HiveDaemonDispatcherTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 5, 6, 12, 0, 0)

  Row = Hive::Daemon::StatusConsumer::Row
  ChildExit = Hive::Daemon::ChildSupervisor::ChildExit

  def setup
    @row_dirs = []
  end

  def teardown
    Array(@row_dirs).each { |dir| FileUtils.rm_rf(dir) }
  end

  # ── fakes ─────────────────────────────────────────────────────────────

  class FakeStatusConsumer
    attr_writer :next_result
    def fetch
      @next_result || Hive::Daemon::StatusConsumer::Result.new(ok: true, rows: [], error: nil)
    end
  end

  class FakeSupervisor
    attr_reader :spawned, :next_pid
    def initialize
      @spawned = []
      @next_pid = 100
    end

    def spawn(command_string:, project:, slug:, stage:,
              hive_state_path: nil, state_file_path: nil, dry_run: nil,
              request_id: nil)
      pid = @next_pid
      @next_pid += 1
      @spawned << {
        pid: pid, command: command_string, project: project, slug: slug,
        stage: stage, state_file_path: state_file_path, dry_run: dry_run,
        request_id: request_id
      }
      pid
    end

    def reap_all(now: Time.now)
      []
    end

    def reap_dry_run(now: Time.now)
      []
    end

    def terminate_all(grace_sec: 600)
    end

    def in_flight_count
      @spawned.size
    end
  end

  class FakeMergeWatcher
    attr_reader :enqueued
    attr_accessor :next_archives, :next_dropped
    def initialize
      @enqueued = []
      @next_archives = []
      @last_tick_dropped = []
      @next_dropped = []
    end

    def enqueue(project:, slug:, task_folder:)
      @enqueued << { project: project, slug: slug, task_folder: task_folder }
    end

    def tick(now:)
      out = @next_archives
      @next_archives = []
      @last_tick_dropped = @next_dropped
      @next_dropped = []
      out
    end

    attr_reader :last_tick_dropped
  end

  # ── construction helpers ───────────────────────────────────────────────

  def make_dispatcher(rows: [], dry_run: false, with_merge_watcher: false,
                      project_enabled: true, dispatch_state: nil, status_result: nil,
                      dispatch_request_state_home: nil)
    config = {
      "daemon" => {
        "edit_debounce_sec" => 30,
        "poll_interval_sec" => 30,
        "shutdown_grace_sec" => 60
      }
    }
    controller = Hive::Daemon::ConcurrencyController.new(
      max_concurrent_runs: 5, max_concurrent_per_project: 5,
      max_runs_per_day_per_project: 100,
      dispatch_state: dispatch_state
    )
    supervisor = FakeSupervisor.new
    status = FakeStatusConsumer.new
    # Mirror what StatusConsumer emits in production: a `projects` list derived
    # from the rows being returned. Without this the dispatcher's prune scope
    # is empty and prune_dispatch_baselines never drops anything — making the
    # prune-on-tick path effectively dead in any test that relies on the
    # default `status_result`.
    projects_for_rows = rows.map(&:project).uniq.map do |name|
      Hive::Daemon::StatusConsumer::ProjectInfo.new(name: name, legacy_stage_dirs: [])
    end
    status.next_result = status_result ||
                         Hive::Daemon::StatusConsumer::Result.new(
                           ok: true, rows: rows, projects: projects_for_rows, error: nil
                         )
    logger = StubLogger.new
    merge_watcher = with_merge_watcher ? FakeMergeWatcher.new : nil

    dispatcher = Hive::Daemon::Dispatcher.new(
      config: config,
      controller: controller,
      supervisor: supervisor,
      status_consumer: status,
      logger: logger,
      merge_watcher: merge_watcher,
      dry_run: dry_run,
      dispatch_request_state_home: dispatch_request_state_home
    )
    # Bypass the Hive::Config.find_project / Config.load lookup chain
    # for unit tests — stub the predicate directly.
    dispatcher.define_singleton_method(:project_enabled?) { |_| project_enabled }
    [ dispatcher, supervisor, controller, logger, merge_watcher ]
  end

  class StubLogger
    attr_reader :events
    def initialize; @events = []; end
    def event(name, **attrs); @events << [ name, attrs ]; end
    def close; end
  end

  def row(project: "p1", slug: "s1", stage: "1-inbox", marker: "waiting",
          action: "ready_to_brainstorm", command: "hive brainstorm s1",
          mtime: T0 - 600, claude_pid_alive: nil, live_task_lock: nil,
          state_file: nil, folder: nil)
    folder ||= make_existing_row_folder(project: project, stage: stage, slug: slug)
    Row.new(
      project: project, slug: slug, stage: stage, marker: marker,
      folder: folder,
      state_file: state_file || File.join(folder, "idea.md"),
      state_file_mtime: mtime, action: action,
      suggested_command: command, claude_pid_alive: claude_pid_alive,
      live_task_lock: live_task_lock
    )
  end

  def make_existing_row_folder(project:, stage:, slug:)
    root = Dir.mktmpdir([ "hive-dispatcher-row", project, stage, slug ].join("-"))
    @row_dirs << root
    root
  end

  # ── core dispatch flow ────────────────────────────────────────────────

  def test_advance_action_dispatches_workflow_verb
    rows = [ row(action: "ready_to_plan", command: "hive plan s1 --from 2-brainstorm") ]
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows)
    dispatcher.tick(now: T0)
    assert_equal 1, sup.spawned.size
    assert_equal "hive plan s1 --from 2-brainstorm", sup.spawned.first[:command]
    assert events_include?(logger, :dispatched)
  end

  def test_advance_action_skips_when_task_folder_vanished_after_snapshot
    missing = File.join(Dir.tmpdir, "hive-dispatcher-missing-#{Process.pid}-#{rand(1_000_000)}")
    FileUtils.rm_rf(missing)
    rows = [
      row(action: "ready_to_plan",
          command: "hive plan s1 --from 2-brainstorm",
          folder: missing)
    ]
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows)

    dispatcher.tick(now: T0)

    assert_equal 0, sup.spawned.size, "stale snapshot row must not spawn after drop removed the folder"
    # No :dispatched event should fire — Policy.decide ran but the
    # vanished-folder guard suppresses the spawn AFTER the decision.
    refute events_include?(logger, :dispatched),
           "vanished-folder row must not produce a :dispatched log event"
    skipped = logger.events.find { |(name, attrs)| name == :skipped && attrs[:reason] == "folder_missing" }
    refute_nil skipped, "must log :skipped reason: folder_missing"
    assert_equal "s1", skipped[1][:slug]
  end

  # Nil/empty row.folder is a different signal (malformed snapshot)
  # than a folder that vanished between snapshot and dispatch. The
  # dispatcher distinguishes the two so operators reading daemon.log
  # can tell "drop just ran" apart from "the snapshot is broken".
  def test_advance_action_skips_with_distinct_reason_when_row_folder_nil
    folder_dir = make_existing_row_folder(project: "p1", stage: "1-inbox", slug: "s1")
    raw_row = Row.new(
      project: "p1", slug: "s1", stage: "1-inbox", marker: "waiting",
      folder: nil,
      state_file: File.join(folder_dir, "idea.md"),
      state_file_mtime: T0 - 600, action: "ready_to_plan",
      suggested_command: "hive plan s1 --from 2-brainstorm",
      claude_pid_alive: nil
    )
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: [ raw_row ])

    dispatcher.tick(now: T0)

    assert_equal 0, sup.spawned.size, "nil-folder row must not spawn"
    skipped = logger.events.find { |(name, attrs)| name == :skipped && attrs[:reason] == "folder_missing_nil" }
    refute_nil skipped,
               "nil row.folder must log :skipped reason: folder_missing_nil (distinct from folder_missing)"
    assert_equal "s1", skipped[1][:slug]
  end

  def test_disabled_project_is_skipped
    rows = [ row(action: "ready_to_plan", command: "hive plan s1 --from 2-brainstorm") ]
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows, project_enabled: false)
    dispatcher.tick(now: T0)
    assert_equal 0, sup.spawned.size
    refute events_include?(logger, :dispatched)
  end

  # PR-40 follow-up #2: the @enabled_cache must clear at the start of
  # each tick so a `daemon.enabled: false` edit in the project's YAML
  # takes effect on the next poll. Previously the cache persisted for
  # the daemon's lifetime and only SIGHUP cleared it — meaning a
  # disable could be silently ignored for hours.
  def test_enable_cache_clears_at_start_of_each_tick
    rows = [ row(action: "ready_to_plan", command: "hive plan s1 --from 2-brainstorm") ]
    dispatcher, sup, _ctrl, _logger, _mw = make_dispatcher(rows: rows, project_enabled: true)

    # Pre-seed the cache as if a previous tick saw the project enabled.
    dispatcher.instance_variable_get(:@enabled_cache)["p1"] = true
    # Now redefine project_enabled? to return false from THIS point on
    # (simulates the operator editing the YAML to disable the project).
    dispatcher.define_singleton_method(:project_enabled?) { |_| false }

    dispatcher.tick(now: T0)
    assert_equal 0, sup.spawned.size,
                 "tick must re-resolve enable status — stale cache cannot keep dispatch alive"
  end

  def test_recover_stale_action_is_skipped_with_log
    rows = [ row(action: "recover_review", marker: "review_error", stage: "6-review",
                 command: nil) ]
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows)
    dispatcher.tick(now: T0)
    assert_equal 0, sup.spawned.size
    skipped = logger.events.find { |(n, _)| n == :skipped }
    refute_nil skipped, "recover_stale row must produce a :skipped event"
  end

  def test_archive_action_routes_to_merge_watcher
    rows = [ row(stage: "8-finalize", action: "ready_to_archive",
                 command: "hive archive s1 --from 8-finalize") ]
    dispatcher, sup, _ctrl, _logger, mw = make_dispatcher(rows: rows, with_merge_watcher: true)
    dispatcher.tick(now: T0)
    assert_equal 0, sup.spawned.size, "archive must NOT spawn directly"
    assert_equal 1, mw.enqueued.size
    assert_equal "s1", mw.enqueued.first[:slug]
  end

  def test_merged_pr_archive_dispatches_through_supervisor
    # PR-40 review P2 #4: when PrMergeWatcher.tick returns an archive
    # dispatch entry (PR is MERGED), Dispatcher routes it through the
    # supervisor + caps just like a regular advance dispatch.
    dispatcher, sup, _ctrl, _logger, mw = make_dispatcher(rows: [], with_merge_watcher: true)
    mw.next_archives = [ {
      project: "p1", slug: "s1", stage: "8-finalize",
      command: "hive archive s1 --from 8-finalize --project p1 --json",
      state_file_mtime: nil, hive_state_path: nil
    } ]
    dispatcher.tick(now: T0)
    assert_equal 1, sup.spawned.size
    assert_equal "hive archive s1 --from 8-finalize --project p1 --json", sup.spawned.first[:command]
  end

  def test_merge_watcher_dropped_entries_are_logged
    dispatcher, _sup, _ctrl, logger, mw = make_dispatcher(rows: [], with_merge_watcher: true)
    mw.next_dropped = [ {
      project: "p1", slug: "s1", pr_url: "https://example.com/pull/1",
      failure_count: 3, last_error: "gh api failed"
    } ]

    dispatcher.tick(now: T0)

    event = logger.events.find { |(name, _attrs)| name == :merge_watcher_dropped }
    refute_nil event
    assert_equal({
      project: "p1", slug: "s1", pr_url: "https://example.com/pull/1",
      failure_count: 3, last_error: "gh api failed"
    }, event[1])
  end

  def test_merged_pr_archive_skips_when_project_disabled_after_enqueue
    # PR-40 review P2 #4: a project disabled between merge-watch
    # enqueue and the merge-completion tick must NOT be archived.
    dispatcher, sup, _ctrl, logger, mw = make_dispatcher(
      rows: [], with_merge_watcher: true, project_enabled: false
    )
    mw.next_archives = [ {
      project: "p1", slug: "s1", stage: "8-finalize",
      command: "hive archive s1 --from 8-finalize --project p1 --json",
      state_file_mtime: nil, hive_state_path: nil
    } ]
    dispatcher.tick(now: T0)
    assert_equal 0, sup.spawned.size
    skipped = logger.events.find { |(n, a)| n == :skipped && a[:reason] == "project_disabled_after_enqueue" }
    refute_nil skipped, "must log :skipped reason: project_disabled_after_enqueue"
  end

  def test_merged_pr_archive_skips_when_project_layout_is_legacy
    # ce-code-review P1 #10: when a project's status snapshot reports
    # legacy_stage_dirs (half-migrated layout), archive dispatch must
    # be deferred. The watcher's ARCHIVE_VERB_TEMPLATE is frozen at
    # class-load and may interpolate a stale `--from <stage>` that
    # doesn't match the post-migrate on-disk layout. Skip the dispatch
    # and let handle_row re-enqueue on a future tick.
    dispatcher, sup, _ctrl, logger, mw = make_dispatcher(
      rows: [], with_merge_watcher: true
    )
    legacy_project = Hive::Daemon::StatusConsumer::ProjectInfo.new(
      name: "p1",
      legacy_stage_dirs: [ { "stage_dir" => "7-finalize", "task_count" => 1 } ]
    )
    dispatcher.instance_variable_get(:@status_consumer).next_result =
      Hive::Daemon::StatusConsumer::Result.new(
        ok: true, rows: [], projects: [ legacy_project ], error: nil
      )
    mw.next_archives = [ {
      project: "p1", slug: "s1", stage: "8-finalize",
      command: "hive archive s1 --from 8-finalize --project p1 --json",
      state_file_mtime: nil, hive_state_path: nil
    } ]
    dispatcher.tick(now: T0)
    assert_equal 0, sup.spawned.size,
                 "archive must not fire while the project is half-migrated"
    skipped = logger.events.find { |(n, a)| n == :skipped && a[:reason] == "legacy_layout_detected" }
    refute_nil skipped, "must log :skipped reason: legacy_layout_detected"
    assert_equal "archive", skipped[1][:action]
  end

  def test_merged_pr_archive_respects_global_cap
    # PR-40 review P2 #4: with N PRs ready to archive but only M
    # capacity slots open, only M archives spawn this tick; the rest
    # block (and re-enqueue for the next tick).
    dispatcher, sup, ctrl, logger, mw = make_dispatcher(
      rows: [], with_merge_watcher: true
    )
    # Force global cap to 1 with one slot already used.
    ctrl.instance_variable_set(:@max_concurrent_runs, 1)
    ctrl.record_dispatch(
      pid: 999, project: "px", slug: "running",
      stage: "6-review", command: "hive run", started_at: T0,
      state_file_mtime: T0 - 60
    )

    mw.next_archives = [ {
      project: "p1", slug: "s1", stage: "8-finalize",
      command: "hive archive s1 --from 8-finalize --project p1 --json",
      state_file_mtime: nil, hive_state_path: nil
    } ]
    dispatcher.tick(now: T0)
    assert_equal 0, sup.spawned.size, "global cap reached → no archive spawn"
    blocked = logger.events.find { |(n, a)| n == :blocked && a[:action] == "archive" }
    refute_nil blocked, "must log :blocked for the archive dispatch"
    assert_equal "global_cap", blocked[1][:reason]
  end

  def test_edit_action_within_debounce_after_baseline_logs_debouncing
    # With a baseline already recorded (i.e. NOT first sight), a fresh
    # edit within the debounce window logs :debouncing and does not
    # dispatch.
    rows = [ row(action: "needs_input", marker: "waiting",
                 command: "hive brainstorm s1 --from 2-brainstorm",
                 mtime: T0 - 5) ]
    dispatcher, sup, ctrl, logger, _mw = make_dispatcher(rows: rows)
    ctrl.observe_state_file_mtime(project: "p1", slug: "s1", mtime: T0 - 600)
    dispatcher.tick(now: T0)
    assert_equal 0, sup.spawned.size
    assert events_include?(logger, :debouncing)
  end

  def test_edit_action_first_sight_records_baseline_does_not_dispatch
    # PR-40 review P1 #1: first sight of `kind: edit` cannot tell if
    # the file has fresh user edits or just the agent's WAITING write.
    # Skip + seed the controller with the current mtime so the next
    # tick has a baseline. A subsequent tick where mtime moves past
    # the baseline triggers the actual dispatch.
    rows = [ row(action: "needs_input", marker: "waiting",
                 command: "hive brainstorm s1 --from 2-brainstorm",
                 mtime: T0 - 600) ]
    dispatcher, sup, ctrl, logger, _mw = make_dispatcher(rows: rows)
    dispatcher.tick(now: T0)
    assert_equal 0, sup.spawned.size, "first-sight kind: edit must not dispatch"
    # Baseline got recorded
    refute_nil ctrl.last_dispatched_state_file_mtime_for(project: "p1", slug: "s1")
    # Logged as :skipped with reason: baseline_recorded
    skipped = logger.events.find { |(n, a)| n == :skipped && a[:reason] == "baseline_recorded" }
    refute_nil skipped, "must log :skipped reason: baseline_recorded"
  end

  def test_plan_needs_input_first_sight_dispatches_without_baseline
    # End-to-end fix for PR #83's P0: the production command for a
    # `plan_waiting` row is `hive plan ...` (per TaskAction; see the
    # `plan_waiting` entry in lib/hive/task_action.rb). The daemon
    # rewrites it to `hive develop ...` AND flips the `:waiting`
    # marker to `:complete` before dispatch so the workflow verb's
    # terminal-marker gate (VALID_TERMINAL_MARKERS) accepts the
    # advance. Both steps live in Hive::Daemon::PlanApproval.
    Dir.mktmpdir("dispatcher-plan-approval") do |dir|
      state_file = File.join(dir, "plan.md")
      File.write(state_file, "# plan\n\n<!-- WAITING -->\n")

      rows = [ row(stage: "3-plan", action: "needs_input", marker: "waiting",
                   command: "hive plan s1 --from 3-plan",
                   mtime: T0 - 600, state_file: state_file) ]
      dispatcher, sup, ctrl, logger, _mw = make_dispatcher(rows: rows)
      dispatcher.tick(now: T0)

      # Dispatched the rewritten command (develop, not plan).
      assert_equal 1, sup.spawned.size
      assert_equal "hive develop s1 --from 3-plan", sup.spawned.first[:command],
                   "PlanApproval must rewrite `hive plan ...` to `hive develop ...`"

      # Marker flipped to :complete on disk so `hive develop --from
      # 3-plan` will be accepted by VALID_TERMINAL_MARKERS on the
      # spawned child.
      assert_equal :complete, Hive::Markers.current(state_file).name,
                   "plan-approval auto-dispatch must flip :waiting → :complete"

      # Baseline mtime recorded so subsequent ticks have something
      # to compare against (and don't re-record a baseline).
      assert_equal T0 - 600,
                   ctrl.last_dispatched_state_file_mtime_for(project: "p1", slug: "s1")
      refute logger.events.any? { |(n, a)| n == :skipped && a[:reason] == "baseline_recorded" }

      # Audit event fired with the trigger field set so log readers
      # can distinguish plan-approval dispatches from advance-action
      # dispatches without re-implementing Policy.decide.
      assert events_include?(logger, :dispatched)
      dispatched_event = logger.events.find { |(n, _a)| n == :dispatched }
      assert_equal "plan_approval", dispatched_event[1][:trigger]
    end
  end

  def test_plan_needs_input_skips_when_marker_is_not_waiting_or_complete
    # PlanApproval.prepare raises NotApprovable for any marker that
    # isn't :waiting or :complete (e.g., :error). The dispatcher must
    # log :skipped and NOT spawn — the workflow verb's WrongStage
    # check would refuse the advance anyway, but failing in Policy is
    # noisier than failing in PlanApproval, so we route to :skip
    # before dispatch.
    Dir.mktmpdir("dispatcher-plan-approval-error") do |dir|
      state_file = File.join(dir, "plan.md")
      File.write(state_file, "# plan\n\n<!-- ERROR reason=plan_failed -->\n")

      rows = [ row(stage: "3-plan", action: "needs_input", marker: "waiting",
                   command: "hive plan s1 --from 3-plan",
                   mtime: T0 - 600, state_file: state_file) ]
      dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows)
      dispatcher.tick(now: T0)

      assert_equal 0, sup.spawned.size, "must not spawn when marker isn't :waiting/:complete"
      skip_event = logger.events.find do |(n, a)|
        n == :skipped && a[:reason].to_s.start_with?("plan_approval_invalid")
      end
      refute_nil skip_event,
                 "must log :skipped reason: plan_approval_invalid (got events: #{logger.events.map(&:first).inspect})"
    end
  end

  def test_plan_needs_input_with_malformed_command_skips
    # If the suggested_command is not a well-formed `hive plan ...`
    # invocation (e.g., a stale TaskAction emission or a malformed
    # status JSON row), PlanApproval raises ArgumentError; dispatcher
    # routes to :skip with a reason field instead of spawning a
    # garbage subprocess.
    Dir.mktmpdir("dispatcher-plan-approval-malformed") do |dir|
      state_file = File.join(dir, "plan.md")
      File.write(state_file, "# plan\n\n<!-- WAITING -->\n")

      rows = [ row(stage: "3-plan", action: "needs_input", marker: "waiting",
                   command: "hive review s1 --from 3-plan",
                   mtime: T0 - 600, state_file: state_file) ]
      dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows)
      dispatcher.tick(now: T0)

      assert_equal 0, sup.spawned.size
      skip_event = logger.events.find do |(n, a)|
        n == :skipped && a[:reason].to_s.start_with?("plan_approval_invalid")
      end
      refute_nil skip_event
      # Marker NOT flipped — malformed command must leave the
      # marker at :waiting so an operator can inspect.
      assert_equal :waiting, Hive::Markers.current(state_file).name,
                   "malformed command must not flip the marker"
    end
  end

  def test_edit_action_after_baseline_user_edit_dispatches
    rows = [ row(action: "needs_input", marker: "waiting",
                 command: "hive brainstorm s1 --from 2-brainstorm",
                 mtime: T0 - 60) ]
    dispatcher, sup, ctrl, _logger, _mw = make_dispatcher(rows: rows)
    # Pretend a previous tick recorded an older baseline
    ctrl.observe_state_file_mtime(project: "p1", slug: "s1", mtime: T0 - 600)
    dispatcher.tick(now: T0)
    assert_equal 1, sup.spawned.size
  end

  # ── concurrency cap respected ─────────────────────────────────────────

  def test_global_cap_blocks_third_dispatch
    rows = [
      row(slug: "s1", action: "ready_to_plan", command: "hive plan s1 --from 2-brainstorm"),
      row(slug: "s2", action: "ready_to_plan", command: "hive plan s2 --from 2-brainstorm"),
      row(slug: "s3", action: "ready_to_plan", command: "hive plan s3 --from 2-brainstorm")
    ]
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows)
    # Override controller cap
    dispatcher.controller.instance_variable_set(:@max_concurrent_runs, 2)

    dispatcher.tick(now: T0)
    assert_equal 2, sup.spawned.size
    blocked = logger.events.find { |(n, attrs)| n == :blocked && attrs[:slug] == "s3" }
    refute_nil blocked, "third dispatch must be :blocked when global cap = 2"
    assert_equal "global_cap", blocked[1][:reason]
  end

  def test_status_active_agent_row_counts_toward_project_cap
    rows = [
      row(slug: "running", stage: "6-review", marker: "review_working",
          action: "agent_running", command: nil, claude_pid_alive: true),
      row(slug: "ready", action: "ready_to_plan",
          command: "hive plan ready --from 2-brainstorm")
    ]
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows)
    dispatcher.controller.instance_variable_set(:@max_concurrent_per_project, 1)

    dispatcher.tick(now: T0)

    assert_equal 0, sup.spawned.size
    blocked = logger.events.find { |(n, attrs)| n == :blocked && attrs[:slug] == "ready" }
    refute_nil blocked, "ready row must block while an active agent is already running"
    assert_equal "project_cap", blocked[1][:reason]
  end

  def test_agent_running_rows_from_prior_daemon_count_toward_global_cap
    rows = [
      row(slug: "already-running", action: "agent_running", command: nil, mtime: T0 - 60),
      row(slug: "ready", action: "ready_to_plan", command: "hive plan ready --from 2-brainstorm")
    ]
    rows.first.claude_pid_alive = true
    dispatcher, sup, ctrl, logger, _mw = make_dispatcher(rows: rows)
    ctrl.instance_variable_set(:@max_concurrent_runs, 1)

    dispatcher.tick(now: T0)

    assert_equal 0, sup.spawned.size
    blocked = logger.events.find { |(n, attrs)| n == :blocked && attrs[:slug] == "ready" }
    refute_nil blocked, "visible running agents must consume capacity after daemon restart"
    assert_equal "global_cap", blocked[1][:reason]
  end

  # Issue #144: a row whose only liveness signal is `live_task_lock`
  # (runner is in the pre-claude_pid window — auto-rebase or other
  # pre-stage work) must consume capacity, otherwise the daemon will
  # dispatch more work and breach the global cap.
  def test_live_task_lock_only_row_counts_toward_global_cap
    rows = [
      row(slug: "rebasing", action: "agent_running", command: nil, mtime: T0 - 60,
          claude_pid_alive: nil, live_task_lock: true),
      row(slug: "ready", action: "ready_to_plan", command: "hive plan ready --from 2-brainstorm")
    ]
    dispatcher, sup, ctrl, logger, _mw = make_dispatcher(rows: rows)
    ctrl.instance_variable_set(:@max_concurrent_runs, 1)

    dispatcher.tick(now: T0)

    assert_equal 0, sup.spawned.size
    blocked = logger.events.find { |(n, attrs)| n == :blocked && attrs[:slug] == "ready" }
    refute_nil blocked, "live_task_lock=true row must consume a global cap slot"
    assert_equal "global_cap", blocked[1][:reason]
  end

  def test_needs_input_rows_do_not_count_toward_project_cap
    rows = [
      row(slug: "waiting", stage: "2-brainstorm", action: "needs_input",
          command: "hive brainstorm waiting --from 2-brainstorm"),
      row(slug: "ready", action: "ready_to_plan",
          command: "hive plan ready --from 2-brainstorm")
    ]
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows)
    dispatcher.controller.instance_variable_set(:@max_concurrent_per_project, 1)

    dispatcher.tick(now: T0)

    assert_equal 1, sup.spawned.size
    assert_equal "ready", sup.spawned.first[:slug]
    refute logger.events.any? { |(n, attrs)| n == :blocked && attrs[:slug] == "ready" }
  end

  def test_status_agent_row_for_daemon_child_is_not_double_counted
    rows = [
      row(slug: "running", stage: "6-review", marker: "review_working",
          action: "agent_running", command: nil, claude_pid_alive: true),
      row(slug: "ready", action: "ready_to_plan",
          command: "hive plan ready --from 2-brainstorm")
    ]
    dispatcher, sup, ctrl, _logger, _mw = make_dispatcher(rows: rows)
    dispatcher.controller.instance_variable_set(:@max_concurrent_runs, 2)
    ctrl.record_dispatch(
      pid: 999, project: "p1", slug: "running",
      stage: "6-review", command: "hive review running",
      started_at: T0, state_file_mtime: T0 - 60
    )

    dispatcher.tick(now: T0)

    assert_equal 1, sup.spawned.size,
                 "the status row for a daemon-owned child must not consume a second slot"
    assert_equal "ready", sup.spawned.first[:slug]
  end

  def test_stale_agent_running_row_does_not_consume_capacity
    rows = [
      row(slug: "stale", action: "agent_running", command: nil, mtime: T0 - 60),
      row(slug: "ready", action: "ready_to_plan", command: "hive plan ready --from 2-brainstorm")
    ]
    rows.first.claude_pid_alive = false
    dispatcher, sup, ctrl, _logger, _mw = make_dispatcher(rows: rows)
    ctrl.instance_variable_set(:@max_concurrent_runs, 1)

    dispatcher.tick(now: T0)

    assert_equal 1, sup.spawned.size
    assert_equal "ready", sup.spawned.first[:slug]
  end

  # ── status failure ────────────────────────────────────────────────────

  def test_status_failure_logs_and_returns_no_dispatches
    config = { "daemon" => { "edit_debounce_sec" => 30, "poll_interval_sec" => 30 } }
    controller = Hive::Daemon::ConcurrencyController.new(
      max_concurrent_runs: 5, max_concurrent_per_project: 5,
      max_runs_per_day_per_project: 100
    )
    supervisor = FakeSupervisor.new
    status = FakeStatusConsumer.new
    status.next_result = Hive::Daemon::StatusConsumer::Result.new(
      ok: false, rows: [], error: "hive status crashed"
    )
    logger = StubLogger.new

    dispatcher = Hive::Daemon::Dispatcher.new(
      config: config, controller: controller, supervisor: supervisor,
      status_consumer: status, logger: logger
    )
    dispatcher.tick(now: T0)
    assert_equal 0, supervisor.spawned.size
    assert events_include?(logger, :status_failure)
  end

  # ── dry run ───────────────────────────────────────────────────────────

  def test_dry_run_passes_flag_to_supervisor
    rows = [ row(action: "ready_to_plan", command: "hive plan s1 --from 2-brainstorm") ]
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows, dry_run: true)
    dispatcher.tick(now: T0)
    assert_equal 1, sup.spawned.size
    assert_equal true, sup.spawned.first[:dry_run]
    assert events_include?(logger, :dry_run)
  end

  # ── child exit handling ───────────────────────────────────────────────

  def test_child_exit_records_completion_and_logs
    config = { "daemon" => { "edit_debounce_sec" => 30, "poll_interval_sec" => 30 } }
    controller = Hive::Daemon::ConcurrencyController.new(
      max_concurrent_runs: 5, max_concurrent_per_project: 5,
      max_runs_per_day_per_project: 100
    )
    supervisor = FakeSupervisor.new
    # Override reap to return one fake completion
    def supervisor.reap_all(now: Time.now)
      return [] if @reaped
      @reaped = true
      [ ChildExit.new(pid: 999, exit_code: 0, project: "p1", slug: "s1",
                      stage: "6-review", command: "hive run s1",
                      started_at: T0, finished_at: now, json_envelope: nil) ]
    end
    status = FakeStatusConsumer.new
    logger = StubLogger.new

    # Pre-record the dispatch so the controller has something to clear
    controller.record_dispatch(pid: 999, project: "p1", slug: "s1",
                               stage: "6-review", command: "hive run s1",
                               started_at: T0, state_file_mtime: T0 - 60)

    dispatcher = Hive::Daemon::Dispatcher.new(
      config: config, controller: controller, supervisor: supervisor,
      status_consumer: status, logger: logger
    )
    dispatcher.tick(now: T0 + 100)
    assert events_include?(logger, :child_exited)
    assert_equal 0, controller.in_flight_count, "completed child must clear running entry"
  end

  def test_config_exit_drops_project
    config = { "daemon" => { "edit_debounce_sec" => 30, "poll_interval_sec" => 30 } }
    controller = Hive::Daemon::ConcurrencyController.new(
      max_concurrent_runs: 5, max_concurrent_per_project: 5,
      max_runs_per_day_per_project: 100
    )
    supervisor = FakeSupervisor.new
    def supervisor.reap_all(now: Time.now)
      return [] if @reaped
      @reaped = true
      [ ChildExit.new(pid: 999, exit_code: Hive::ExitCodes::CONFIG, project: "p1",
                      slug: "s1", stage: "6-review", command: "hive run s1",
                      started_at: Time.now, finished_at: now, json_envelope: nil) ]
    end
    controller.record_dispatch(pid: 999, project: "p1", slug: "s1",
                               stage: "6-review", command: "hive run s1",
                               started_at: Time.now, state_file_mtime: Time.now - 60)
    status = FakeStatusConsumer.new
    logger = StubLogger.new

    dispatcher = Hive::Daemon::Dispatcher.new(
      config: config, controller: controller, supervisor: supervisor,
      status_consumer: status, logger: logger
    )
    dispatcher.tick(now: T0)
    assert controller.project_dropped?("p1")
    assert events_include?(logger, :project_dropped)
  end

  # ── stale-agent healer integration ────────────────────────────────────

  def test_dispatcher_tick_heals_dead_pid_agent_working_marker_on_disk
    # End-to-end wiring test: dispatcher#tick must invoke the real
    # StaleAgentHealer with the tick's frozen `now` and the current
    # legacy_layout_projects set. Plant a real on-disk task.md with
    # AGENT_WORKING and an attached-but-dead pid; assert the marker
    # is rewritten on the same tick that processed it.
    Dir.mktmpdir("dispatcher-healer-integration") do |tmpdir|
      state_file = File.join(tmpdir, "task.md")
      File.write(state_file, "# task\n\n<!-- AGENT_WORKING pid=99999999 -->\n")

      stale_row = row(
        project: "p1", slug: "stale-1", stage: "4-execute",
        marker: "agent_working", action: "error", # post-U4 status produces this
        state_file: state_file,
        mtime: T0 - 1000,
        claude_pid_alive: false
      )
      dispatcher, _sup, _ctrl, logger, _mw = make_dispatcher(rows: [ stale_row ])
      dispatcher.tick(now: T0)

      assert events_include?(logger, :marker_healed),
             "dispatcher#tick must invoke the real healer; events=#{logger.events.inspect}"
      heal_attrs = logger.events.find { |(n, _)| n == :marker_healed }[1]
      assert_equal "agent_died", heal_attrs[:reason]
      assert_match(/ERROR\s+reason=agent_died/, File.read(state_file),
                   "healer must rewrite the on-disk marker, not just log")
    end
  end

  def test_dispatcher_tick_skips_healing_for_legacy_layout_projects
    Dir.mktmpdir("dispatcher-healer-legacy") do |tmpdir|
      state_file = File.join(tmpdir, "task.md")
      File.write(state_file, "# task\n\n<!-- AGENT_WORKING pid=99999999 -->\n")
      stale_row = row(
        project: "legacy-proj", slug: "stale-1", stage: "4-execute",
        marker: "agent_working", action: "error",
        state_file: state_file, mtime: T0 - 1000, claude_pid_alive: false
      )
      legacy_project = Hive::Daemon::StatusConsumer::ProjectInfo.new(
        name: "legacy-proj",
        legacy_stage_dirs: [ { "stage_dir" => "1-input", "task_count" => 1 } ]
      )

      config = { "daemon" => { "edit_debounce_sec" => 30, "poll_interval_sec" => 30 } }
      controller = Hive::Daemon::ConcurrencyController.new(
        max_concurrent_runs: 5, max_concurrent_per_project: 5,
        max_runs_per_day_per_project: 100
      )
      supervisor = FakeSupervisor.new
      status = FakeStatusConsumer.new
      status.next_result = Hive::Daemon::StatusConsumer::Result.new(
        ok: true, rows: [ stale_row ], projects: [ legacy_project ], error: nil
      )
      logger = StubLogger.new
      dispatcher = Hive::Daemon::Dispatcher.new(
        config: config, controller: controller, supervisor: supervisor,
        status_consumer: status, logger: logger
      )

      dispatcher.tick(now: T0)

      refute events_include?(logger, :marker_healed),
             "half-migrated projects must be excluded from healing; events=#{logger.events.inspect}"
      assert_match(/AGENT_WORKING/, File.read(state_file),
                   "marker on disk must be untouched when project is half-migrated")
    end
  end

  def test_dispatcher_outer_rescue_logs_fatal_and_continues_per_row_dispatch
    # If the healer itself raises (a bug, not a per-row disk failure),
    # the dispatcher's outer rescue must log :fatal and let the rest of
    # the tick proceed — so a future healer bug doesn't trigger
    # systemd's StartLimitBurst cap by failing every tick.
    advance_row = row(action: "ready_to_plan", command: "hive plan s1 --from 2-brainstorm")
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: [ advance_row ])
    # Stub the dispatcher's healer instance to raise on heal.
    healer = dispatcher.instance_variable_get(:@stale_agent_healer)
    def healer.heal(*, **)
      raise NoMethodError, "simulated healer bug"
    end

    dispatcher.tick(now: T0)

    fatal = logger.events.find { |(n, _)| n == :fatal }
    assert fatal, "outer rescue must log :fatal when healer raises; events=#{logger.events.inspect}"
    assert_includes fatal[1][:message], "stale_agent_healer raised"
    assert_equal 1, sup.spawned.size,
                 "per-row dispatch must still run after healer crash to avoid StartLimitBurst flapping"
  end

  def test_reload_config_rebuilds_healer_with_new_grace_sec
    dispatcher, _sup, _ctrl, _logger, _mw = make_dispatcher
    original_healer = dispatcher.instance_variable_get(:@stale_agent_healer)
    refute_nil original_healer, "dispatcher must construct a healer at boot"

    # Stub Config.load_global_daemon to return a new grace, then reload.
    # `Hive::Config` is a module_function-defined module, so its
    # methods live on the singleton class. Save the original and
    # restore via `define_singleton_method(..., &original)` rather
    # than `remove_method` — the latter would delete the real
    # implementation and break every later test that loads config.
    new_cfg = { "agent_marker_grace_sec" => 60, "edit_debounce_sec" => 30 }
    original = Hive::Config.method(:load_global_daemon)
    Hive::Config.define_singleton_method(:load_global_daemon) { new_cfg }
    begin
      dispatcher.send(:reload_config!)
    ensure
      Hive::Config.define_singleton_method(:load_global_daemon, &original)
    end

    rebuilt = dispatcher.instance_variable_get(:@stale_agent_healer)
    refute_same original_healer, rebuilt,
                "reload_config! must rebuild the healer so new daemon.agent_marker_grace_sec binds"
    assert_equal 60, rebuilt.instance_variable_get(:@grace_sec),
                 "rebuilt healer must carry the reloaded grace value"
  end

def test_run_forever_reloads_ticks_and_shuts_down_cleanly
  dispatcher, supervisor, _ctrl, logger, _mw = make_dispatcher
  ticks = 0
  reloads = 0
  sleeps = []

  dispatcher.define_singleton_method(:install_signal_handlers!) { true }
  dispatcher.define_singleton_method(:reload_config!) { reloads += 1 }
  dispatcher.define_singleton_method(:interruptible_sleep) { |seconds| sleeps << seconds }
  dispatcher.define_singleton_method(:tick) do
    ticks += 1
    request_reload! if ticks == 1
    request_shutdown! if ticks == 2
  end

  dispatcher.run_forever

  assert_equal 2, ticks
  assert_equal 1, reloads
  assert_equal [ 30, 30 ], sleeps
  assert events_include?(logger, :dispatcher_started)
  assert events_include?(logger, :dispatcher_stopping)
  assert_equal 0, supervisor.spawned.size
end

def test_request_methods_flip_lifecycle_flags
  dispatcher, _sup, _ctrl, _logger, _mw = make_dispatcher

  dispatcher.request_reload!
  dispatcher.request_shutdown!

  assert_equal true, dispatcher.instance_variable_get(:@reload)
  assert_equal true, dispatcher.instance_variable_get(:@shutdown)
end

def test_install_signal_handlers_sets_shutdown_and_reload_flags
  dispatcher, _sup, _ctrl, _logger, _mw = make_dispatcher
  old_handlers = {}
  %w[TERM INT HUP].each { |signal| old_handlers[signal] = Signal.trap(signal, "IGNORE") }

  begin
    dispatcher.send(:install_signal_handlers!)
    Process.kill("HUP", Process.pid)
    sleep 0.01
    assert_equal true, dispatcher.instance_variable_get(:@reload)

    dispatcher.instance_variable_set(:@shutdown, false)
    Process.kill("INT", Process.pid)
    sleep 0.01
    assert_equal true, dispatcher.instance_variable_get(:@shutdown)

    dispatcher.instance_variable_set(:@shutdown, false)
    Process.kill("TERM", Process.pid)
    sleep 0.01
    assert_equal true, dispatcher.instance_variable_get(:@shutdown)
  ensure
    old_handlers.each { |signal, handler| Signal.trap(signal, handler) }
  end
end

def test_refresh_post_completion_mtime_records_existing_state_file
  dispatcher, _sup, ctrl, _logger, _mw = make_dispatcher

  Dir.mktmpdir("dispatcher-completion-mtime") do |dir|
    state_file = File.join(dir, "task.md")
    File.write(state_file, "# task\n")
    File.utime(T0 - 10, T0 - 10, state_file)
    child = ChildExit.new(
      pid: 999, exit_code: 0, project: "p1", slug: "s1", stage: "6-review",
      command: "hive review s1", state_file_path: state_file,
      started_at: T0 - 100, finished_at: T0, json_envelope: nil
    )

    dispatcher.send(:refresh_post_completion_mtime, child)

    assert_equal File.mtime(state_file),
                 ctrl.last_dispatched_state_file_mtime_for(project: "p1", slug: "s1")
  end
end

def test_resolve_post_completion_path_finds_advanced_stage_state_file
  dispatcher, _sup, _ctrl, _logger, _mw = make_dispatcher

  Dir.mktmpdir("dispatcher-post-advance") do |dir|
    hive_state_path = File.join(dir, ".hive-state")
    slug_dir = File.join(hive_state_path, "stages", "6-review", "s1")
    FileUtils.mkdir_p(slug_dir)
    older = File.join(slug_dir, "old.md")
    newer = File.join(slug_dir, "review.md")
    File.write(older, "old\n")
    File.write(newer, "new\n")
    File.utime(T0 - 20, T0 - 20, older)
    File.utime(T0 - 10, T0 - 10, newer)
    child = ChildExit.new(
      pid: 999, exit_code: 0, project: "p1", slug: "s1", stage: "4-execute",
      command: "hive develop s1", state_file_path: File.join(dir, "missing.md"),
      started_at: T0 - 100, finished_at: T0, json_envelope: nil
    )

    with_replaced_singleton_method(Hive::Config, :find_project, ->(_project) { { "hive_state_path" => hive_state_path } }) do
      assert_equal newer, dispatcher.send(:resolve_post_completion_path, child)
    end
  end
end

def test_find_post_advance_state_file_handles_missing_and_empty_layouts
  dispatcher, _sup, _ctrl, _logger, _mw = make_dispatcher

  Dir.mktmpdir("dispatcher-empty-post-advance") do |dir|
    hive_state_path = File.join(dir, ".hive-state")
    FileUtils.mkdir_p(File.join(hive_state_path, "stages", "6-review", "s1"))

    assert_nil dispatcher.send(:find_post_advance_state_file, nil, "s1")
    assert_nil dispatcher.send(:find_post_advance_state_file, hive_state_path, "s1")
  end
end

def test_dry_run_reaps_pseudo_children_and_logs_completion
  dispatcher, _sup, ctrl, logger, _mw = make_dispatcher(rows: [], dry_run: true)
  child = ChildExit.new(
    pid: -1, exit_code: 0, project: "p1", slug: "s1", stage: "3-plan",
    command: "hive plan s1", state_file_path: nil,
    started_at: T0, finished_at: T0, json_envelope: nil
  )
  dispatcher.supervisor.define_singleton_method(:reap_dry_run) { |now:| [ child ] }
  ctrl.record_dispatch(pid: -1, project: "p1", slug: "s1", stage: "3-plan",
                       command: "hive plan s1", started_at: T0, state_file_mtime: T0 - 60)

  dispatcher.tick(now: T0)

  assert_equal 0, ctrl.in_flight_count
  event = logger.events.find { |(name, attrs)| name == :child_exited && attrs[:dry_run] == true }
  refute_nil event
end

def test_archive_dispatch_reenqueue_errors_are_logged_as_fatal
  dispatcher, _sup, ctrl, logger, mw = make_dispatcher(rows: [], with_merge_watcher: true)
  ctrl.instance_variable_set(:@max_concurrent_runs, 1)
  ctrl.record_dispatch(pid: 999, project: "p1", slug: "running", stage: "6-review",
                       command: "hive review running", started_at: T0, state_file_mtime: T0 - 60)
  mw.next_archives = [ {
    project: "p1", slug: "s1", stage: "7-finalize",
    command: "hive archive s1 --from 7-finalize --project p1 --json",
    state_file_mtime: nil, hive_state_path: nil
  } ]

  with_replaced_singleton_method(Hive::Config, :find_project, ->(_project) { raise "registry unavailable" }) do
    dispatcher.tick(now: T0)
  end

  fatal = logger.events.find { |(name, attrs)| name == :fatal && attrs[:message].include?("archive dispatch error") }
  refute_nil fatal
  assert_includes fatal[1][:message], "registry unavailable"
end

def test_project_enabled_reads_project_config_and_caches_result
  dispatcher, _sup, _ctrl, _logger, _mw = make_dispatcher
  dispatcher.singleton_class.send(:remove_method, :project_enabled?)
  load_calls = []

  with_replaced_singleton_method(Hive::Config, :find_project, ->(_project) { { "path" => "/tmp/project" } }) do
    with_replaced_singleton_method(Hive::Config, :load, lambda { |path|
      load_calls << path
      { "daemon" => { "enabled" => true } }
    }) do
      assert_equal true, dispatcher.send(:project_enabled?, "p1")
      assert_equal true, dispatcher.send(:project_enabled?, "p1")
    end
  end

  assert_equal [ "/tmp/project" ], load_calls
end

def test_project_enabled_returns_false_for_missing_or_invalid_project_config
  dispatcher, _sup, _ctrl, _logger, _mw = make_dispatcher
  dispatcher.singleton_class.send(:remove_method, :project_enabled?)

  with_replaced_singleton_method(Hive::Config, :find_project, ->(_project) { nil }) do
    assert_equal false, dispatcher.send(:project_enabled?, "missing")
  end

  dispatcher.instance_variable_get(:@enabled_cache).clear
  with_replaced_singleton_method(Hive::Config, :find_project, ->(_project) { { "path" => "/tmp/project" } }) do
    with_replaced_singleton_method(Hive::Config, :load, ->(_path) { raise Hive::ConfigError, "bad config" }) do
      assert_equal false, dispatcher.send(:project_enabled?, "bad")
    end
  end
end

def test_reload_config_error_logs_and_keeps_previous_config
  dispatcher, _sup, _ctrl, logger, _mw = make_dispatcher
  original_cfg = dispatcher.instance_variable_get(:@daemon_cfg)

  with_replaced_singleton_method(Hive::Config, :load_global_daemon, -> { raise Hive::ConfigError, "broken yaml" }) do
    dispatcher.send(:reload_config!)
  end

  assert_same original_cfg, dispatcher.instance_variable_get(:@daemon_cfg)
  fatal = logger.events.find { |(name, attrs)| name == :fatal && attrs[:message].include?("config reload failed") }
  refute_nil fatal
  assert_includes fatal[1][:message], "broken yaml"
end

def test_interruptible_sleep_stops_after_shutdown_request
  dispatcher, _sup, _ctrl, _logger, _mw = make_dispatcher
  sleeps = []
  dispatcher.define_singleton_method(:sleep) do |seconds|
    sleeps << seconds
    request_shutdown!
  end

  dispatcher.send(:interruptible_sleep, 30)

  assert_equal [ 0.5 ], sleeps
end

  # ── dispatch-baseline persistence across restart ───────────────────────
  # Tests below MUST stay above the `private` declaration further down —
  # Minitest only discovers public test methods. A prior arrangement hid them
  # under `private` and silently ran zero of them (line coverage stayed green
  # via other tests indirectly exercising `prune_dispatch_baselines`, masking
  # the regression these tests pin).

  # The core fix: a needs_input row answered BEFORE a daemon restart must
  # dispatch, not be re-stranded. The pre-restart "ask" baseline is persisted;
  # the live state-file mtime (the user's answer) is newer, so the freshly
  # restarted dispatcher dispatches. Without persistence the reloaded baseline
  # would be nil → first-sight → :record_baseline → skip (the bug).
  def test_pre_restart_answer_dispatches_after_restart_via_persisted_baseline
    Dir.mktmpdir do |dir|
      path = File.join(dir, "baselines.json")
      seed_baseline(path, project: "writero", slug: "add-x", mtime: T0 - 600) # the ask

      answered = row(project: "writero", slug: "add-x", stage: "2-brainstorm",
                     action: "needs_input",
                     command: "hive brainstorm add-x --from 2-brainstorm",
                     mtime: T0 - 40) # user's answer: newer than ask, past 30s debounce
      dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(
        rows: [ answered ],
        dispatch_state: Hive::Daemon::DispatchBaselines.new(path: path)
      )

      dispatcher.tick(now: T0)

      assert_equal 1, sup.spawned.size, "a pre-restart answer must dispatch, not be re-stranded"
      assert events_include?(logger, :dispatched)
    end
  end

  def test_tick_prunes_baselines_for_tasks_absent_from_status
    Dir.mktmpdir do |dir|
      path = File.join(dir, "baselines.json")
      seed_baseline(path, project: "p", slug: "gone", mtime: T0 - 600)
      seed_baseline(path, project: "p", slug: "present", mtime: T0 - 600)

      present = row(project: "p", slug: "present", stage: "2-brainstorm",
                    action: "needs_input",
                    command: "hive brainstorm present --from 2-brainstorm",
                    mtime: T0 - 600) # equal to baseline → :skip, no re-dispatch
      _dispatcher, _sup, ctrl, _logger, _mw = make_dispatcher(
        rows: [ present ],
        dispatch_state: Hive::Daemon::DispatchBaselines.new(path: path)
      )
      _dispatcher.tick(now: T0)

      assert_nil ctrl.last_dispatched_state_file_mtime_for(project: "p", slug: "gone"),
                 "a task absent from the status scan must be pruned from baselines"
      refute_nil ctrl.last_dispatched_state_file_mtime_for(project: "p", slug: "present"),
                 "a task still present must keep its baseline"
    end
  end

  def test_failed_status_fetch_does_not_prune_baselines
    Dir.mktmpdir do |dir|
      path = File.join(dir, "baselines.json")
      seed_baseline(path, project: "p", slug: "keep", mtime: T0 - 600)

      _dispatcher, _sup, ctrl, _logger, _mw = make_dispatcher(
        dispatch_state: Hive::Daemon::DispatchBaselines.new(path: path),
        status_result: Hive::Daemon::StatusConsumer::Result.new(ok: false, rows: [], error: "boom")
      )
      _dispatcher.tick(now: T0)

      refute_nil ctrl.last_dispatched_state_file_mtime_for(project: "p", slug: "keep"),
                 "a transient status failure must NOT wipe persisted baselines"
    end
  end

  # Per-project errors (`not_initialised`, `missing_project_path`) cause
  # `StatusConsumer` to drop a project from BOTH rows AND projects, even
  # though the overall fetch is `ok: true`. Without a scope guard the prune
  # would silently wipe every baseline for that project on the spot — the
  # exact stranding regression. The dispatcher passes `result.projects` as
  # the scope so an errored project keeps its baselines until it reappears.
  def test_per_project_error_does_not_wipe_that_projects_baselines
    Dir.mktmpdir do |dir|
      path = File.join(dir, "baselines.json")
      seed_baseline(path, project: "writero", slug: "answered", mtime: T0 - 600)
      seed_baseline(path, project: "errored", slug: "answered-too", mtime: T0 - 600)

      writero_row = row(project: "writero", slug: "answered", stage: "2-brainstorm",
                        action: "needs_input",
                        command: "hive brainstorm answered --from 2-brainstorm",
                        mtime: T0 - 600)
      # `errored` project is filtered out of rows AND projects by the consumer
      # — mirror that here.
      result = Hive::Daemon::StatusConsumer::Result.new(
        ok: true, rows: [ writero_row ],
        projects: [ Hive::Daemon::StatusConsumer::ProjectInfo.new(name: "writero", legacy_stage_dirs: []) ],
        error: nil
      )
      _dispatcher, _sup, ctrl, _logger, _mw = make_dispatcher(
        dispatch_state: Hive::Daemon::DispatchBaselines.new(path: path),
        status_result: result
      )
      _dispatcher.tick(now: T0)

      assert_equal T0 - 600,
                   ctrl.last_dispatched_state_file_mtime_for(project: "errored", slug: "answered-too"),
                   "a project absent from result.projects (per-project error) must NOT have its baselines pruned"
      # Sanity: writero/answered's baseline is still there too (mtime == baseline → :skip).
      assert_equal T0 - 600,
                   ctrl.last_dispatched_state_file_mtime_for(project: "writero", slug: "answered")
    end
  end

  # ── dispatch-request queue integration ───────────────────────────────

  Q = Hive::Daemon::DispatchRequestQueue

  def write_request_file(dir, slug:, request_id:, created_at: T0, argv: nil, project: "p1",
                         trigger: "answer_complete")
    argv ||= [ "hive", "run", slug, "--json" ]
    path = File.join(Q.directory(state_home: dir), Q.filename_for(created_at: created_at, request_id: request_id))
    payload = {
      "schema" => "hive-dispatch-request",
      "schema_version" => 1,
      "request_id" => request_id,
      "created_at" => created_at.utc.iso8601,
      "project" => project,
      "slug" => slug,
      "argv" => argv,
      "requestor" => "bot",
      "chat_id" => 42,
      "update_id" => 99,
      "trigger" => trigger
    }
    File.write(path, JSON.generate(payload))
    path
  end

  def stub_find_project!(dispatcher, project_name)
    Hive::Config.singleton_class.alias_method(:__orig_find_project, :find_project) unless Hive::Config.singleton_class.method_defined?(:__orig_find_project)
    Hive::Config.define_singleton_method(:find_project) do |name|
      name == project_name ? { "name" => project_name, "path" => "/tmp/nonexistent", "hive_state_path" => "/tmp/nonexistent/.hive-state" } : nil
    end
    dispatcher
  end

  def restore_find_project!
    if Hive::Config.singleton_class.method_defined?(:__orig_find_project)
      Hive::Config.define_singleton_method(:find_project, Hive::Config.method(:__orig_find_project))
    end
  end

  def test_dispatch_request_observed_logged_and_dispatched
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home
      )
      write_request_file(state_home, slug: "s1", request_id: "R1")
      stub_find_project!(dispatcher, "p1")
      begin
        dispatcher.tick(now: T0)

        observed = logger.events.find { |(n, _)| n == :dispatch_request_observed }
        dispatched = logger.events.find { |(n, _)| n == :dispatch_request_dispatched }
        refute_nil observed
        refute_nil dispatched
        assert_equal "R1", observed[1][:request_id]
        assert_equal 1, sup.spawned.size
        assert_equal "hive run s1 --json", sup.spawned.first[:command]
        assert_equal "R1", sup.spawned.first[:request_id]
      ensure
        restore_find_project!
      end
    end
  end

  def test_dispatch_request_rejected_when_argv_not_allowlisted
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home
      )
      write_request_file(state_home, slug: "s1", request_id: "BAD",
                         argv: [ "hive", "doctor" ])
      stub_find_project!(dispatcher, "p1")
      begin
        dispatcher.tick(now: T0)

        rejected = logger.events.find { |(n, attrs)| n == :dispatch_request_rejected && attrs[:request_id] == "BAD" }
        refute_nil rejected
        assert_equal "invalid_argv", rejected[1][:reason]
        assert_empty sup.spawned
        assert_empty Dir.glob(File.join(Q.directory(state_home: state_home), "*.json"))
      ensure
        restore_find_project!
      end
    end
  end

  def test_dispatch_request_rejected_when_project_unknown
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home
      )
      write_request_file(state_home, slug: "s1", request_id: "RX", project: "unknown-proj")
      # No stub for find_project ⇒ returns nil
      Hive::Config.singleton_class.alias_method(:__orig_find_project, :find_project) unless Hive::Config.singleton_class.method_defined?(:__orig_find_project)
      Hive::Config.define_singleton_method(:find_project) { |_| nil }
      begin
        dispatcher.tick(now: T0)

        rejected = logger.events.find { |(n, attrs)| n == :dispatch_request_rejected && attrs[:request_id] == "RX" }
        refute_nil rejected
        assert_equal "unknown_project", rejected[1][:reason]
        assert_empty sup.spawned
      ensure
        restore_find_project!
      end
    end
  end

  def test_dispatch_request_blocked_when_in_flight_for_same_slug
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, ctrl, logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home
      )
      # Pre-seed an in-flight slot for (p1, s1)
      ctrl.record_dispatch(pid: 7777, project: "p1", slug: "s1", stage: nil,
                           command: "hive run s1", started_at: T0,
                           state_file_mtime: nil)
      write_request_file(state_home, slug: "s1", request_id: "DEF")
      stub_find_project!(dispatcher, "p1")
      begin
        dispatcher.tick(now: T0)

        blocked = logger.events.find { |(n, _)| n == :dispatch_request_blocked }
        refute_nil blocked
        assert_equal "in_flight", blocked[1][:reason]
        # The request file MUST remain on disk for the next tick.
        files = Dir.glob(File.join(Q.directory(state_home: state_home), "*.json"))
        assert_equal 1, files.size
        # Sup must NOT have spawned this request (only the pre-seeded slot exists).
        assert_empty sup.spawned
      ensure
        restore_find_project!
      end
    end
  end

  def test_dispatch_request_expired_removed_without_dispatch
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home
      )
      # Created 11 minutes before "now"
      ancient = T0 - (11 * 60)
      write_request_file(state_home, slug: "s1", request_id: "OLD", created_at: ancient)
      stub_find_project!(dispatcher, "p1")
      begin
        dispatcher.tick(now: T0)

        expired = logger.events.find { |(n, _)| n == :dispatch_request_expired }
        refute_nil expired, "a 11-min-old request must be reaped before dispatch"
        assert_empty sup.spawned
        files = Dir.glob(File.join(Q.directory(state_home: state_home), "*.json"))
        assert_empty files, "expired requests must be unlinked from the queue dir"
      ensure
        restore_find_project!
      end
    end
  end

  def test_per_slug_in_flight_gate_within_one_tick_blocks_same_slug_row_dispatch
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      # A row exists for the same slug as the queued request. The
      # request scan fires first and `record_dispatch`'s the controller.
      # When the row scan later sees the same slug, `dispatch_or_block`
      # must consult the controller and refuse rather than spawn a
      # second child against the same task.
      row_for_same_slug = row(slug: "s1", action: "ready_to_plan",
                              command: "hive plan s1 --from 2-brainstorm")
      dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(
        rows: [ row_for_same_slug ], dispatch_request_state_home: state_home
      )
      write_request_file(state_home, slug: "s1", request_id: "FIRST")
      stub_find_project!(dispatcher, "p1")
      begin
        dispatcher.tick(now: T0)

        # Exactly one spawn — for the request — not two.
        assert_equal 1, sup.spawned.size,
                     "per-slug in-flight gate must keep the row scan from double-spawning"
        assert_equal "FIRST", sup.spawned.first[:request_id]
        blocked = logger.events.find { |(n, attrs)| n == :blocked && attrs[:reason] == "in_flight" }
        refute_nil blocked, "row scan must log :blocked reason=in_flight when slug is already running"
      ensure
        restore_find_project!
      end
    end
  end

  def test_dispatch_request_completed_logs_on_child_reap
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home
      )
      write_request_file(state_home, slug: "s1", request_id: "REQ-X")
      stub_find_project!(dispatcher, "p1")
      begin
        dispatcher.tick(now: T0)
        spawned_pid = sup.spawned.first[:pid]
        sup.define_singleton_method(:reap_all) do |now: Time.now|
          [
            ChildExit.new(
              pid: spawned_pid, exit_code: 0, project: "p1", slug: "s1", stage: nil,
              command: "hive run s1 --json", state_file_path: nil,
              started_at: T0, finished_at: now, json_envelope: nil,
              request_id: "REQ-X"
            )
          ]
        end

        dispatcher.tick(now: T0 + 60)

        completed = logger.events.find { |(n, _)| n == :dispatch_request_completed }
        refute_nil completed
        assert_equal "REQ-X", completed[1][:request_id]
        # The file MUST have been unlinked.
        files = Dir.glob(File.join(Q.directory(state_home: state_home), "*.json"))
        assert_empty files
      ensure
        restore_find_project!
      end
    end
  end

  private

  def events_include?(logger, name)
    logger.events.any? { |(n, _)| n == name }
  end

  def seed_baseline(path, project:, slug:, mtime:)
    Hive::Daemon::ConcurrencyController.new(
      max_concurrent_runs: 5, max_concurrent_per_project: 5,
      max_runs_per_day_per_project: 100,
      dispatch_state: Hive::Daemon::DispatchBaselines.new(path: path)
    ).observe_state_file_mtime(project: project, slug: slug, mtime: mtime)
  end
end
