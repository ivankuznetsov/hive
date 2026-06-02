require "test_helper"
require "json"
require "fileutils"
require "tmpdir"
require "hive/daemon/dispatcher"
require "hive/daemon/concurrency_controller"
require "hive/daemon/dispatch_request_queue"
require "hive/bot/dispatch_request_writer"

# Regression test for the 2026-05-28 redundant-redispatch bug.
#
# Plan 2026-05-28-002 Problem section: when the bot dispatched
# `hive run` directly, the daemon's `last_dispatched_mtime` stayed
# stale because the bot — not the daemon — owned the child. The
# agent's own write to brainstorm.md looked like a "new user edit"
# on the next tick, so the daemon dispatched a SECOND runner that
# held the task lock for 1-2 min while the bot rejected legitimate
# user answers with "Try again - another run holds the lock".
#
# Smoking gun in the original incident:
#
#   18:13:14  debouncing   mtime=18:13:09     ← agent's write
#   18:13:44  dispatched   trigger=advance    ← redundant daemon redispatch
#
# This test replays that exact sequence against the post-fix code
# path. The acceptance criterion (plan §"Acceptance" item 3): "no
# redundant redispatch within 60s of a bot-driven `hive run`."
class HiveRegressionRedundantRedispatchTest < Minitest::Test
  include HiveTestHelper

  Row = Hive::Daemon::StatusConsumer::Row
  ProjectInfo = Hive::Daemon::StatusConsumer::ProjectInfo
  ChildExit = Hive::Daemon::ChildSupervisor::ChildExit

  # T0 == the 18:13 incident's relative t=0.
  T_BOT_ANSWER = Time.utc(2026, 5, 28, 18, 13, 4)  # bot finishes writing Q10's answer
  T_AGENT_WRITE = Time.utc(2026, 5, 28, 18, 13, 9) # agent's write to brainstorm.md
  T_FIRST_TICK = Time.utc(2026, 5, 28, 18, 13, 14) # daemon picks up the request
  T_REAP_TICK = Time.utc(2026, 5, 28, 18, 13, 30)  # child exits, daemon reaps
  T_NEXT_TICK = Time.utc(2026, 5, 28, 18, 13, 44)  # 30s later — the redundant-redispatch tick

  class FakeStatusConsumer
    attr_accessor :result
    def fetch
      @result || Hive::Daemon::StatusConsumer::Result.new(ok: true, rows: [], projects: [], error: nil)
    end
  end

  class FakeSupervisor
    attr_reader :spawned
    attr_accessor :reap_queue
    def initialize
      @spawned = []
      @next_pid = 5000
      @reap_queue = []
    end

    def spawn(command_string:, project:, slug:, stage:,
              hive_state_path: nil, state_file_path: nil, dry_run: nil, request_id: nil)
      pid = @next_pid
      @next_pid += 1
      @spawned << { pid: pid, command: command_string, slug: slug,
                    request_id: request_id, state_file_path: state_file_path,
                    spawned_at_tick: @current_tick }
      pid
    end

    def reap_all(now: Time.now)
      @current_tick = now
      out = @reap_queue
      @reap_queue = []
      out
    end

    def reap_dry_run(now: Time.now) = []
    def terminate_all(grace_sec: 600); end
    def in_flight_count = @spawned.size
  end

  class StubLogger
    attr_reader :events
    def initialize
      @events = []
    end

    def event(name, **attrs)
      @events << [ name, attrs ]
    end

    def close; end
  end

  def setup
    @state_home = Dir.mktmpdir("hive-regression-state")
    @project = "hive"
    @slug = "explore-the-simplest-way-to-260528-2503"
    @hive_state_path = File.join(@state_home, "project_state")
    @stage_dir = File.join(@hive_state_path, "stages", "2-brainstorm", @slug)
    FileUtils.mkdir_p(@stage_dir)
    @brainstorm_path = File.join(@stage_dir, "brainstorm.md")
    File.write(@brainstorm_path, "## Round 1\n\n<!-- WAITING -->\n")
    # Pre-set the brainstorm.md mtime to T_BOT_ANSWER (the answer write
    # bumped it before the agent's tick).
    File.utime(T_BOT_ANSWER, T_BOT_ANSWER, @brainstorm_path)

    @supervisor = FakeSupervisor.new
    @status_consumer = FakeStatusConsumer.new
    @logger = StubLogger.new
    @controller = Hive::Daemon::ConcurrencyController.new(
      max_concurrent_runs: 5, max_concurrent_per_project: 5,
      max_runs_per_day_per_project: 100
    )
    @dispatcher = Hive::Daemon::Dispatcher.new(
      config: { "daemon" => { "edit_debounce_sec" => 30, "poll_interval_sec" => 30 } },
      controller: @controller, supervisor: @supervisor,
      status_consumer: @status_consumer, logger: @logger,
      dispatch_request_state_home: @state_home
    )
    @dispatcher.define_singleton_method(:project_enabled?) { |_| true }
    @original_find_project = Hive::Config.method(:find_project)
    project = @project
    state_home = @state_home
    hive_state = @hive_state_path
    Hive::Config.define_singleton_method(:find_project) do |name|
      next nil unless name == project

      { "name" => project, "path" => state_home, "hive_state_path" => hive_state }
    end
  end

  def teardown
    FileUtils.remove_entry(@state_home) if @state_home && File.exist?(@state_home)
    Hive::Config.define_singleton_method(:find_project, @original_find_project) if @original_find_project
  end

  def needs_input_row(mtime:)
    Row.new(
      project: @project, slug: @slug, stage: "2-brainstorm",
      marker: "waiting", folder: @stage_dir,
      state_file: @brainstorm_path, state_file_mtime: mtime,
      action: "needs_input", suggested_command: "hive run #{@slug}",
      claude_pid_alive: nil, live_task_lock: nil
    )
  end

  def set_status_rows(rows)
    @status_consumer.result = Hive::Daemon::StatusConsumer::Result.new(
      ok: true,
      rows: rows,
      projects: [ ProjectInfo.new(name: @project, legacy_stage_dirs: []) ],
      error: nil
    )
  end

  def test_no_redundant_redispatch_within_60s_of_bot_driven_hive_run
    # Replay the exact 2026-05-28 18:13 sequence:
    #
    # 1. T_BOT_ANSWER: bot finishes writing Q10's answer and ENQUEUES
    #    a `hive run` request (post-refactor). The brainstorm.md
    #    mtime is at T_BOT_ANSWER (the answer write).
    request_id = Hive::Bot::DispatchRequestWriter.write!(
      project: @project, slug: @slug,
      argv: [ "hive", "run", @slug, "--json" ],
      chat_id: 12345, update_id: 926_850_952, trigger: "answer_complete",
      state_home: @state_home, now: T_BOT_ANSWER
    )

    # 2. T_FIRST_TICK (18:13:14): daemon's first tick picks up the
    #    request and spawns. record_dispatch seeds the baseline to
    #    T_BOT_ANSWER (the mtime at dispatch time).
    set_status_rows([ needs_input_row(mtime: T_BOT_ANSWER) ])
    @dispatcher.tick(now: T_FIRST_TICK)

    assert_equal 1, @supervisor.spawned.size, "tick 1 dispatches the queued request"
    assert_equal request_id, @supervisor.spawned.first[:request_id]

    # 3. T_AGENT_WRITE (18:13:09 — note: in real-world the agent's
    #    write happened BEFORE the daemon's tick. Either order is
    #    fine for the regression because the post-completion mtime
    #    refresh covers both). Simulate the agent's write by
    #    bumping the brainstorm.md mtime past T_BOT_ANSWER.
    agent_write_mtime = T_AGENT_WRITE
    File.utime(agent_write_mtime, agent_write_mtime, @brainstorm_path)

    # 4. T_REAP_TICK (18:13:30): child exits. The daemon's reap
    #    refreshes the baseline to the brainstorm.md's CURRENT mtime
    #    (the agent's last write, post-completion).
    pid = @supervisor.spawned.first[:pid]
    @supervisor.reap_queue = [
      ChildExit.new(
        pid: pid, exit_code: 0, project: @project, slug: @slug, stage: nil,
        command: "hive run #{@slug} --json", state_file_path: @brainstorm_path,
        started_at: T_FIRST_TICK, finished_at: T_REAP_TICK, json_envelope: nil,
        request_id: request_id
      )
    ]
    # Status now reports the row with the agent's write mtime — the
    # debounce window has elapsed (>30s since T_AGENT_WRITE).
    set_status_rows([ needs_input_row(mtime: agent_write_mtime) ])
    @dispatcher.tick(now: T_REAP_TICK)

    completed = @logger.events.find { |(n, _)| n == :dispatch_request_completed }
    refute_nil completed, "reap must log :dispatch_request_completed"
    baseline_after_reap = @controller.last_dispatched_state_file_mtime_for(
      project: @project, slug: @slug
    )
    assert_equal agent_write_mtime.to_i, baseline_after_reap.to_i,
                 "post-completion refresh must seed the baseline to the agent's last write — " \
                 "the very property whose absence caused the 18:13 redundant redispatch"

    # 5. T_NEXT_TICK (18:13:44 — exactly 30s after T_FIRST_TICK):
    #    THE bug-tick. Pre-fix, this was when the daemon dispatched
    #    `trigger=advance` against a stale baseline. Post-fix, the
    #    row mtime equals the baseline → Policy returns :skip → no
    #    redundant spawn.
    set_status_rows([ needs_input_row(mtime: agent_write_mtime) ])
    @dispatcher.tick(now: T_NEXT_TICK)

    spawn_count_after_bug_window = @supervisor.spawned.size
    assert_equal 1, spawn_count_after_bug_window,
                 "ACCEPTANCE CRITERION: no redundant redispatch within 60s of a " \
                 "bot-driven `hive run`. Only the original request must have spawned."

    # The daemon.log must show NO :dispatched event for trigger=advance
    # within the 18:13 window — the regression's smoking gun.
    bug_dispatches = @logger.events.select do |(n, attrs)|
      n == :dispatched &&
        attrs[:trigger] == "advance" &&
        attrs[:slug] == @slug
    end
    assert_empty bug_dispatches,
                 "the daemon must NOT have logged an :advance dispatch — " \
                 "any such event is the original bug"

    # The :skipped event for the row scan must record either
    # baseline_recorded or no skip at all (mtime == baseline yields
    # Policy :skip), confirming the gate is the post-completion
    # baseline refresh.
    # The events.jsonl evidence trail:
    observed = @logger.events.count { |(n, _)| n == :dispatch_request_observed }
    dispatched_via_request = @logger.events.count { |(n, _)| n == :dispatch_request_dispatched }
    completed_via_request = @logger.events.count { |(n, _)| n == :dispatch_request_completed }
    assert_equal 1, observed, "exactly one :dispatch_request_observed event"
    assert_equal 1, dispatched_via_request,
                 "exactly one :dispatch_request_dispatched event — no shadow second dispatch"
    assert_equal 1, completed_via_request, "exactly one :dispatch_request_completed event"
  end
end
