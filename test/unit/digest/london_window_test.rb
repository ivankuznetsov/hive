require "test_helper"
require "hive/digest/london_window"

class HiveDigestLondonWindowTest < Minitest::Test
  include HiveTestHelper

  def test_uses_london_midnight_when_host_timezone_differs
    with_env("TZ" => "America/Los_Angeles") do
      date = Date.new(2026, 6, 13)

      refute Hive::Digest::LondonWindow.on_date?("2026-06-12T22:59:59Z", date)
      assert Hive::Digest::LondonWindow.on_date?("2026-06-12T23:00:00Z", date)
      assert Hive::Digest::LondonWindow.on_date?("2026-06-13T22:59:59Z", date)
      refute Hive::Digest::LondonWindow.on_date?("2026-06-13T23:00:00Z", date)
    end
  end

  def test_utc_bounds_cover_ordinary_and_dst_transition_days
    assert_equal [ Time.utc(2026, 1, 13), Time.utc(2026, 1, 14) ],
                 Hive::Digest::LondonWindow.utc_bounds(Date.new(2026, 1, 13))
    assert_equal [ Time.utc(2026, 6, 12, 23), Time.utc(2026, 6, 13, 23) ],
                 Hive::Digest::LondonWindow.utc_bounds(Date.new(2026, 6, 13))
    assert_equal 23 * 60 * 60,
                 bounds_duration(Date.new(2026, 3, 29))
    assert_equal 25 * 60 * 60,
                 bounds_duration(Date.new(2026, 10, 25))
  end

  def test_previous_day_uses_london_date_not_host_date
    with_env("TZ" => "America/Los_Angeles") do
      now = Time.utc(2026, 6, 14, 0, 30)

      assert_equal Date.new(2026, 6, 13),
                   Hive::Digest::LondonWindow.previous_day(now: now)
    end
  end

  def test_parse_date_is_strict
    assert_equal Date.new(2026, 6, 13), Hive::Digest::LondonWindow.parse_date("2026-06-13")
    assert_raises(ArgumentError) { Hive::Digest::LondonWindow.parse_date("13 June 2026") }
  end

  private

  def bounds_duration(date)
    start_at, end_at = Hive::Digest::LondonWindow.utc_bounds(date)
    end_at - start_at
  end
end
