require "test_helper"
require "json"
require "fileutils"
require "tmpdir"
require "hive/daemon/dispatcher"
require "hive/daemon/concurrency_controller"
require "hive/daemon/dispatch_request_queue"
require "hive/bot/dispatch_request_writer"

# Plan 2026-05-28-002 §"Tests":
#   "Bot writes a request → daemon picks up → child runs → controller
#    baseline updated → no redundant redispatch on next tick."
#
# Drives the real `Hive::Daemon::Dispatcher#tick` with a real
# `Hive::Daemon::ConcurrencyController` and a real
# `Hive::Daemon::DispatchRequestQueue`. The only fakes are
# StatusConsumer (so we don't shell out to `hive status`) and
# ChildSupervisor (so we control the spawn/reap timing
# deterministically). The bot side is the production
# `DispatchRequestWriter`.
class HiveDispatchRequestRoundtripTest < Minitest::Test
  include HiveTestHelper

  Row = Hive::Daemon::StatusConsumer::Row
  ProjectInfo = Hive::Daemon::StatusConsumer::ProjectInfo
  ChildExit = Hive::Daemon::ChildSupervisor::ChildExit

  T0 = Time.utc(2026, 5, 28, 18, 10, 0)

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
      @next_pid = 1000
      @reap_queue = []
    end

    def spawn(command_string:, project:, slug:, stage:,
              hive_state_path: nil, state_file_path: nil, dry_run: nil, request_id: nil)
      pid = @next_pid
      @next_pid += 1
      @spawned << {
        pid: pid, command: command_string, project: project, slug: slug,
        request_id: request_id, state_file_path: state_file_path
      }
      pid
    end

    def reap_all(now: Time.now)
      out = @reap_queue
      @reap_queue = []
      out
    end

    def reap_dry_run(now: Time.now)
      []
    end

    def terminate_all(grace_sec: 600); end

    def enforce_timeouts(now:) = [] # #252: dispatcher calls this each tick

    def in_flight_count
      @spawned.size
    end
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
    @state_home = Dir.mktmpdir("hive-roundtrip-state")
    @project = "hive"
    @slug = "test-roundtrip-260528-aaaa"
    @hive_state_path = File.join(@state_home, "project_state")
    @stage_dir = File.join(@hive_state_path, "stages", "2-brainstorm", @slug)
    FileUtils.mkdir_p(@stage_dir)
    @brainstorm_path = File.join(@stage_dir, "brainstorm.md")
    File.write(@brainstorm_path, "## Round 1\n\n<!-- WAITING -->\n")

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
    stub_find_project!
  end

  def teardown
    FileUtils.remove_entry(@state_home) if @state_home && File.exist?(@state_home)
    restore_find_project!
  end

  def stub_find_project!
    @original_find_project = Hive::Config.method(:find_project)
    state_home = @state_home
    project = @project
    hive_state = @hive_state_path
    Hive::Config.define_singleton_method(:find_project) do |name|
      next nil unless name == project

      { "name" => project, "path" => state_home, "hive_state_path" => hive_state }
    end
  end

  def restore_find_project!
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

  # ── ROUNDTRIP: bot writes → daemon picks up → child runs → no
  # redundant redispatch on the next tick ────────────────────────────
  def test_bot_request_picked_up_and_no_redundant_redispatch
    # 1. Bot writes the request file.
    request_id = Hive::Bot::DispatchRequestWriter.write!(
      project: @project, slug: @slug,
      argv: [ "hive", "run", @slug, "--json" ],
      chat_id: 12345, update_id: 1, trigger: "answer_complete",
      state_home: @state_home, now: T0
    )

    # 2. Daemon tick 1. Picks up the request and spawns.
    @dispatcher.tick(now: T0 + 1)

    assert_equal 1, @supervisor.spawned.size, "daemon must pick up the request and spawn exactly once"
    assert_equal request_id, @supervisor.spawned.first[:request_id],
                 "the spawn must carry the request_id for reap-time unlink"
    # C3: the file stays on disk until reap, but is CLAIMED (renamed to
    # *.json.claimed) so a later tick never re-observes it.
    assert_empty Dir.glob(File.join(@state_home, "dispatch_requests", "*.json")),
                 "the pending .json must be renamed away once dispatched (claimed)"
    refute_empty Dir.glob(File.join(@state_home, "dispatch_requests", "*.json.claimed")),
                 "the claimed request file stays on disk until the child reaps"

    # 3. The child writes a fresh marker; brainstorm.md mtime bumps.
    new_mtime = T0 + 30
    File.utime(new_mtime, new_mtime, @brainstorm_path)

    # 4. Child completes. Reap arrives. The daemon's reap path must
    #    refresh the controller's baseline mtime AND unlink the
    #    request file.
    pid = @supervisor.spawned.first[:pid]
    @supervisor.reap_queue = [
      ChildExit.new(
        pid: pid, exit_code: 0, project: @project, slug: @slug, stage: nil,
        command: "hive run #{@slug} --json", state_file_path: @brainstorm_path,
        started_at: T0, finished_at: T0 + 90, json_envelope: nil,
        request_id: request_id
      )
    ]

    # 5. Tick 2: status now shows the row as needs_input with the NEW
    #    mtime (the agent's own write). If the baseline was stale,
    #    Policy.decide_edit would return :dispatch and the daemon
    #    would re-spawn. The post-completion mtime refresh prevents
    #    that.
    set_status_rows([ needs_input_row(mtime: new_mtime) ])
    @dispatcher.tick(now: T0 + 90)

    # The reap must have:
    #   - unlinked the request file
    #   - logged :dispatch_request_completed
    #   - refreshed the controller's baseline to the new mtime
    assert_empty Dir.glob(File.join(@state_home, "dispatch_requests", "*")),
                 "the claimed request file must be unlinked on reap (no pending or claimed left)"
    completed = @logger.events.find { |(n, _)| n == :dispatch_request_completed }
    refute_nil completed
    baseline = @controller.last_dispatched_state_file_mtime_for(project: @project, slug: @slug)
    assert_equal new_mtime.to_i, baseline.to_i,
                 "post-completion mtime refresh must seed the baseline to the agent's own write"

    # 6. Tick 3 (well past the debounce window): the row's mtime
    #    equals the baseline → Policy.decide_edit returns :skip → no
    #    redundant spawn. This is the regression we're fixing.
    set_status_rows([ needs_input_row(mtime: new_mtime) ])
    @dispatcher.tick(now: T0 + 180)

    assert_equal 1, @supervisor.spawned.size,
                 "after baseline refresh, the next tick must NOT re-dispatch — single-dispatcher invariant holds"
  end
end
