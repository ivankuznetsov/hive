require "test_helper"
require "hive/london_date"

class HiveLondonDateTest < Minitest::Test
  include HiveTestHelper

  def test_today_uses_london_even_when_host_timezone_differs
    with_env("TZ" => "America/Los_Angeles") do
      assert_equal Date.new(2026, 6, 14), Hive::LondonDate.today(now: Time.utc(2026, 6, 14, 0, 30))
    end
  end

  def test_today_tracks_both_london_dst_transitions
    assert_equal Date.new(2026, 3, 28), Hive::LondonDate.today(now: Time.utc(2026, 3, 28, 23, 59))
    assert_equal Date.new(2026, 3, 29), Hive::LondonDate.today(now: Time.utc(2026, 3, 29, 0, 0))
    assert_equal Date.new(2026, 10, 25), Hive::LondonDate.today(now: Time.utc(2026, 10, 24, 23, 0))
    assert_equal Date.new(2026, 10, 26), Hive::LondonDate.today(now: Time.utc(2026, 10, 26, 0, 0))
  end

  def test_parse_is_strict
    assert_equal Date.new(2026, 6, 13), Hive::LondonDate.parse("2026-06-13")
    assert_raises(Date::Error) { Hive::LondonDate.parse("13 June 2026") }
  end
end
