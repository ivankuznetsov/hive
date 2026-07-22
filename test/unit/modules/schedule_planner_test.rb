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
end
