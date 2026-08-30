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
    end
  end
end
