require "test_helper"
require "hive/daemon/digest_scheduler"

class HiveDaemonDigestSchedulerTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 6, 14, 0, 0, 30)

  class StubLogger
    attr_reader :events

    def initialize
      @events = []
    end

    def event(name, **attrs)
      @events << [ name, attrs ]
    end
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
