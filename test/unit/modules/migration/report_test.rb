require "test_helper"
require "digest"
require "hive/modules/migration/report_migration"

class ModulesMigrationReportTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 3, 12)

  def test_runtime_load_accepts_only_canonical_report_v2
    with_tmp_dir do |root|
      path = File.join(root, "report.json")
      projection = evidence_required_projection
      Hive::Modules::Migration::Report.write_projection(path, projection)

      assert_equal projection.to_h,
                   Hive::Modules::Migration::Report.load(path).to_h
      File.binwrite(path, JSON.pretty_generate(projection.to_h))
      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::Report.load(path)
      end
    end
  end

  def test_projection_write_uses_expected_report_cas
    with_tmp_dir do |root|
      path = File.join(root, "report.json")
      projection = evidence_required_projection
      Hive::Modules::Migration::Report.write_projection(path, projection)
      replacement = Hive::Modules::Migration::ReportProjection.build(
        qualifications: [], generated_at: NOW + 1,
        migration: projection.migration
      )

      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::Report.write_projection(path, replacement)
      end

      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::Report.write_projection(
          path, projection, expected_digest: "f" * 64
        )
      end
      assert_equal projection.to_h,
                   JSON.parse(File.binread(path))
    end
  end

  def test_legacy_builder_cannot_replace_v2_storage
    with_tmp_dir do |root|
      path = File.join(root, "report.json")
      projection = evidence_required_projection
      Hive::Modules::Migration::Report.write_projection(path, projection)
      legacy = Hive::Modules::Migration::Report.build(
        record_source: [], reviewer: "reviewer", reviewed_at: NOW
      )

      assert_raises(Hive::ConfigError) { legacy.write(path) }
      assert_equal projection.to_h,
                   Hive::Modules::Migration::Report.load(path).to_h
    end
  end

  def test_released_v1_success_and_error_shapes_remain_migration_inputs
    success = legacy_success
    success.fetch("modules").fetch("patrol")["configuration_digest"] = nil
    error = {
      "schema" => "hive-module-migration-report", "schema_version" => 1,
      "ok" => false, "error_kind" => "config_error", "exit_code" => 1,
      "message" => "unavailable", "error_class" => "ConfigError"
    }

    assert Hive::Modules::Migration::Report.valid_legacy_payload?(success)
    assert Hive::Modules::Migration::Report.valid_legacy_payload?(error)
    refute Hive::Modules::Migration::Report.valid_legacy_payload?(
      success.merge("unexpected" => true)
    )
    invalid_summary = legacy_success
    invalid_summary.fetch("modules").fetch("patrol")[
      "duplicate_effect_count"
    ] = -1
    refute Hive::Modules::Migration::Report.valid_legacy_payload?(
      invalid_summary
    )
    refute Hive::Modules::Migration::Report.valid_legacy_payload?(
      legacy_success.merge("reviewer" => 1)
    )
  end

  private

  def evidence_required_projection
    source = Hive::Modules::Migration::Report.canonical(legacy_success)
    digest = Digest::SHA256.hexdigest(source)
    Hive::Modules::Migration::ReportProjection.build(
      qualifications: [], generated_at: NOW,
      migration: {
        "source_schema_version" => 1,
        "source_digest" => digest,
        "archive_digest" => digest,
        "disposition" => "evidence_required"
      }
    )
  end

  def legacy_success
    modules = %w[patrol architecture-patrol].to_h do |module_name|
      [ module_name, {
        "decision_count" => 0, "started_at" => nil, "ended_at" => nil,
        "elapsed_seconds" => 0, "configuration_digest" => "a" * 64,
        "unexplained_difference_count" => 0,
        "duplicate_effect_count" => 0,
        "blockers" => [ "decision_count_below_10" ]
      } ]
    end
    {
      "schema" => "hive-module-migration-report", "schema_version" => 1,
      "generated_at" => NOW.iso8601(6), "reviewer" => "reviewer-1",
      "reviewed_at" => NOW.iso8601(6),
      "window" => { "started_at" => nil, "ended_at" => nil },
      "modules" => modules, "eligible" => false,
      "blockers" => [ "patrol:decision_count_below_10" ]
    }
  end
end
