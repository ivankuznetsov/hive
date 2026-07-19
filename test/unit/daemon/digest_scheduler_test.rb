require "test_helper"
require "hive/daemon/digest_scheduler"
require "hive/daemon/logger"

class HiveDaemonDigestSchedulerTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 6, 14, 0, 0, 30)

  # Validate event names against the REAL daemon Logger allowlist so a
  # scheduler emitting an unregistered event (which a production
  # Hive::Daemon::Logger would reject with ArgumentError, crashing the
  # tick) is caught here instead of passing against a permissive stub.
  class StubLogger
    attr_reader :events

    def initialize
      @events = []
    end

    def event(name, **attrs)
      unless Hive::Daemon::Logger::EVENTS.include?(name)
        raise ArgumentError, "unregistered daemon log event in test: #{name.inspect}"
      end

      @events << [ name, attrs ]
    end
  end

  def test_base_scheduler_requires_a_subclass_contract
    base = Hive::Daemon::DigestSchedulerBase.new(
      state_path: "/tmp/hive-digest-base-test.json",
      clock: -> { T0 },
      enabled: false,
      logger: nil
    )

    error = assert_raises(NotImplementedError) { base.send(:scheduler_contract) }
    assert_includes error.message, "must define its digest scheduler contract"
  end

  def test_first_run_initializes_cursor_without_dispatching_history
    with_tmp_dir do |dir|
      scheduler = scheduler(dir, enabled: true)

      assert_empty scheduler.tick(now: T0)
      assert_equal "2026-06-13", state(dir).fetch("last_digested_date")
    end
  end

  def test_normal_due_day_dispatches_once_and_completion_advances_cursor
    with_tmp_dir do |dir|
      write_state(dir, "last_digested_date" => "2026-06-12")
      scheduler = scheduler(dir, enabled: true)

      dispatches = scheduler.tick(now: T0)

      assert_equal 1, dispatches.size
      assert_equal "digest", dispatches.first.fetch(:project)
      assert_equal "2026-06-13", dispatches.first.fetch(:slug)
      assert_equal "digest", dispatches.first.fetch(:stage)
      assert_equal "hive digest --date 2026-06-13 --json", dispatches.first.fetch(:command)
      assert scheduler.pending?("2026-06-13")
      assert_empty scheduler.tick(now: T0 + 60), "pending digest must not dispatch twice"

      scheduler.complete(date: "2026-06-13", exit_code: 0, now: T0 + 61)

      assert_equal "2026-06-13", state(dir).fetch("last_digested_date")
      assert_empty scheduler.tick(now: T0 + 62)
    end
  end

  def test_complete_nonzero_leaves_cursor_and_backs_off_before_retry
    with_tmp_dir do |dir|
      write_state(dir, "last_digested_date" => "2026-06-12")
      scheduler = scheduler(dir, enabled: true)

      assert_equal "2026-06-13", scheduler.tick(now: T0).first.fetch(:slug)
      scheduler.complete(date: "2026-06-13", exit_code: 1, now: T0 + 1)

      assert_equal "2026-06-12", state(dir).fetch("last_digested_date")
      assert_empty scheduler.tick(now: T0 + 2), "a failed date must back off before retrying"
      assert_equal "2026-06-13", scheduler.tick(now: T0 + 61).first.fetch(:slug),
                   "the same date re-dispatches once the backoff window elapses"
    end
  end

  def test_failed_date_backoff_escalates_and_logs
    with_tmp_dir do |dir|
      write_state(dir, "last_digested_date" => "2026-06-12")
      logger = StubLogger.new
      scheduler = scheduler(dir, enabled: true, logger: logger)

      assert_equal "2026-06-13", scheduler.tick(now: T0).first.fetch(:slug)
      scheduler.complete(date: "2026-06-13", exit_code: 1, now: T0 + 1)

      # First failure → 60s window: suppressed inside it, dispatched after.
      assert_empty scheduler.tick(now: T0 + 30)
      assert_equal "2026-06-13", scheduler.tick(now: T0 + 61).first.fetch(:slug)

      # Second consecutive failure → 300s window.
      scheduler.complete(date: "2026-06-13", exit_code: 1, now: T0 + 62)
      assert_empty scheduler.tick(now: T0 + 200)
      assert_equal "2026-06-13", scheduler.tick(now: T0 + 362).first.fetch(:slug)

      windows = logger.events.select { |name, _| name == :digest_failure_backoff }
                      .map { |_, attrs| attrs.fetch(:retry_after_sec) }
      assert_equal [ 60, 300 ], windows
    end
  end

  def test_success_after_failure_clears_backoff
    with_tmp_dir do |dir|
      write_state(dir, "last_digested_date" => "2026-06-11")
      scheduler = scheduler(dir, enabled: true)

      assert_equal "2026-06-12", scheduler.tick(now: T0).first.fetch(:slug)
      scheduler.complete(date: "2026-06-12", exit_code: 1, now: T0 + 1)
      assert_equal "2026-06-12", scheduler.tick(now: T0 + 61).first.fetch(:slug)
      scheduler.complete(date: "2026-06-12", exit_code: 0, now: T0 + 62)

      # Cursor advanced and the cleared backoff lets the next owed day go
      # immediately, with no residual window from the prior failure.
      assert_equal "2026-06-12", state(dir).fetch("last_digested_date")
      assert_equal "2026-06-13", scheduler.tick(now: T0 + 63).first.fetch(:slug)
    end
  end

  def test_catchup_dispatches_missed_days_oldest_first_one_at_a_time
    with_tmp_dir do |dir|
      write_state(dir, "last_digested_date" => "2026-06-10")
      scheduler = scheduler(dir, enabled: true)

      assert_equal "2026-06-11", scheduler.tick(now: T0).first.fetch(:slug)
      scheduler.complete(date: "2026-06-11", exit_code: 0, now: T0 + 1)
      assert_equal "2026-06-12", scheduler.tick(now: T0 + 2).first.fetch(:slug)
      scheduler.complete(date: "2026-06-12", exit_code: 0, now: T0 + 3)
      assert_equal "2026-06-13", scheduler.tick(now: T0 + 4).first.fetch(:slug)
    end
  end

  def test_catchup_cap_skips_oldest_excess_days_and_logs
    with_tmp_dir do |dir|
      write_state(dir, "last_digested_date" => "2026-06-01")
      logger = StubLogger.new
      scheduler = scheduler(dir, enabled: true, max_catchup_days: 3, logger: logger)

      dispatches = scheduler.tick(now: T0)

      assert_equal "2026-06-11", dispatches.first.fetch(:slug)
      assert_equal "2026-06-10", state(dir).fetch("last_digested_date")
      event = logger.events.find { |name, _attrs| name == :digest_catchup_skipped }
      assert_equal "2026-06-02", event.last.fetch(:skipped_from)
      assert_equal "2026-06-10", event.last.fetch(:skipped_to)
    end
  end

  def test_catchup_cap_drains_all_capped_days_in_order_then_stops
    with_tmp_dir do |dir|
      write_state(dir, "last_digested_date" => "2026-06-01")
      scheduler = scheduler(dir, enabled: true, max_catchup_days: 3)

      # 06-02..06-13 owed (12 days); cap keeps the newest three: 11, 12, 13.
      # Drive the full drain, completing each before the next dispatches.
      assert_equal "2026-06-11", scheduler.tick(now: T0).first.fetch(:slug)
      scheduler.complete(date: "2026-06-11", exit_code: 0, now: T0 + 1)
      assert_equal "2026-06-12", scheduler.tick(now: T0 + 2).first.fetch(:slug)
      scheduler.complete(date: "2026-06-12", exit_code: 0, now: T0 + 3)
      assert_equal "2026-06-13", scheduler.tick(now: T0 + 4).first.fetch(:slug)
      scheduler.complete(date: "2026-06-13", exit_code: 0, now: T0 + 5)

      assert_equal "2026-06-13", state(dir).fetch("last_digested_date"),
                   "every capped day must drain through the cursor exactly once"
      assert_empty scheduler.tick(now: T0 + 6), "no day may be stranded or double-dispatched"
    end
  end

  def test_zero_max_catchup_days_is_unbounded
    with_tmp_dir do |dir|
      write_state(dir, "last_digested_date" => "2026-06-01")
      logger = StubLogger.new
      scheduler = scheduler(dir, enabled: true, max_catchup_days: 0, logger: logger)

      assert_equal "2026-06-02", scheduler.tick(now: T0).first.fetch(:slug)
      assert_equal "2026-06-01", state(dir).fetch("last_digested_date"),
                   "unbounded catch-up must not skip or advance the cursor"
      refute logger.events.any? { |name, _| name == :digest_catchup_skipped }
    end
  end

  def test_disabled_scheduler_returns_no_dispatches
    with_tmp_dir do |dir|
      write_state(dir, "last_digested_date" => "2026-06-12")

      assert_empty scheduler(dir, enabled: false).tick(now: T0)
    end
  end

  def test_backoff_clamps_at_final_tier_after_repeated_failures
    with_tmp_dir do |dir|
      write_state(dir, "last_digested_date" => "2026-06-12")
      logger = StubLogger.new
      scheduler = scheduler(dir, enabled: true, logger: logger)

      # Four consecutive failures: 60s, 300s, then clamp at the final 900s
      # tier. Without the `[count - 1, size - 1].min` clamp the fourth would
      # index past the schedule and raise on `now + nil`.
      4.times { |i| scheduler.complete(date: "2026-06-13", exit_code: 1, now: T0 + i) }

      windows = logger.events.select { |name, _| name == :digest_failure_backoff }
                      .map { |_, attrs| attrs.fetch(:retry_after_sec) }
      assert_equal [ 60, 300, 900, 900 ], windows,
                   "the third and later consecutive failures must clamp at the 900s ceiling"
    end
  end

  def test_backoff_logs_next_eligible_at_as_now_plus_interval
    with_tmp_dir do |dir|
      write_state(dir, "last_digested_date" => "2026-06-12")
      logger = StubLogger.new
      scheduler = scheduler(dir, enabled: true, logger: logger)

      scheduler.complete(date: "2026-06-13", exit_code: 1, now: T0)

      event = logger.events.find { |name, _| name == :digest_failure_backoff }.last
      assert_equal((T0 + 60).utc.iso8601, event.fetch(:next_eligible_at),
                   "next_eligible_at must be the future retry time (now + interval), not the failure time")
    end
  end

  def test_nil_exit_code_is_treated_as_failure_not_silent_skip
    with_tmp_dir do |dir|
      write_state(dir, "last_digested_date" => "2026-06-12")
      scheduler = scheduler(dir, enabled: true)

      assert_equal "2026-06-13", scheduler.tick(now: T0).first.fetch(:slug)
      # A signalled child (SIGTERM/SIGKILL on shutdown or timeout) reports a
      # nil exit status; treating it as success would advance the cursor and
      # silently skip the date.
      scheduler.complete(date: "2026-06-13", exit_code: nil, now: T0 + 1)

      assert_equal "2026-06-12", state(dir).fetch("last_digested_date"),
                   "a nil (signalled) exit must be a failure, not a silent cursor advance"
    end
  end

  def test_complete_does_not_regress_cursor_for_an_older_date
    with_tmp_dir do |dir|
      write_state(dir, "last_digested_date" => "2026-06-13")
      scheduler = scheduler(dir, enabled: true)

      # A late/duplicate success for an OLDER date must not rewind the cursor.
      scheduler.complete(date: "2026-06-10", exit_code: 0, now: T0)

      assert_equal "2026-06-13", state(dir).fetch("last_digested_date"),
                   "completion must never regress the cursor below its current value"
    end
  end

  def test_complete_write_failure_keeps_day_owed_and_backs_off
    with_tmp_dir do |dir|
      write_state(dir, "last_digested_date" => "2026-06-12")
      logger = StubLogger.new
      scheduler = scheduler(dir, enabled: true, logger: logger)
      assert_equal "2026-06-13", scheduler.tick(now: T0).first.fetch(:slug)

      scheduler.define_singleton_method(:write_state) do |_data|
        raise Errno::ENOSPC, "no space left on device"
      end

      assert_raises(Errno::ENOSPC) do
        scheduler.complete(date: "2026-06-13", exit_code: 0, now: T0 + 1)
      end

      assert_equal "2026-06-12", state(dir).fetch("last_digested_date")
      assert logger.events.any? { |name, _| name == :digest_failure_backoff }
      assert_empty scheduler.tick(now: T0 + 30)
      assert_equal "2026-06-13", scheduler.tick(now: T0 + 61).first.fetch(:slug)
    end
  end

  def test_reconfigure_enables_a_disabled_scheduler_in_place
    with_tmp_dir do |dir|
      write_state(dir, "last_digested_date" => "2026-06-12")
      scheduler = scheduler(dir, enabled: false)

      assert_empty scheduler.tick(now: T0), "a disabled scheduler dispatches nothing"

      scheduler.reconfigure(enabled: true, max_catchup_days: 7)

      assert_equal "2026-06-13", scheduler.tick(now: T0).first.fetch(:slug),
                   "reconfigure must enable dispatch within one tick"
    end
  end

  def test_reconfigure_can_disable_an_enabled_scheduler
    with_tmp_dir do |dir|
      write_state(dir, "last_digested_date" => "2026-06-12")
      scheduler = scheduler(dir, enabled: true)

      scheduler.reconfigure(enabled: false, max_catchup_days: 7)

      assert_empty scheduler.tick(now: T0), "reconfigure(enabled: false) must stop dispatch"
    end
  end

  def test_cancel_releases_pending_without_recording_a_failure
    with_tmp_dir do |dir|
      write_state(dir, "last_digested_date" => "2026-06-12")
      scheduler = scheduler(dir, enabled: true)

      assert_equal "2026-06-13", scheduler.tick(now: T0).first.fetch(:slug)
      assert scheduler.pending?("2026-06-13")

      scheduler.cancel(date: "2026-06-13")

      refute scheduler.pending?("2026-06-13"), "cancel must clear the pending marker"
      # No failure recorded → no backoff window, so the next tick re-dispatches
      # the same date immediately.
      assert_equal "2026-06-13", scheduler.tick(now: T0 + 1).first.fetch(:slug),
                   "a cancelled (never-run) date must be re-evaluated with no backoff"
    end
  end

  def test_corrupt_state_emits_unreadable_event
    with_tmp_dir do |dir|
      File.write(File.join(dir, "digest_state.json"), "{ not valid json")
      logger = StubLogger.new
      scheduler = scheduler(dir, enabled: true, logger: logger)

      scheduler.tick(now: T0)

      assert(logger.events.any? { |name, _| name == :digest_state_unreadable },
             "a corrupt digest_state.json must surface a :digest_state_unreadable event " \
             "instead of silently resetting the cursor")
    end
  end

  def test_wrong_shape_state_emits_unreadable_event_before_degrading
    with_tmp_dir do |dir|
      # Valid JSON, wrong shape (a top-level array, not an object). Treating
      # it as a silent first-run would reset the cursor forward and skip every
      # owed day, so it must surface a distinct event before degrading to {}.
      File.write(File.join(dir, "digest_state.json"), JSON.pretty_generate([ "2026-06-12" ]))
      logger = StubLogger.new
      scheduler = scheduler(dir, enabled: true, logger: logger)

      assert_empty scheduler.tick(now: T0), "a wrong-shape state degrades to a seeded first-run"
      event = logger.events.find { |name, _| name == :digest_state_unreadable }
      refute_nil event, "a JSON array where an object is expected must surface :digest_state_unreadable"
      assert_match(/expected a JSON object/, event.last.fetch(:error))
    end
  end

  def test_unparseable_cursor_date_is_treated_as_first_run
    with_tmp_dir do |dir|
      # A non-ISO last_digested_date makes Date.iso8601 raise ArgumentError;
      # parse_date swallows it to nil so tick re-seeds rather than crashing.
      write_state(dir, "last_digested_date" => "not-a-date")
      scheduler = scheduler(dir, enabled: true)

      assert_empty scheduler.tick(now: T0),
                   "an unparseable cursor must degrade to a first-run seed, not raise"
      assert_equal "2026-06-13", state(dir).fetch("last_digested_date"),
                   "the seed must reset the cursor to the completed day"
    end
  end

  def test_dst_boundary_uses_local_completed_day_once
    with_env("TZ" => "America/New_York") do
      with_tmp_dir do |dir|
        write_state(dir, "last_digested_date" => "2026-03-07")
        scheduler = scheduler(dir, enabled: true)

        dispatches = scheduler.tick(now: Time.utc(2026, 3, 9, 4, 30, 0))

        assert_equal "2026-03-08", dispatches.first.fetch(:slug)
      end
    end
  end

  private

  def scheduler(dir, enabled:, max_catchup_days: 7, logger: nil)
    Hive::Daemon::DigestScheduler.new(
      state_path: File.join(dir, "digest_state.json"),
      enabled: enabled,
      max_catchup_days: max_catchup_days,
      logger: logger
    )
  end

  def write_state(dir, data)
    File.write(File.join(dir, "digest_state.json"), JSON.pretty_generate(data))
  end

  def state(dir)
    JSON.parse(File.read(File.join(dir, "digest_state.json")))
  end
end
