require "test_helper"
require "hive/daily_digest/migration"

class DailyDigestMigrationTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.iso8601("2026-08-30T12:34:56Z")

  def test_initializes_zone_coverage_membership_and_first_interval_atomically
    with_tmp_global_config do |home|
      project = {
        "name" => "demo", "project_id" => "project-1", "registration_id" => "registration-1",
        "path" => "/tmp/demo", "hive_state_path" => "/tmp/demo/.hive-state"
      }
      migration = Hive::DailyDigest::Migration.new(
        detector: -> { "Europe/London" }, projects: -> { [ project ] }, now: -> { NOW }
      )

      result = migration.call
      persisted = YAML.safe_load_file(File.join(home, "config.yml")).fetch("daily_digest")
      assert_equal "Europe/London", persisted.fetch("time_zone")
      assert_equal NOW.iso8601(6), persisted.fetch("coverage_started_at")
      assert_equal [ project ], persisted.fetch("initial_membership")
      assert_equal "2026-08-30", persisted.dig("first_interval", "local_date")
      assert_equal persisted, result

      second = migration.call
      assert_equal persisted, second
      assert_equal persisted, YAML.safe_load_file(File.join(home, "config.yml")).fetch("daily_digest")
    end
  end

  def test_failed_detection_leaves_existing_feature_disabled
    with_tmp_global_config do |home|
      File.write(File.join(home, "config.yml"), { "daily_digest" => { "enabled" => false } }.to_yaml)
      migration = Hive::DailyDigest::Migration.new(
        detector: -> { raise Hive::DailyDigest::Migration::InitializationError, "zone unavailable" },
        projects: -> { [] }, now: -> { NOW }
      )

      assert_raises(Hive::DailyDigest::Migration::InitializationError) { migration.call }
      persisted = YAML.safe_load_file(File.join(home, "config.yml")).fetch("daily_digest")
      assert_equal false, persisted.fetch("enabled")
      refute persisted.key?("coverage_started_at")
    end
  end

  def test_detector_accepts_tz_environment_and_rejects_unknown_values
    assert_equal "Europe/London",
                 Hive::DailyDigest::TimeZoneDetector.new(environment: { "TZ" => "Europe/London" }).call
    detector = Hive::DailyDigest::TimeZoneDetector.new(
      environment: { "TZ" => "Mars/Olympus" }, timezone_file: "/missing", localtime_file: "/missing"
    )
    assert_raises(Hive::DailyDigest::Migration::InitializationError) { detector.call }
  end
end
