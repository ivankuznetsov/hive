require "test_helper"
require "hive/daemon/dispatcher"
require "hive/daemon/concurrency_controller"
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
              hive_state_path: nil, state_file_path: nil, dry_run: nil)
      pid = @next_pid
      @next_pid += 1
      @spawned << {
        pid: pid, command: command_string, project: project, slug: slug,
        stage: stage, state_file_path: state_file_path, dry_run: dry_run
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
    attr_accessor :next_archives
    def initialize
      @enqueued = []
      @next_archives = []
    end

    def enqueue(project:, slug:, task_folder:)
      @enqueued << { project: project, slug: slug, task_folder: task_folder }
    end

    def tick(now:)
      out = @next_archives
      @next_archives = []
      out
    end
  end

  # ── construction helpers ───────────────────────────────────────────────

  def make_dispatcher(rows: [], dry_run: false, with_merge_watcher: false,
                      project_enabled: true)
    config = {
      "daemon" => {
        "edit_debounce_sec" => 30,
        "poll_interval_sec" => 30,
        "shutdown_grace_sec" => 60
      }
    }
    controller = Hive::Daemon::ConcurrencyController.new(
      max_concurrent_runs: 5, max_concurrent_per_project: 5,
      max_runs_per_day_per_project: 100
    )
    supervisor = FakeSupervisor.new
    status = FakeStatusConsumer.new
    status.next_result = Hive::Daemon::StatusConsumer::Result.new(ok: true, rows: rows, error: nil)
    logger = StubLogger.new
    merge_watcher = with_merge_watcher ? FakeMergeWatcher.new : nil

    dispatcher = Hive::Daemon::Dispatcher.new(
      config: config,
      controller: controller,
      supervisor: supervisor,
      status_consumer: status,
      logger: logger,
      merge_watcher: merge_watcher,
      dry_run: dry_run
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
          mtime: T0 - 600)
    Row.new(
      project: project, slug: slug, stage: stage, marker: marker,
      folder: "/tmp/#{project}/#{stage}/#{slug}",
      state_file: "/tmp/#{project}/#{stage}/#{slug}/idea.md",
      state_file_mtime: mtime, action: action,
      suggested_command: command, claude_pid_alive: nil
    )
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

  def test_disabled_project_is_skipped
    rows = [ row(action: "ready_to_plan", command: "hive plan s1 --from 2-brainstorm") ]
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows, project_enabled: false)
    dispatcher.tick(now: T0)
    assert_equal 0, sup.spawned.size
    refute events_include?(logger, :dispatched)
  end

  def test_recover_stale_action_is_skipped_with_log
    rows = [ row(action: "recover_review", marker: "review_error", stage: "5-review",
                 command: nil) ]
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows)
    dispatcher.tick(now: T0)
    assert_equal 0, sup.spawned.size
    skipped = logger.events.find { |(n, _)| n == :skipped }
    refute_nil skipped, "recover_stale row must produce a :skipped event"
  end

  def test_archive_action_routes_to_merge_watcher
    rows = [ row(stage: "6-pr", action: "ready_to_archive",
                 command: "hive archive s1 --from 6-pr") ]
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
      project: "p1", slug: "s1", stage: "6-pr",
      command: "hive archive s1 --from 6-pr --project p1 --json",
      state_file_mtime: nil, hive_state_path: nil
    } ]
    dispatcher.tick(now: T0)
    assert_equal 1, sup.spawned.size
    assert_equal "hive archive s1 --from 6-pr --project p1 --json", sup.spawned.first[:command]
  end

  def test_merged_pr_archive_skips_when_project_disabled_after_enqueue
    # PR-40 review P2 #4: a project disabled between merge-watch
    # enqueue and the merge-completion tick must NOT be archived.
    dispatcher, sup, _ctrl, logger, mw = make_dispatcher(
      rows: [], with_merge_watcher: true, project_enabled: false
    )
    mw.next_archives = [ {
      project: "p1", slug: "s1", stage: "6-pr",
      command: "hive archive s1 --from 6-pr --project p1 --json",
      state_file_mtime: nil, hive_state_path: nil
    } ]
    dispatcher.tick(now: T0)
    assert_equal 0, sup.spawned.size
    skipped = logger.events.find { |(n, a)| n == :skipped && a[:reason] == "project_disabled_after_enqueue" }
    refute_nil skipped, "must log :skipped reason: project_disabled_after_enqueue"
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
      stage: "5-review", command: "hive run", started_at: T0,
      state_file_mtime: T0 - 60
    )

    mw.next_archives = [ {
      project: "p1", slug: "s1", stage: "6-pr",
      command: "hive archive s1 --from 6-pr --project p1 --json",
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
                      stage: "5-review", command: "hive run s1",
                      started_at: T0, finished_at: now, json_envelope: nil) ]
    end
    status = FakeStatusConsumer.new
    logger = StubLogger.new

    # Pre-record the dispatch so the controller has something to clear
    controller.record_dispatch(pid: 999, project: "p1", slug: "s1",
                               stage: "5-review", command: "hive run s1",
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
                      slug: "s1", stage: "5-review", command: "hive run s1",
                      started_at: Time.now, finished_at: now, json_envelope: nil) ]
    end
    controller.record_dispatch(pid: 999, project: "p1", slug: "s1",
                               stage: "5-review", command: "hive run s1",
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

  private

  def events_include?(logger, name)
    logger.events.any? { |(n, _)| n == name }
  end
end
