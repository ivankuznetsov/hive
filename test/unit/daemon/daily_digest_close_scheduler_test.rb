require "test_helper"
require "hive/daemon/daily_digest_close_scheduler"

class HiveDaemonDailyDigestCloseSchedulerTest < Minitest::Test
  include HiveTestHelper

  def test_coalesces_refreshes_to_the_configured_cadence
    with_tmp_dir do |dir|
      now = Time.iso8601("2026-08-30T12:00:00Z")
      scheduler = Hive::Daemon::DailyDigestCloseScheduler.new(
        state_path: File.join(dir, "state.json"), enabled: true,
        interval_sec: 300, clock: -> { now },
        date_resolver: ->(_instant) { "2026-08-30" }
      )

      dispatch = scheduler.tick.fetch(0)
      assert_equal "daily_digest_close", dispatch.fetch(:stage)
      assert_equal "hive digest refresh --json", dispatch.fetch(:command)
      assert_empty scheduler.tick

      scheduler.complete(date: "2026-08-30", exit_code: 0, now: now)
      now += 299
      assert_empty scheduler.tick
      now += 1
      assert_equal 1, scheduler.tick.size
    end
  end

  def test_disabled_scheduler_never_dispatches
    scheduler = Hive::Daemon::DailyDigestCloseScheduler.new(
      enabled: false, date_resolver: ->(_instant) { "2026-08-30" }
    )
    assert_empty scheduler.tick(now: Time.iso8601("2026-08-30T12:00:00Z"))
  end

  def test_open_covering_record_uses_the_independent_refresh_identity
    with_tmp_dir do |dir|
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      interval = Hive::DailyDigest::Calendar.new(time_zone: "UTC")
                                             .interval_for("2026-08-30", sequence: 1)
      store.write_base(
        "schema" => "hive-digest-record", "schema_version" => 1, **interval,
        "lifecycle" => "open", "closed_at" => nil,
        "completeness" => "complete", "content" => "empty",
        "last_materialized_at" => interval.fetch("starts_at"),
        "projects" => [], "items" => [], "attention" => [], "gaps" => [],
        "source_frontiers" => {}
      )
      scheduler = Hive::Daemon::DailyDigestCloseScheduler.new(
        state_path: File.join(dir, "state.json"), enabled: true,
        interval_sec: 300, store: store,
        date_resolver: ->(_instant) { "2026-08-30" }
      )

      dispatch = scheduler.tick(now: Time.iso8601("2026-08-30T12:00:00Z")).fetch(0)
      assert_equal "daily_digest_refresh", dispatch.fetch(:stage)
      assert_equal "daily_digest_refresh", dispatch.fetch(:project)
    end
  end

  def test_boundary_close_dispatches_while_the_prior_refresh_is_still_pending
    with_tmp_dir do |dir|
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      interval = Hive::DailyDigest::Calendar.new(time_zone: "UTC")
                                             .interval_for("2026-08-30", sequence: 1)
      store.write_base(
        "schema" => "hive-digest-record", "schema_version" => 1, **interval,
        "lifecycle" => "open", "closed_at" => nil,
        "completeness" => "complete", "content" => "empty",
        "last_materialized_at" => interval.fetch("starts_at"),
        "projects" => [], "items" => [], "attention" => [], "gaps" => [],
        "source_frontiers" => {}
      )
      scheduler = Hive::Daemon::DailyDigestCloseScheduler.new(
        state_path: File.join(dir, "state.json"), enabled: true,
        interval_sec: 300, store: store,
        date_resolver: ->(_instant) { "2026-08-30" }
      )

      refresh = scheduler.tick(now: Time.iso8601("2026-08-30T23:59:59Z")).fetch(0)
      close = scheduler.tick(now: Time.iso8601("2026-08-31T00:00:01Z")).fetch(0)

      assert_equal "daily_digest_refresh", refresh.fetch(:stage)
      assert_equal "daily_digest_close", close.fetch(:stage)
      assert_equal "daily_digest_close", close.fetch(:project)
      assert scheduler.pending?("2026-08-30", stage: "daily_digest_refresh")
      assert scheduler.pending?("2026-08-30", stage: "daily_digest_close")

      scheduler.complete(
        date: "2026-08-30", stage: "daily_digest_close", exit_code: 0,
        now: Time.iso8601("2026-08-31T00:00:02Z")
      )
      assert scheduler.pending?("2026-08-30", stage: "daily_digest_refresh")
      refute scheduler.pending?("2026-08-30", stage: "daily_digest_close")
    end
  end

  def test_reconfiguration_failure_backoff_and_state_write_errors_are_independent
    with_tmp_dir do |dir|
      now = Time.iso8601("2026-08-30T12:00:00Z")
      scheduler = Hive::Daemon::DailyDigestCloseScheduler.new(
        state_path: File.join(dir, "state.json"), enabled: false, interval_sec: 300,
        date_resolver: ->(_instant) { "2026-08-30" }
      )
      scheduler.reconfigure(enabled: true, interval_sec: "60")
      assert_equal 1, scheduler.tick(now: now).size
      assert_nil scheduler.complete(date: "2026-08-30", exit_code: 1, now: now)
      assert_empty scheduler.tick(now: now + 30)

      scheduler.tick(now: now + 60)
      scheduler.define_singleton_method(:write_state) { |_value| raise IOError, "disk failed" }
      assert_raises(IOError) do
        scheduler.complete(date: "2026-08-30", exit_code: 0, now: now + 60)
      end
    end
  end

  def test_stage_and_date_resolution_use_persisted_intervals_then_configured_zone
    open_interval = Hive::DailyDigest::Calendar.new(time_zone: "UTC")
                                               .interval_for("2026-08-30", sequence: 1)
    store = Object.new
    store.define_singleton_method(:read) do |_date|
      { "lifecycle" => "closed", "ends_at" => open_interval.fetch("ends_at") }
    end
    store.define_singleton_method(:intervals) { [ open_interval ] }
    scheduler = Hive::Daemon::DailyDigestCloseScheduler.new(
      enabled: true, store: store, config_loader: -> { { "time_zone" => "Pacific/Honolulu" } }
    )
    now = Time.iso8601("2026-08-30T12:00:00Z")

    assert_equal "daily_digest_close", scheduler.send(:stage_for, "2026-08-30", now: now)
    assert_equal "2026-08-30", scheduler.send(:resolve_date, now)

    store.define_singleton_method(:intervals) { [] }
    assert_equal "2026-08-30", scheduler.send(:resolve_date, now)
  end

  def test_malformed_state_time_and_invalid_intervals_are_typed
    messages = []
    logger = Object.new
    logger.define_singleton_method(:event) { |event, **payload| messages << [ event, payload ] }
    scheduler = Hive::Daemon::DailyDigestCloseScheduler.new(
      enabled: true, interval_sec: 300, logger: logger
    )

    assert_nil scheduler.send(:parse_time, "bad-time")
    refute_empty messages
    [ 0, "bad" ].each do |value|
      assert_raises(ArgumentError) { scheduler.reconfigure(enabled: true, interval_sec: value) }
    end
  end

  def test_pending_cancellation_and_ambiguous_completion_are_typed
    with_tmp_dir do |dir|
      events = []
      logger = Object.new
      logger.define_singleton_method(:event) { |event, **payload| events << [ event, payload ] }
      store = Object.new
      store.define_singleton_method(:read) do |_date|
        raise Hive::DailyDigest::Error, "missing"
      end
      now = Time.iso8601("2026-08-30T12:00:00Z")
      scheduler = Hive::Daemon::DailyDigestCloseScheduler.new(
        state_path: File.join(dir, "state.json"), enabled: true, interval_sec: 300,
        logger: logger, store: store, date_resolver: ->(_instant) { "2026-08-30" }
      )

      scheduler.tick(now: now)
      assert scheduler.pending?("2026-08-30")
      scheduler.cancel(date: "2026-08-30", stage: "daily_digest_close")
      refute scheduler.pending?("2026-08-30")

      pending = scheduler.instance_variable_get(:@pending)
      pending.fetch("daily_digest_refresh")["2026-08-30"] = true
      pending.fetch("daily_digest_close")["2026-08-30"] = true
      error = assert_raises(ArgumentError) do
        scheduler.complete(date: "2026-08-30", exit_code: 0, now: now)
      end
      assert_match(/completion stage is ambiguous/, error.message)
      assert_equal :daily_digest_scheduler_failure_backoff, events.last.fetch(0)
      assert_equal 60, events.last.fetch(1).fetch(:retry_after_sec)

      scheduler.cancel(date: "2026-08-30")
      refute scheduler.pending?("2026-08-30")
      assert_raises(ArgumentError) do
        scheduler.cancel(date: "2026-08-30", stage: "unknown")
      end

      scheduler.complete(date: "2026-08-31", exit_code: 0, now: now + 1)
      assert File.file?(File.join(dir, "state.json"))
    end
  end
end
