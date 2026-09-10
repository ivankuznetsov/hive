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

  def test_initializes_legacy_registry_identity_before_snapshotting_coverage
    assert_legacy_registry_coverage({})
  end

  def test_initializes_missing_registration_epoch_without_replacing_project_identity
    assert_legacy_registry_coverage("project_id" => "12345678-1234-4234-a234-123456789012")
  end

  def assert_legacy_registry_coverage(identity)
    with_tmp_global_config do
      row = { "name" => "legacy", "path" => "/missing/legacy" }.merge(identity)
      File.write(Hive::Config.global_config_path, { "registered_projects" => [ row ] }.to_yaml)
      migration = Hive::DailyDigest::Migration.new(detector: -> { "UTC" }, now: -> { NOW })
      result = migration.call
      persisted = YAML.safe_load_file(Hive::Config.global_config_path)
      registered = persisted.fetch("registered_projects").first
      member = result.fetch("initial_membership").first
      refute_nil registered["registration_id"]
      assert_equal "legacy:#{registered.fetch('project_id')}", registered.fetch("registration_id")
      assert_equal registered.fetch("registration_id"), member.fetch("registration_id")
      assert_equal registered.fetch("project_id"), member.fetch("project_id")
      assert_equal NOW.iso8601(6), registered.fetch("registered_at")
      assert_equal identity["project_id"], registered.fetch("project_id") if identity.key?("project_id")
      refute persisted.key?("project_membership_history")
      original = File.read(Hive::Config.global_config_path)
      assert_equal result, migration.call
      refute Hive::Config.ensure_project_identities!(now: NOW + 86_400)
      assert_equal original, File.read(Hive::Config.global_config_path)
    end
  end

  def test_failed_snapshot_does_not_persist_registry_identity_or_coverage
    with_tmp_global_config do
      original = { "registered_projects" => [ { "name" => "legacy", "path" => "/missing/legacy" } ] }.to_yaml
      File.write(Hive::Config.global_config_path, original)
      migration = Hive::DailyDigest::Migration.new(
        detector: -> { "UTC" }, now: -> { NOW },
        projects: -> { raise Hive::ConfigError, "snapshot failed" }
      )

      assert_raises(Hive::DailyDigest::Migration::InitializationError) { migration.call }
      assert_equal original, File.read(Hive::Config.global_config_path)
    end
  end

  def test_existing_snapshot_and_registration_history_are_preserved
    with_tmp_global_config do
      row = {
        "name" => "demo", "path" => "/missing/demo",
        "project_id" => "12345678-1234-4234-a234-123456789012",
        "registration_id" => "historic-epoch", "registered_at" => "2026-01-01T00:00:00Z"
      }
      history = [ { "kind" => "registered", "after" => row.dup } ]
      File.write(Hive::Config.global_config_path, {
        "registered_projects" => [ row ], "project_membership_history" => history
      }.to_yaml)
      migration = Hive::DailyDigest::Migration.new(detector: -> { "UTC" }, now: -> { NOW })
      result = migration.call
      assert_equal "historic-epoch", result.fetch("initial_membership").first.fetch("registration_id")
      persisted = YAML.safe_load_file(Hive::Config.global_config_path)
      assert_equal [ row ], persisted.fetch("registered_projects")
      assert_equal history, persisted.fetch("project_membership_history")
      original = File.read(Hive::Config.global_config_path)
      later = Hive::DailyDigest::Migration.new(
        detector: -> { flunk "must not redetect historic zone" },
        projects: -> { flunk "must not resnapshot historic membership" }, now: -> { NOW + 86_400 }
      )
      assert_equal result, later.call
      assert_equal original, File.read(Hive::Config.global_config_path)
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

  def test_detector_reads_timezone_file_and_ignores_read_failures
    with_tmp_dir do |dir|
      timezone_file = File.join(dir, "timezone")
      File.write(timezone_file, "Europe/London\n")
      detector = Hive::DailyDigest::TimeZoneDetector.new(
        environment: {}, timezone_file: timezone_file, localtime_file: "/missing"
      )
      assert_equal "Europe/London", detector.call

      with_replaced_singleton_method(
        File, :read, ->(*_args) { raise Errno::EACCES, "denied" }
      ) do
        unavailable = Hive::DailyDigest::TimeZoneDetector.new(
          environment: {}, timezone_file: timezone_file, localtime_file: "/missing"
        )
        assert_raises(Hive::DailyDigest::Migration::InitializationError) { unavailable.call }
      end
    end
  end

  def test_migration_rejects_scalar_config_invalid_zone_and_clock
    with_tmp_global_config do
      File.write(Hive::Config.global_config_path, { "daily_digest" => "bad" }.to_yaml)
      error = assert_raises(Hive::DailyDigest::Migration::InitializationError) do
        Hive::DailyDigest::Migration.new.call
      end
      assert_match(/must be a Hash/, error.message)
    end

    with_tmp_global_config do
      File.write(
        Hive::Config.global_config_path,
        { "daily_digest" => { "enabled" => false, "time_zone" => "Mars/Olympus" } }.to_yaml
      )
      error = assert_raises(Hive::DailyDigest::Migration::InitializationError) do
        Hive::DailyDigest::Migration.new(now: -> { NOW }).call
      end
      assert_match(/unknown IANA time zone/, error.message)
    end

    with_tmp_global_config do
      error = assert_raises(Hive::DailyDigest::Migration::InitializationError) do
        Hive::DailyDigest::Migration.new(
          detector: -> { "UTC" }, projects: -> { [ nil ] }, now: -> { "bad-time" }
        ).call
      end
      assert_match(/migration clock is invalid/, error.message)
    end
  end
end
