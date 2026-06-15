require "test_helper"
require "hive/digest/window"

class HiveDigestWindowTest < Minitest::Test
  include HiveTestHelper

  def test_boundary_maps_by_local_calendar_date
    with_env("TZ" => "America/New_York") do
      assert Hive::Digest::Window.on_local_date?("2026-06-13T03:59:59Z", Date.new(2026, 6, 12))
      assert Hive::Digest::Window.on_local_date?("2026-06-13T04:00:00Z", Date.new(2026, 6, 13))
    end
  end

  def test_spring_forward_day_maps_to_one_local_date
    with_env("TZ" => "America/New_York") do
      date = Date.new(2026, 3, 8)

      assert Hive::Digest::Window.on_local_date?("2026-03-08T06:59:00Z", date)
      assert Hive::Digest::Window.on_local_date?("2026-03-08T07:00:00Z", date)
      assert Hive::Digest::Window.on_local_date?("2026-03-09T03:59:59Z", date)
      refute Hive::Digest::Window.on_local_date?("2026-03-09T04:00:00Z", date)
    end
  end

  def test_local_today_uses_host_timezone
    with_env("TZ" => "America/Los_Angeles") do
      now = Time.utc(2026, 6, 14, 6, 59, 59)

      assert_equal Date.new(2026, 6, 13), Hive::Digest::Window.local_today(now: now)
    end
  end
end
