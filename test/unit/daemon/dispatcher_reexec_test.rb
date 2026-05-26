require "test_helper"
require "tmpdir"
require "digest"
require "hive/daemon/dispatcher"
require "hive/daemon/concurrency_controller"

# Covers the auto-reexec behavior: when the on-disk source file that
# defines SCHEMA_VERSIONS changes, the dispatcher detects drift, logs
# a `version_drift` event, sets `reexec_requested?`, and breaks its
# run loop so Commands::Daemon can re-exec. See
# lib/hive/daemon/dispatcher.rb for context.
class HiveDaemonDispatcherReexecTest < Minitest::Test
  include HiveTestHelper

  class StubLogger
    attr_reader :events
    def initialize; @events = []; end
    def event(name, **attrs); @events << [ name, attrs ]; end
    def close; end
  end

  class StubStatusConsumer
    def fetch
      Hive::Daemon::StatusConsumer::Result.new(ok: true, rows: [], error: nil)
    end
  end

  class StubSupervisor
    def reap_all(now: Time.now); []; end
    def reap_dry_run(now: Time.now); []; end
    def terminate_all(grace_sec: 600); end
    def in_flight_count; 0; end
  end

  def build_dispatcher
    config = {
      "daemon" => {
        "edit_debounce_sec" => 30, "poll_interval_sec" => 30, "shutdown_grace_sec" => 60
      }
    }
    controller = Hive::Daemon::ConcurrencyController.new(
      max_concurrent_runs: 3, max_concurrent_per_project: 3,
      max_runs_per_day_per_project: 50
    )
    Hive::Daemon::Dispatcher.new(
      config: config, controller: controller,
      supervisor: StubSupervisor.new, status_consumer: StubStatusConsumer.new,
      logger: StubLogger.new, dry_run: true
    )
  end

  def test_baseline_fingerprint_is_captured_at_construction_and_matches_disk
    dispatcher = build_dispatcher
    baseline = dispatcher.instance_variable_get(:@code_fingerprint)
    refute_nil baseline, "baseline fingerprint must be captured at init"
    assert_match(/\A[0-9a-f]{64}\z/, baseline, "fingerprint must be a sha256 hexdigest")

    # When nothing has changed on disk, no drift is reported.
    refute dispatcher.send(:version_drift_detected?),
           "freshly-constructed dispatcher must not report drift against unchanged disk"
  end

  def test_version_drift_detected_when_source_file_changes
    dispatcher = build_dispatcher
    # Replace the baseline with a deliberately-wrong digest to simulate
    # the daemon having loaded older code than what is on disk now.
    dispatcher.instance_variable_set(:@code_fingerprint, "0" * 64)

    assert dispatcher.send(:version_drift_detected?),
           "stale baseline vs fresh on-disk digest must register as drift"
  end

  def test_version_drift_suppressed_by_env_kill_switch
    dispatcher = build_dispatcher
    dispatcher.instance_variable_set(:@code_fingerprint, "0" * 64)
    with_env("HIVE_DAEMON_NO_AUTO_REEXEC" => "1") do
      refute dispatcher.send(:version_drift_detected?),
             "HIVE_DAEMON_NO_AUTO_REEXEC=1 must disable drift detection"
    end
  end

  def test_version_drift_suppressed_when_baseline_fingerprint_is_nil
    dispatcher = build_dispatcher
    dispatcher.instance_variable_set(:@code_fingerprint, nil)
    refute dispatcher.send(:version_drift_detected?),
           "no baseline → never re-exec (fail-soft on read failure)"
  end

  def test_version_drift_rate_limited_within_60_seconds_of_previous_reexec
    dispatcher = build_dispatcher
    dispatcher.instance_variable_set(:@code_fingerprint, "0" * 64)
    dispatcher.instance_variable_set(:@last_reexec_at, Time.now - 5)

    refute dispatcher.send(:version_drift_detected?),
           "a re-exec less than 60s ago must rate-limit the next one"
  end

  def test_version_drift_not_rate_limited_after_60_seconds
    dispatcher = build_dispatcher
    dispatcher.instance_variable_set(:@code_fingerprint, "0" * 64)
    dispatcher.instance_variable_set(:@last_reexec_at, Time.now - 120)

    assert dispatcher.send(:version_drift_detected?),
           "after 60s the rate limit lifts and drift is reportable again"
  end

  def test_reexec_requested_is_false_until_drift_is_detected
    dispatcher = build_dispatcher
    refute dispatcher.reexec_requested?
  end

  def test_run_forever_breaks_loop_and_sets_reexec_requested_on_drift
    dispatcher = build_dispatcher
    # Force the loop to see drift on the first check.
    dispatcher.define_singleton_method(:version_drift_detected?) { true }
    dispatcher.define_singleton_method(:compute_code_fingerprint) { "deadbeef" * 8 }
    # No signal handler installation in tests — replace with a no-op.
    dispatcher.define_singleton_method(:install_signal_handlers!) { }

    dispatcher.run_forever

    assert dispatcher.reexec_requested?,
           "drift must flip reexec_requested? after run_forever returns"
    last = dispatcher.instance_variable_get(:@last_reexec_at)
    refute_nil last, "must stamp @last_reexec_at when drift fires"
  end

  def test_run_forever_logs_dispatcher_started_with_code_fingerprint
    dispatcher = build_dispatcher
    logger = dispatcher.instance_variable_get(:@logger)
    # Short-circuit the loop immediately so we only test the start log.
    dispatcher.define_singleton_method(:install_signal_handlers!) { }
    dispatcher.instance_variable_set(:@shutdown, true)
    dispatcher.run_forever

    started = logger.events.find { |(name, _)| name == :dispatcher_started }
    refute_nil started, "dispatcher_started event must be emitted"
    _, attrs = started
    assert attrs.key?(:code_fingerprint), "dispatcher_started must carry code_fingerprint"
    assert_match(/\A[0-9a-f]{64}\z/, attrs[:code_fingerprint])
  end

  def test_run_forever_logs_version_drift_event_with_both_fingerprints
    dispatcher = build_dispatcher
    logger = dispatcher.instance_variable_get(:@logger)
    dispatcher.instance_variable_set(:@code_fingerprint, "0" * 64)
    dispatcher.define_singleton_method(:install_signal_handlers!) { }
    dispatcher.define_singleton_method(:compute_code_fingerprint) { "f" * 64 }
    dispatcher.define_singleton_method(:version_drift_detected?) { true }

    dispatcher.run_forever

    drift = logger.events.find { |(name, _)| name == :version_drift }
    refute_nil drift, "version_drift event must be emitted on detection"
    _, attrs = drift
    assert_equal "0" * 64, attrs[:old_fingerprint]
    assert_equal "f" * 64, attrs[:new_fingerprint]
    assert_equal Process.pid, attrs[:pid]
  end

  def test_dispatcher_stopping_event_carries_reexec_requested_flag
    dispatcher = build_dispatcher
    logger = dispatcher.instance_variable_get(:@logger)
    dispatcher.define_singleton_method(:install_signal_handlers!) { }
    dispatcher.define_singleton_method(:version_drift_detected?) { true }
    dispatcher.define_singleton_method(:compute_code_fingerprint) { "f" * 64 }

    dispatcher.run_forever

    stopping = logger.events.find { |(name, _)| name == :dispatcher_stopping }
    refute_nil stopping, "dispatcher_stopping event must be emitted on shutdown"
    _, attrs = stopping
    assert_equal true, attrs[:reexec_requested],
                 "dispatcher_stopping must surface reexec_requested for observability"
  end

  private

  def with_env(pairs)
    previous = pairs.each_key.each_with_object({}) { |k, h| h[k] = ENV[k] }
    pairs.each { |k, v| ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
