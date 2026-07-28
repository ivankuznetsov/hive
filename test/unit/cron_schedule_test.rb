require "test_helper"
require "hive/cron_schedule"

class CronScheduleTest < Minitest::Test
  NOW = Time.utc(2026, 7, 27, 12, 15)

  def test_parses_and_matches_the_shared_five_field_grammar
    assert Hive::CronSchedule.valid?("*/5 9-17 * * 1-5")
    assert Hive::CronSchedule.match?("*/5 9-17 * * 1-5", NOW)
    refute Hive::CronSchedule.match?("*/10 9-17 * * 1-5", NOW)
  end

  def test_rejects_every_malformed_comma_step_range_and_domain
    [
      "* * * *",
      "61 * * * *",
      "*/0 * * * *",
      "1, * * * *",
      "1,2, * * * *",
      "15,bad * * * *",
      "1//2 * * * *",
      "5-1 * * * *",
      "bad * * * *"
    ].each do |schedule|
      refute Hive::CronSchedule.valid?(schedule), schedule
      assert_raises(Hive::ConfigError) do
        Hive::CronSchedule.match?(schedule, NOW)
      end
    end
  end
end
