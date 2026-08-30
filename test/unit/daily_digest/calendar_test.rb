require "test_helper"
require "hive/daily_digest/calendar"

class DailyDigestCalendarTest < Minitest::Test
  include HiveTestHelper

  def test_london_spring_and_fall_days_keep_exact_utc_boundaries
    calendar = Hive::DailyDigest::Calendar.new(time_zone: "Europe/London")

    assert_equal Date.iso8601("2026-03-29"),
                 calendar.local_date_at("2026-03-29T12:00:00Z")

    spring = calendar.interval_for("2026-03-29")
    assert_equal "2026-03-29T00:00:00.000000Z", spring.fetch("starts_at")
    assert_equal "2026-03-29T23:00:00.000000Z", spring.fetch("ends_at")
    assert_equal 23 * 60 * 60, spring.fetch("duration_seconds")

    fall = calendar.interval_for("2026-10-25")
    assert_equal "2026-10-24T23:00:00.000000Z", fall.fetch("starts_at")
    assert_equal "2026-10-26T00:00:00.000000Z", fall.fetch("ends_at")
    assert_equal 25 * 60 * 60, fall.fetch("duration_seconds")
  end

  def test_zone_cutover_starts_at_previous_fixed_end_and_preserves_monotonic_label
    london = Hive::DailyDigest::Calendar.new(time_zone: "Europe/London")
    previous = london.interval_for("2026-08-30")
    cutover = Hive::DailyDigest::Calendar.cutover_interval(
      previous: previous,
      time_zone: "Pacific/Kiritimati",
      requested_at: Time.iso8601("2026-08-30T12:00:00Z")
    )

    assert_equal previous.fetch("ends_at"), cutover.fetch("starts_at")
    assert_equal "2026-08-31", cutover.fetch("local_date")
    assert_equal "zone_cutover", cutover.fetch("boundary_kind")
    assert_equal "Pacific/Kiritimati", cutover.fetch("time_zone")
    assert_equal "2026-08-30T12:00:00.000000Z", cutover.dig("cutover", "requested_at")
    assert_equal previous.fetch("ends_at"), cutover.dig("cutover", "effective_at")
  end

  def test_zone_cutover_records_wall_clock_labels_skipped_by_a_date_line_move
    previous = Hive::DailyDigest::Calendar.new(time_zone: "Pacific/Honolulu")
                                          .interval_for("2026-08-30", sequence: 7)

    cutover = Hive::DailyDigest::Calendar.cutover_interval(
      previous: previous,
      time_zone: "Pacific/Kiritimati",
      requested_at: previous.fetch("ends_at")
    )

    assert_equal "2026-09-01", cutover.fetch("local_date")
    assert_equal [ "2026-08-31" ], cutover.dig("cutover", "skipped_labels")
    assert_equal 8, cutover.fetch("sequence")
  end

  def test_rejects_unknown_iana_zone
    error = assert_raises(Hive::DailyDigest::Calendar::InvalidTimeZone) do
      Hive::DailyDigest::Calendar.new(time_zone: "Mars/Olympus")
    end
    assert_match(/unknown IANA time zone/, error.message)
  end

  def test_rejects_invalid_dates_instants_and_cutover_shapes
    calendar = Hive::DailyDigest::Calendar.new(time_zone: "UTC")
    assert_raises(Hive::DailyDigest::Calendar::InvalidInterval) do
      calendar.interval_for("not-a-date")
    end
    assert_raises(Hive::DailyDigest::Calendar::InvalidInterval) do
      calendar.local_date_at("not-an-instant")
    end
    assert_raises(Hive::DailyDigest::Calendar::InvalidInterval) do
      Hive::DailyDigest::Calendar.cutover_interval(
        previous: {}, time_zone: "UTC", requested_at: "2026-08-30T00:00:00Z"
      )
    end
  end

  def test_skipped_civil_date_uses_the_first_valid_wall_instant
    interval = Hive::DailyDigest::Calendar.new(time_zone: "Pacific/Apia")
                                                .interval_for("2011-12-30")

    assert_equal 0, interval.fetch("duration_seconds")
    assert_equal interval.fetch("starts_at"), interval.fetch("ends_at")
  end

  def test_cutover_and_midnight_resolution_reject_nonadvancing_zones
    previous = Hive::DailyDigest::Calendar.new(time_zone: "UTC")
                                          .interval_for("2026-08-30")
    fake = Object.new
    fake.define_singleton_method(:local_midnight_utc) { |_date| Time.iso8601(previous.fetch("ends_at")) }
    fake.define_singleton_method(:build_interval) { |**| flunk "invalid cutover must not build" }
    with_replaced_singleton_method(
      Hive::DailyDigest::Calendar, :new, ->(**) { fake }
    ) do
      assert_raises(Hive::DailyDigest::Calendar::InvalidInterval) do
        Hive::DailyDigest::Calendar.cutover_interval(
          previous: previous, time_zone: "UTC", requested_at: previous.fetch("ends_at")
        )
      end
    end

    timezone = Object.new
    timezone.define_singleton_method(:periods_for_local) { |_wall| [] }
    unresolved = Hive::DailyDigest::Calendar.allocate
    unresolved.instance_variable_set(:@time_zone, "Test/NoMidnight")
    unresolved.instance_variable_set(:@timezone, timezone)
    assert_raises(Hive::DailyDigest::Calendar::InvalidInterval) do
      unresolved.send(:local_midnight_utc, Date.iso8601("2026-08-30"))
    end
  end
end
