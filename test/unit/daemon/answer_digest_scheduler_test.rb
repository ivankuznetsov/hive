require "test_helper"
require "hive/daemon/answer_digest_scheduler"
require "hive/daemon/logger"

class HiveDaemonAnswerDigestSchedulerTest < Minitest::Test
  include HiveTestHelper

  BEFORE_9 = Time.utc(2026, 6, 14, 8, 59, 59)
  AT_9 = Time.utc(2026, 6, 14, 9, 0, 0)
  AFTER_9 = Time.utc(2026, 6, 14, 9, 5, 0)

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

  def test_disabled_default_state_path_scheduler_returns_no_dispatches
    assert_empty Hive::Daemon::AnswerDigestScheduler.new(enabled: false).tick(now: AT_9)
  end

  def test_before_configured_hour_returns_no_dispatches
    with_utc do
      with_tmp_dir do |dir|
        assert_empty scheduler(dir, enabled: true).tick(now: BEFORE_9)
        refute File.exist?(state_path(dir))
      end
    end
  end

  def test_at_or_after_configured_hour_dispatches_today_once_and_marks_pending
    with_utc do
      with_tmp_dir do |dir|
        scheduler = scheduler(dir, enabled: true)

        dispatches = scheduler.tick(now: AT_9)

        assert_equal 1, dispatches.size
        assert_equal "answer_digest", dispatches.first.fetch(:project)
        assert_equal "2026-06-14", dispatches.first.fetch(:slug)
        assert_equal "answer_digest", dispatches.first.fetch(:stage)
        assert_equal "hive answer-digest --date 2026-06-14 --json", dispatches.first.fetch(:command)
        assert scheduler.pending?("2026-06-14")
        assert_empty scheduler.tick(now: AFTER_9), "pending answer digest must not dispatch twice"
      end
    end
  end

  def test_complete_success_marks_date_done_and_survives_restart
    with_utc do
      with_tmp_dir do |dir|
        scheduler = scheduler(dir, enabled: true)
        assert_equal "2026-06-14", scheduler.tick(now: AT_9).first.fetch(:slug)

        scheduler.complete(date: "2026-06-14", exit_code: 0, now: AFTER_9)

        assert_equal "2026-06-14", state(dir).fetch("last_fired_date")
        assert_equal AFTER_9.utc.iso8601, state(dir).fetch("updated_at")
        assert_empty scheduler.tick(now: AFTER_9 + 60)
        assert_empty scheduler(dir, enabled: true).tick(now: AFTER_9 + 120),
                     "a fresh scheduler must not re-fire a completed local day"
      end
    end
  end

  def test_next_local_day_fires_again
    with_utc do
      with_tmp_dir do |dir|
        write_state(dir, "last_fired_date" => "2026-06-14")
        scheduler = scheduler(dir, enabled: true)

        assert_equal "2026-06-15", scheduler.tick(now: Time.utc(2026, 6, 15, 9, 0, 0)).first.fetch(:slug)
      end
    end
  end

  def test_complete_nonzero_leaves_cursor_and_backs_off_before_retry
    with_utc do
      with_tmp_dir do |dir|
        write_state(dir, "last_fired_date" => "2026-06-13")
        scheduler = scheduler(dir, enabled: true)

        assert_equal "2026-06-14", scheduler.tick(now: AT_9).first.fetch(:slug)
        scheduler.complete(date: "2026-06-14", exit_code: 1, now: AT_9 + 1)

        assert_equal "2026-06-13", state(dir).fetch("last_fired_date")
        assert_empty scheduler.tick(now: AT_9 + 30)
        assert_equal "2026-06-14", scheduler.tick(now: AT_9 + 61).first.fetch(:slug)
      end
    end
  end

  def test_nil_exit_code_is_treated_as_failure
    with_utc do
      with_tmp_dir do |dir|
        write_state(dir, "last_fired_date" => "2026-06-13")
        scheduler = scheduler(dir, enabled: true)

        assert_equal "2026-06-14", scheduler.tick(now: AT_9).first.fetch(:slug)
        scheduler.complete(date: "2026-06-14", exit_code: nil, now: AT_9 + 1)

        assert_equal "2026-06-13", state(dir).fetch("last_fired_date")
      end
    end
  end

  def test_failed_date_backoff_escalates_and_logs
    with_utc do
      with_tmp_dir do |dir|
        write_state(dir, "last_fired_date" => "2026-06-13")
        logger = StubLogger.new
        scheduler = scheduler(dir, enabled: true, logger: logger)

        assert_equal "2026-06-14", scheduler.tick(now: AT_9).first.fetch(:slug)
        scheduler.complete(date: "2026-06-14", exit_code: 1, now: AT_9 + 1)
        assert_empty scheduler.tick(now: AT_9 + 30)
        assert_equal "2026-06-14", scheduler.tick(now: AT_9 + 61).first.fetch(:slug)

        scheduler.complete(date: "2026-06-14", exit_code: 1, now: AT_9 + 62)
        assert_empty scheduler.tick(now: AT_9 + 200)
        assert_equal "2026-06-14", scheduler.tick(now: AT_9 + 362).first.fetch(:slug)

        windows = logger.events.select { |name, _| name == :answer_digest_failure_backoff }
                        .map { |_, attrs| attrs.fetch(:retry_after_sec) }
        assert_equal [ 60, 300 ], windows
      end
    end
  end

  def test_backoff_clamps_at_final_tier_after_repeated_failures
    with_utc do
      with_tmp_dir do |dir|
        logger = StubLogger.new
        scheduler = scheduler(dir, enabled: true, logger: logger)

        4.times { |i| scheduler.complete(date: "2026-06-14", exit_code: 1, now: AT_9 + i) }

        windows = logger.events.select { |name, _| name == :answer_digest_failure_backoff }
                        .map { |_, attrs| attrs.fetch(:retry_after_sec) }
        assert_equal [ 60, 300, 900, 900 ], windows
        event = logger.events.find { |name, _| name == :answer_digest_failure_backoff }.last
        assert_equal((AT_9 + 60).utc.iso8601, event.fetch(:next_eligible_at))
      end
    end
  end

  def test_success_after_failure_clears_backoff
    with_utc do
      with_tmp_dir do |dir|
        write_state(dir, "last_fired_date" => "2026-06-13")
        scheduler = scheduler(dir, enabled: true)

        assert_equal "2026-06-14", scheduler.tick(now: AT_9).first.fetch(:slug)
        scheduler.complete(date: "2026-06-14", exit_code: 1, now: AT_9 + 1)
        assert_equal "2026-06-14", scheduler.tick(now: AT_9 + 61).first.fetch(:slug)
        scheduler.complete(date: "2026-06-14", exit_code: 0, now: AT_9 + 62)

        assert_empty scheduler.tick(now: AT_9 + 63),
                     "success must clear the pending marker and record today as fired"
      end
    end
  end

  def test_cancel_releases_pending_without_recording_failure
    with_utc do
      with_tmp_dir do |dir|
        scheduler = scheduler(dir, enabled: true)

        assert_equal "2026-06-14", scheduler.tick(now: AT_9).first.fetch(:slug)
        scheduler.cancel(date: "2026-06-14")

        refute scheduler.pending?("2026-06-14")
        assert_equal "2026-06-14", scheduler.tick(now: AT_9 + 1).first.fetch(:slug)
      end
    end
  end

  def test_reconfigure_changes_enabled_state_and_hour
    with_utc do
      with_tmp_dir do |dir|
        scheduler = scheduler(dir, enabled: false, hour: 22)

        scheduler.reconfigure(enabled: true, hour: 10)
        assert_empty scheduler.tick(now: AT_9)
        assert_equal "2026-06-14", scheduler.tick(now: Time.utc(2026, 6, 14, 10, 0, 0)).first.fetch(:slug)

        scheduler.cancel(date: "2026-06-14")
        scheduler.reconfigure(enabled: false, hour: 9)
        assert_empty scheduler.tick(now: Time.utc(2026, 6, 14, 11, 0, 0))
      end
    end
  end

  def test_complete_does_not_regress_cursor_for_older_date
    with_tmp_dir do |dir|
      write_state(dir, "last_fired_date" => "2026-06-14")
      scheduler = scheduler(dir, enabled: true)

      scheduler.complete(date: "2026-06-13", exit_code: 0, now: AFTER_9)

      assert_equal "2026-06-14", state(dir).fetch("last_fired_date")
    end
  end

  # A successful send whose cursor write fails (ENOSPC/EROFS on the atomic
  # rename) must NOT silently advance/clear backoff: the day stays owed AND the
  # bounded backoff is engaged, so the next eligible tick retries on the
  # schedule instead of re-firing immediately and re-sending the same digest.
  def test_complete_write_failure_keeps_day_owed_and_backs_off
    with_utc do
      with_tmp_dir do |dir|
        write_state(dir, "last_fired_date" => "2026-06-13")
        logger = StubLogger.new
        scheduler = scheduler(dir, enabled: true, logger: logger)
        assert_equal "2026-06-14", scheduler.tick(now: AT_9).first.fetch(:slug)

        scheduler.define_singleton_method(:write_state) do |_data|
          raise Errno::ENOSPC, "no space left on device"
        end

        assert_raises(Errno::ENOSPC) do
          scheduler.complete(date: "2026-06-14", exit_code: 0, now: AT_9 + 1)
        end

        assert_equal "2026-06-13", state(dir).fetch("last_fired_date"),
                     "a failed cursor write must leave the day owed, not advance it"
        assert logger.events.any? { |name, _| name == :answer_digest_failure_backoff },
               "a failed cursor write after a successful send must engage the backoff"
        assert_empty scheduler.tick(now: AT_9 + 30),
                     "the backoff must suppress an immediate re-fire of the same digest"
        assert_equal "2026-06-14", scheduler.tick(now: AT_9 + 61).first.fetch(:slug),
                     "the owed day re-fires once the backoff elapses"
      end
    end
  end

  def test_corrupt_state_emits_unreadable_event
    with_utc do
      with_tmp_dir do |dir|
        File.write(state_path(dir), "{ not valid json")
        logger = StubLogger.new
        scheduler = scheduler(dir, enabled: true, logger: logger)

        assert_equal "2026-06-14", scheduler.tick(now: AT_9).first.fetch(:slug)

        assert logger.events.any? { |name, _| name == :answer_digest_state_unreadable }
      end
    end
  end

  def test_wrong_shape_state_emits_unreadable_event
    with_utc do
      with_tmp_dir do |dir|
        File.write(state_path(dir), JSON.pretty_generate([ "2026-06-13" ]))
        logger = StubLogger.new
        scheduler = scheduler(dir, enabled: true, logger: logger)

        assert_equal "2026-06-14", scheduler.tick(now: AT_9).first.fetch(:slug)

        event = logger.events.find { |name, _| name == :answer_digest_state_unreadable }
        refute_nil event
        assert_match(/expected a JSON object/, event.last.fetch(:error))
      end
    end
  end

  def test_unparseable_cursor_date_is_treated_as_unfired_and_logged
    with_utc do
      with_tmp_dir do |dir|
        write_state(dir, "last_fired_date" => "not-a-date")
        logger = StubLogger.new
        scheduler = scheduler(dir, enabled: true, logger: logger)

        assert_equal "2026-06-14", scheduler.tick(now: AT_9).first.fetch(:slug)
        event = logger.events.find { |name, _| name == :answer_digest_state_unreadable }
        refute_nil event, "a corrupt last_fired_date must be logged, not self-heal in the dark"
        assert_match(/malformed last_fired_date/, event.last.fetch(:error))
      end
    end
  end

  def test_local_timezone_controls_date_and_hour
    with_env("TZ" => "America/New_York") do
      with_tmp_dir do |dir|
        scheduler = scheduler(dir, enabled: true, hour: 9)

        assert_empty scheduler.tick(now: Time.utc(2026, 3, 8, 12, 59, 59))
        assert_equal "2026-03-08", scheduler.tick(now: Time.utc(2026, 3, 8, 13, 0, 0)).first.fetch(:slug)
      end
    end
  end

  def test_clamp_hour_clamps_out_of_range_values_at_construction_and_reconfigure
    sched = Hive::Daemon::AnswerDigestScheduler.new(enabled: true, hour: -5)
    assert_equal 0, sched.send(:clamp_hour, -5), "hours below 0 clamp to 0"
    assert_equal 0, sched.send(:clamp_hour, 0), "0 is in range"
    assert_equal 23, sched.send(:clamp_hour, 23), "23 is in range"
    assert_equal 23, sched.send(:clamp_hour, 99), "hours above 23 clamp to 23"
    assert_equal 0, sched.instance_variable_get(:@hour), "constructor clamps an out-of-range hour"

    sched.reconfigure(enabled: true, hour: 30)
    assert_equal 23, sched.instance_variable_get(:@hour), "reconfigure clamps an out-of-range hour"
  end

  private

  def scheduler(dir, enabled:, hour: 9, logger: nil)
    Hive::Daemon::AnswerDigestScheduler.new(
      state_path: state_path(dir),
      enabled: enabled,
      hour: hour,
      logger: logger
    )
  end

  def state_path(dir)
    File.join(dir, "answer_digest_state.json")
  end

  def write_state(dir, data)
    File.write(state_path(dir), JSON.pretty_generate(data))
  end

  def state(dir)
    JSON.parse(File.read(state_path(dir)))
  end

  def with_utc(&block)
    with_env({ "TZ" => "UTC" }, &block)
  end
end
