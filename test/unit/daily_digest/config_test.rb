require "test_helper"
require "hive/config"

class DailyDigestConfigTest < Minitest::Test
  include HiveTestHelper

  def test_disabled_defaults_are_safe_and_do_not_require_initialization
    with_tmp_global_config do
      config = Hive::Config.load_global_daily_digest

      assert_equal false, config.fetch("enabled")
      assert_nil config.fetch("time_zone")
      assert_equal 300, config.fetch("materialization_interval_sec")
      assert_equal false, config.dig("telegram", "enabled")
      assert_equal 9, config.dig("telegram", "hour")
    end
  end

  def test_enabled_digest_requires_valid_zone_and_coverage_frontier
    with_tmp_global_config do |home|
      path = File.join(home, "config.yml")
      File.write(path, { "daily_digest" => { "enabled" => true } }.to_yaml)
      error = assert_raises(Hive::ConfigError) { Hive::Config.load_global_daily_digest }
      assert_match(/daily_digest\.time_zone.*required/, error.message)

      File.write(path, { "daily_digest" => initialized_config("Mars/Olympus") }.to_yaml)
      error = assert_raises(Hive::ConfigError) { Hive::Config.load_global_daily_digest }
      assert_match(/unknown IANA time zone/, error.message)

      File.write(path, { "daily_digest" => initialized_config("Europe/London") }.to_yaml)
      assert_equal true, Hive::Config.load_global_daily_digest.fetch("enabled")
    end
  end

  def test_scalar_block_and_invalid_nested_values_are_typed_config_errors
    with_tmp_global_config do |home|
      path = File.join(home, "config.yml")
      File.write(path, "daily_digest: enabled\n")
      assert_match(/daily_digest.*must be a Hash/,
                   assert_raises(Hive::ConfigError) { Hive::Config.load_global_daily_digest }.message)

      File.write(path, { "daily_digest" => { "materialization_interval_sec" => 0 } }.to_yaml)
      assert_match(/materialization_interval_sec.*integer >= 1/,
                   assert_raises(Hive::ConfigError) { Hive::Config.load_global_daily_digest }.message)

      File.write(path, { "daily_digest" => { "telegram" => true } }.to_yaml)
      assert_match(/daily_digest\.telegram.*must be a Hash/,
                   assert_raises(Hive::ConfigError) { Hive::Config.load_global_daily_digest }.message)
    end
  end

  private

  def initialized_config(zone)
    {
      "enabled" => true,
      "time_zone" => zone,
      "coverage_started_at" => "2026-08-30T12:00:00.000000Z",
      "initial_membership" => [],
      "first_interval" => {
        "local_date" => "2026-08-30",
        "time_zone" => zone,
        "starts_at" => "2026-08-29T23:00:00.000000Z",
        "ends_at" => "2026-08-30T23:00:00.000000Z"
      }
    }
  end
end
