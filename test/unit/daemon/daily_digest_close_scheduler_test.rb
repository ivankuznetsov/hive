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
end
