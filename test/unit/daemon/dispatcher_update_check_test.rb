require "test_helper"
require "tmpdir"
require "hive/daemon/dispatcher"
require "hive/daemon/concurrency_controller"
require "hive/update_check"
require "hive/update_check/state"

# Pins the update-flow integration in Dispatcher#tick (plan 2026-05-27-002,
# U3): throttled release check, channel branch, nudge state, resilience.
class HiveDaemonDispatcherUpdateCheckTest < Minitest::Test
  T0 = Time.utc(2026, 5, 27, 12, 0, 0)

  class FakeStatusConsumer
    def fetch
      Hive::Daemon::StatusConsumer::Result.new(ok: true, rows: [], error: nil)
    end
  end

  class FakeSupervisor
    def reap_all(now: Time.now) = []
    def reap_dry_run(now: Time.now) = []
    def terminate_all(grace_sec: 600); end
    def in_flight_count = 0
  end

  class StubLogger
    attr_reader :events
    def initialize = @events = []
    def event(name, **attrs) = @events << [ name, attrs ]
    def close; end
  end

  class Checker
    attr_reader :calls
    def initialize(result) = (@result = result; @calls = 0)
    def call = (@calls += 1; @result)
  end

  def setup
    @dir = Dir.mktmpdir
    @state = Hive::UpdateCheck::State.new(path: File.join(@dir, "update_check.json"))
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def build(checker:, channel:, update_cfg: { "check" => true, "auto" => true })
    logger = StubLogger.new
    dispatcher = Hive::Daemon::Dispatcher.new(
      config: { "daemon" => { "poll_interval_sec" => 30 }, "update" => update_cfg },
      controller: Hive::Daemon::ConcurrencyController.new(
        max_concurrent_runs: 5, max_concurrent_per_project: 5, max_runs_per_day_per_project: 100
      ),
      supervisor: FakeSupervisor.new,
      status_consumer: FakeStatusConsumer.new,
      logger: logger,
      update_state: @state,
      update_checker: -> { checker.call },
      channel_detector: -> { channel }
    )
    [ dispatcher, logger ]
  end

  def result(latest:, behind:, current: "0.1.5")
    Hive::UpdateCheck::Result.new(current: current, latest: latest, behind: behind)
  end

  def events(logger, name)
    logger.events.select { |n, _| n == name }
  end

  def test_behind_on_brew_sets_nudge_and_logs
    checker = Checker.new(result(latest: "0.1.7", behind: true))
    dispatcher, logger = build(checker: checker, channel: "brew")
    dispatcher.tick(now: T0)

    nudge = @state.nudge
    assert nudge, "expected a nudge to be recorded when behind"
    assert_equal "0.1.7", nudge.latest
    assert_equal "brew", nudge.channel
    assert_equal "brew upgrade ivankuznetsov/hive/hive", nudge.command
    assert_equal 1, events(logger, :update_available).size
  end

  def test_bash_channel_is_nudge_only
    checker = Checker.new(result(latest: "0.1.7", behind: true))
    dispatcher, = build(checker: checker, channel: "bash")
    dispatcher.tick(now: T0)

    assert_equal "hive update", @state.nudge.command, "bash is nudge-only until U7 lands"
  end

  def test_dev_channel_skips_and_clears_nudge
    @state.set_nudge(latest: "0.1.6", channel: "brew", command: "brew upgrade x")
    checker = Checker.new(result(latest: "0.1.7", behind: true))
    dispatcher, logger = build(checker: checker, channel: "dev")
    dispatcher.tick(now: T0)

    assert_nil @state.nudge, "dev clones must not carry a nudge"
    assert_empty events(logger, :update_available)
  end

  def test_not_behind_clears_nudge
    @state.set_nudge(latest: "0.1.6", channel: "brew", command: "brew upgrade x")
    checker = Checker.new(result(latest: "0.1.7", behind: false))
    dispatcher, = build(checker: checker, channel: "brew")
    dispatcher.tick(now: T0)

    assert_nil @state.nudge, "a current install must clear any stale nudge"
  end

  def test_offline_check_degrades_silently
    checker = Checker.new(nil)
    dispatcher, logger = build(checker: checker, channel: "brew")
    dispatcher.tick(now: T0)

    assert_nil @state.nudge
    assert_empty events(logger, :update_available)
    assert_empty events(logger, :update_check_error), "nil result is not an error, just no info"
    assert_equal 1, events(logger, :update_check_no_result).size,
                 "an unreachable check logs a distinct signal so operators can see it"
  end

  def test_checker_exception_does_not_crash_tick
    boom = Object.new
    def boom.call = raise(StandardError, "kaboom")
    logger = StubLogger.new
    dispatcher = Hive::Daemon::Dispatcher.new(
      config: { "daemon" => { "poll_interval_sec" => 30 }, "update" => { "check" => true, "auto" => true } },
      controller: Hive::Daemon::ConcurrencyController.new(
        max_concurrent_runs: 5, max_concurrent_per_project: 5, max_runs_per_day_per_project: 100
      ),
      supervisor: FakeSupervisor.new, status_consumer: FakeStatusConsumer.new, logger: logger,
      update_state: @state, update_checker: -> { boom.call }, channel_detector: -> { "brew" }
    )
    dispatcher.tick(now: T0) # must not raise
    assert_equal 1, events(logger, :update_check_error).size
  end

  def test_throttled_to_once_per_window
    checker = Checker.new(result(latest: "0.1.7", behind: true))
    dispatcher, = build(checker: checker, channel: "brew")
    dispatcher.tick(now: T0)
    dispatcher.tick(now: T0 + 3600) # within the daily window
    assert_equal 1, checker.calls, "must not re-probe GitHub within the throttle window"
  end

  def test_disabled_check_never_probes
    checker = Checker.new(result(latest: "0.1.7", behind: true))
    dispatcher, = build(checker: checker, channel: "brew", update_cfg: { "check" => false, "auto" => true })
    dispatcher.tick(now: T0)
    assert_equal 0, checker.calls
    assert_nil @state.nudge
  end
end
