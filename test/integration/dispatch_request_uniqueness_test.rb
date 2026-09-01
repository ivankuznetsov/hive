require "test_helper"
require "json"
require "fileutils"
require "tmpdir"
require "hive/daemon/dispatcher"
require "hive/daemon/concurrency_controller"
require "hive/runtime_control_plane/dispatch_repository"
require "hive/bot/dispatch_request_writer"

# Plan 2026-05-28-002 §"Tests":
#   "10-min expiry: a request older than the threshold is removed
#    without dispatch."
class HiveDispatchRequestUniquenessTest < Minitest::Test
  include HiveTestHelper

  Row = Hive::Daemon::StatusConsumer::Row

  T0 = Time.utc(2026, 5, 28, 18, 0, 0)

  class FakeStatusConsumer
    def fetch
      Hive::Daemon::StatusConsumer::Result.new(ok: true, rows: [], projects: [], error: nil)
    end
  end

  class FakeSupervisor
    attr_reader :spawned
    def initialize
      @spawned = []
    end

    def spawn(**kwargs)
      @spawned << kwargs
      1234
    end

    def reap_all(now: Time.now) = []
    def reap_dry_run(now: Time.now) = []
    def terminate_all(grace_sec: 600); end
    def enforce_timeouts(now:) = [] # #252: dispatcher calls this each tick
    def in_flight_count = 0
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
    @state_home = Dir.mktmpdir("hive-uniqueness-state")
    @project = "hive"
    @slug = "stale-260528-aaaa"
    prepare_runtime_project(state_home: @state_home, name: @project)
    @supervisor = FakeSupervisor.new
    @logger = StubLogger.new
    @controller = Hive::Daemon::ConcurrencyController.new(
      max_concurrent_runs: 5, max_concurrent_per_project: 5,
      max_runs_per_day_per_project: 100
    )
    @dispatcher = Hive::Daemon::Dispatcher.new(
      config: { "daemon" => { "edit_debounce_sec" => 30, "poll_interval_sec" => 30 } },
      controller: @controller, supervisor: @supervisor,
      status_consumer: FakeStatusConsumer.new, logger: @logger,
      dispatch_request_state_home: @state_home
    )
    @dispatcher.define_singleton_method(:project_enabled?) { |_| true }
    @original_find_project = Hive::Config.method(:find_project)
    @original_registered_projects = Hive::Config.method(:registered_projects)
    project = @project
    state_home = @state_home
    project_entry = {
      "name" => project, "path" => state_home, "hive_state_path" => state_home
    }
    Hive::Config.define_singleton_method(:find_project) do |name|
      name == project ? project_entry : nil
    end
    Hive::Config.define_singleton_method(:registered_projects) { [ project_entry ] }
  end

  def teardown
    FileUtils.remove_entry(@state_home) if @state_home && File.exist?(@state_home)
    Hive::Config.define_singleton_method(:find_project, @original_find_project) if @original_find_project
    if @original_registered_projects
      Hive::Config.define_singleton_method(
        :registered_projects, @original_registered_projects
      )
    end
  end

  def queued_requests
    with_runtime_dispatch_repository(@state_home, &:pending)
  end

  def test_request_older_than_ten_minutes_is_pruned_without_dispatch
    eleven_minutes_ago = T0 - (11 * 60)
    request_id = Hive::Bot::DispatchRequestWriter.write!(
      project: @project, slug: @slug,
      argv: [ "hive", "run", @slug, "--json" ],
      state_home: @state_home, now: eleven_minutes_ago
    )

    @dispatcher.tick(now: T0)

    assert_empty @supervisor.spawned, "an expired request must not dispatch"
    expired = @logger.events.find { |(n, attrs)|
      n == :dispatch_request_expired && attrs[:request_id] == request_id
    }
    refute_nil expired, "the expired request must log :dispatch_request_expired"
    assert_empty queued_requests, "expired request rows must be removed"
  end

  def test_request_within_window_still_dispatches
    nine_minutes_ago = T0 - (9 * 60)
    Hive::Bot::DispatchRequestWriter.write!(
      project: @project, slug: @slug,
      argv: [ "hive", "run", @slug, "--json" ],
      state_home: @state_home, now: nine_minutes_ago
    )

    @dispatcher.tick(now: T0)

    assert_equal 1, @supervisor.spawned.size,
                 "a request inside the 10-min window must dispatch normally"
  end
end
