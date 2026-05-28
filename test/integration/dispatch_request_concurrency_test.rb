require "test_helper"
require "json"
require "fileutils"
require "tmpdir"
require "hive/daemon/dispatcher"
require "hive/daemon/concurrency_controller"
require "hive/daemon/dispatch_request_queue"
require "hive/bot/dispatch_request_writer"

# Plan 2026-05-28-002 §"Tests":
#   "Two requests for same slug → second blocked until first reaps.
#    Request blocked by per-slug quarantine → not dispatched, file
#    stays for retry."
class HiveDispatchRequestConcurrencyTest < Minitest::Test
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
      @next_pid = 2000
      @reap_queue = []
    end

    def spawn(command_string:, project:, slug:, stage:,
              hive_state_path: nil, state_file_path: nil, dry_run: nil, request_id: nil)
      pid = @next_pid
      @next_pid += 1
      @spawned << { pid: pid, command: command_string, slug: slug, request_id: request_id }
      pid
    end

    def reap_all(now: Time.now)
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
    @state_home = Dir.mktmpdir("hive-concurrency-state")
    @project = "hive"
    @slug = "concurrent-260528-aaaa"
    @hive_state_path = File.join(@state_home, "project_state")
    FileUtils.mkdir_p(File.join(@hive_state_path, "stages", "2-brainstorm", @slug))

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

  def queue_files
    Dir.glob(File.join(@state_home, "dispatch_requests", "*.json")).sort
  end

  def test_two_requests_for_same_slug_serialise_by_per_slug_gate
    request_a = Hive::Bot::DispatchRequestWriter.write!(
      project: @project, slug: @slug,
      argv: [ "hive", "run", @slug, "--json" ],
      trigger: "answer_complete",
      state_home: @state_home, now: T0
    )
    # Same slug, different argv (the second request would dispatch
    # the retry verb if the first hadn't claimed the in-flight slot).
    request_b = Hive::Bot::DispatchRequestWriter.write!(
      project: @project, slug: @slug,
      argv: [ "hive", "markers", "clear", @slug, "--name", "ERROR" ],
      trigger: "autofix",
      state_home: @state_home, now: T0 + 1
    )

    @dispatcher.tick(now: T0 + 2)

    assert_equal 1, @supervisor.spawned.size,
                 "exactly one of the two same-slug requests must dispatch this tick"
    assert_equal request_a, @supervisor.spawned.first[:request_id],
                 "the earlier-created request must win the in-flight slot"

    blocked = @logger.events.find { |(n, attrs)|
      n == :dispatch_request_blocked && attrs[:request_id] == request_b
    }
    refute_nil blocked, "the second same-slug request must log :dispatch_request_blocked"
    assert_equal "in_flight", blocked[1][:reason]

    # The deferred request's file must remain on disk for the next tick.
    remaining_ids = queue_files.map { |path| JSON.parse(File.read(path))["request_id"] }
    assert_includes remaining_ids, request_b

    # Reap the first child. record_completion uses the tick's `now`
    # for completed_at, so the SUCCESS_COOLDOWN_SEC (60) extends past
    # this tick. We need TWO subsequent ticks: one to reap and start
    # the cooldown, a later one (past cooldown_until) to dispatch B.
    pid_a = @supervisor.spawned.first[:pid]
    @supervisor.reap_queue = [
      ChildExit.new(
        pid: pid_a, exit_code: 0, project: @project, slug: @slug, stage: nil,
        command: "hive run #{@slug} --json", state_file_path: nil,
        started_at: T0, finished_at: T0 + 60, json_envelope: nil,
        request_id: request_a
      )
    ]
    @dispatcher.tick(now: T0 + 120) # reap, set cooldown_until = T0 + 180
    assert_equal 1, @supervisor.spawned.size,
                 "tick 2 reaps but cooldown blocks the deferred request"

    @dispatcher.tick(now: T0 + 200) # cooldown cleared
    assert_equal 2, @supervisor.spawned.size,
                 "after cooldown clears, the third tick must dispatch the deferred request"
    assert_equal request_b, @supervisor.spawned.last[:request_id]
  end

  def test_quarantined_slug_request_stays_on_disk_for_retry
    @controller.instance_variable_get(:@quarantine).add([ @project, @slug ])

    request_id = Hive::Bot::DispatchRequestWriter.write!(
      project: @project, slug: @slug,
      argv: [ "hive", "run", @slug, "--json" ],
      state_home: @state_home, now: T0
    )

    @dispatcher.tick(now: T0 + 1)

    assert_empty @supervisor.spawned, "a quarantined slug must not dispatch"
    blocked = @logger.events.find { |(n, attrs)|
      n == :dispatch_request_blocked && attrs[:request_id] == request_id
    }
    refute_nil blocked, "the quarantined request must log :dispatch_request_blocked"
    assert_equal "quarantined", blocked[1][:reason]
    refute_empty queue_files, "blocked-by-quarantine requests stay on disk for a later tick"
  end
end
