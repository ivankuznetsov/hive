require "test_helper"
require "hive/daemon/daily_digest_delivery_scheduler"
require "hive/daily_digest/calendar"

class HiveDaemonDailyDigestDeliverySchedulerTest < Minitest::Test
  include HiveTestHelper

  def test_targets_preceding_closed_interval_at_configured_hour_once
    with_tmp_dir do |dir|
      store = build_store(dir, zone: "Europe/London", dates: %w[2026-08-29 2026-08-30])
      state_path = File.join(dir, "scheduler.json")
      scheduler = Hive::Daemon::DailyDigestDeliveryScheduler.new(
        state_path: state_path, enabled: true, hour: 9, store: store
      )

      assert_empty scheduler.tick(now: Time.iso8601("2026-08-30T07:59:59Z"))
      dispatch = scheduler.tick(now: Time.iso8601("2026-08-30T08:00:00Z")).fetch(0)
      assert_equal "2026-08-29", dispatch.fetch(:slug)
      assert_equal "daily_digest_delivery", dispatch.fetch(:stage)
      assert_equal "hive digest send --date 2026-08-29 --json", dispatch.fetch(:command)
      assert_empty scheduler.tick(now: Time.iso8601("2026-08-30T08:01:00Z"))

      scheduler.complete(
        date: "2026-08-29", exit_code: 0,
        envelope: { "outcome" => "sent" }, now: Time.iso8601("2026-08-30T08:02:00Z")
      )
      restarted = Hive::Daemon::DailyDigestDeliveryScheduler.new(
        state_path: state_path, enabled: true, hour: 9, store: store
      )
      assert_empty restarted.tick(now: Time.iso8601("2026-08-30T10:00:00Z"))
      assert_equal "sent", JSON.parse(File.read(state_path)).fetch("last_outcome")
    end
  end

  def test_sequence_navigation_survives_nonconsecutive_zone_cutover_labels
    with_tmp_dir do |dir|
      store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
      first = Hive::DailyDigest::Calendar.new(time_zone: "Pacific/Honolulu")
                                        .interval_for("2026-08-29", sequence: 1)
      second = Hive::DailyDigest::Calendar.cutover_interval(
        previous: first, time_zone: "Pacific/Kiritimati",
        requested_at: first.fetch("ends_at"), sequence: 2
      )
      store.write_base(record(first, lifecycle: "closed"))
      store.write_base(record(second, lifecycle: "open"))
      scheduler = Hive::Daemon::DailyDigestDeliveryScheduler.new(
        state_path: File.join(dir, "state.json"), enabled: true, hour: 9, store: store
      )
      now = Time.iso8601(second.fetch("starts_at")) + (10 * 3_600)

      dispatch = scheduler.tick(now: now).fetch(0)
      assert_equal first.fetch("local_date"), dispatch.fetch(:slug)
      refute_equal Date.iso8601(second.fetch("local_date")).prev_day.iso8601,
                   dispatch.fetch(:slug)
    end
  end

  def test_nonzero_completion_backs_off_and_disabled_or_pruned_targets_do_not_dispatch
    with_tmp_dir do |dir|
      store = build_store(dir, zone: "UTC", dates: %w[2026-08-29 2026-08-30])
      now = Time.iso8601("2026-08-30T09:00:00Z")
      scheduler = Hive::Daemon::DailyDigestDeliveryScheduler.new(
        state_path: File.join(dir, "state.json"), enabled: true, hour: 9, store: store
      )
      assert_equal 1, scheduler.tick(now: now).length
      scheduler.complete(date: "2026-08-29", exit_code: 1, now: now)
      assert_empty scheduler.tick(now: now + 30)
      assert_equal 1, scheduler.tick(now: now + 60).length

      disabled = Hive::Daemon::DailyDigestDeliveryScheduler.new(
        enabled: false, store: store
      )
      assert_empty disabled.tick(now: now)

      scheduler.cancel(date: "2026-08-29")
      store.prune("2026-08-29", pruned_at: now, reason: "test")
      assert_empty scheduler.tick(now: now + 120)
    end
  end

  private

  def build_store(dir, zone:, dates:)
    store = Hive::DailyDigest::Store.new(root: File.join(dir, "digest"))
    calendar = Hive::DailyDigest::Calendar.new(time_zone: zone)
    dates.each_with_index do |date, index|
      interval = calendar.interval_for(date, sequence: index + 1)
      lifecycle = index == dates.length - 1 ? "open" : "closed"
      store.write_base(record(interval, lifecycle: lifecycle))
    end
    store
  end

  def record(interval, lifecycle:)
    {
      "schema" => "hive-digest-record", "schema_version" => 1,
      **interval,
      "lifecycle" => lifecycle,
      "closed_at" => lifecycle == "closed" ? interval.fetch("ends_at") : nil,
      "completeness" => "complete", "content" => "empty",
      "last_materialized_at" => interval.fetch("starts_at"),
      "projects" => [], "items" => [], "attention" => [], "gaps" => [],
      "source_frontiers" => {}
    }
  end
end
