require "test_helper"
require "hive/local_date_window"

class HiveLocalDateWindowTest < Minitest::Test
  include HiveTestHelper

  def test_local_today_uses_host_timezone
    with_env("TZ" => "America/Los_Angeles") do
      now = Time.utc(2026, 6, 14, 6, 59, 59)

      assert_equal Date.new(2026, 6, 13), Hive::LocalDateWindow.local_today(now: now)
    end
  end

  def test_previous_local_day_uses_host_timezone
    with_env("TZ" => "America/Los_Angeles") do
      now = Time.utc(2026, 6, 14, 6, 59, 59)

      assert_equal Date.new(2026, 6, 12), Hive::LocalDateWindow.previous_local_day(now: now)
    end
  end
end
