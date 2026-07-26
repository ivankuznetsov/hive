require "test_helper"
require "hive/modules/schedule_planner"

class ModulesSchedulePlannerTest < Minitest::Test
  def test_due_coalesces_downtime_to_latest_matching_minute
    planner = Hive::Modules::SchedulePlanner.new
    occurrence = planner.due(
      schedule: "*/5 * * * *",
      after: Time.utc(2026, 7, 22, 10, 1),
      now: Time.utc(2026, 7, 22, 10, 17)
    )

    assert_equal Time.utc(2026, 7, 22, 10, 15), occurrence.due_at
    assert_equal 2, occurrence.missed_windows
  end

  def test_invalid_fields_fail_closed
    planner = Hive::Modules::SchedulePlanner.new
    [ "* * * *", "61 * * * *", "*/0 * * * *", "bad * * * *" ].each do |schedule|
      assert_raises(Hive::ConfigError) do
        planner.match?(schedule, Time.utc(2026, 7, 22))
      end
    end
  end

  def test_ranges_empty_searches_and_invalid_timestamps_are_explicit
    planner = Hive::Modules::SchedulePlanner.new
    assert planner.match?("1-5 * * * *", Time.utc(2026, 7, 22, 10, 3))

    no_matches = Hive::Modules::SchedulePlanner.new
    no_matches.define_singleton_method(:match?) { |_schedule, _time| false }
    assert_nil no_matches.next_after(schedule: "* * * * *", now: Time.utc(2026, 7, 22))

    assert_raises(Hive::ConfigError) do
      planner.next_after(schedule: "* * * * *", now: "not-a-time")
    end
  end
end
