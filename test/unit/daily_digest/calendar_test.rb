require "test_helper"
require "hive/daily_digest/calendar"

class DailyDigestCalendarTest < Minitest::Test
  def test_london_spring_and_fall_days_keep_exact_utc_boundaries
    calendar = Hive::DailyDigest::Calendar.new(time_zone: "Europe/London")

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

  def test_rejects_unknown_iana_zone
    error = assert_raises(Hive::DailyDigest::Calendar::InvalidTimeZone) do
      Hive::DailyDigest::Calendar.new(time_zone: "Mars/Olympus")
    end
    assert_match(/unknown IANA time zone/, error.message)
  end
end
