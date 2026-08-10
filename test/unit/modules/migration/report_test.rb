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
      error = with_replaced_singleton_method(
        Hive::Modules::Migration::Report,
        :read_bytes,
        ->(*) { raise Errno::EIO }
      ) do
        assert_raises(Hive::ConfigError) do
          Hive::Modules::Migration::Report.load(path)
        end
      end
      assert_equal "module migration report is missing or unreadable",
                   error.message
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
      expected = Digest::SHA256.hexdigest(File.binread(path))
      assert_equal path,
                   Hive::Modules::Migration::Report.write_projection(
                     path, projection.to_h, expected_digest: expected
                   )
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

      v1_bytes = Hive::Modules::Migration::Report.canonical(legacy_success)
      File.binwrite(path, v1_bytes)
      error = assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::Report.write_projection(
          path, projection,
          expected_digest: Digest::SHA256.hexdigest(v1_bytes)
        )
      end
      assert_equal "module migration report v1 requires one-off migration",
                   error.message
      assert_equal v1_bytes, File.binread(path)
    end
  end

  def test_writers_reject_malformed_current_state_without_mutation
    projection = evidence_required_projection
    legacy = Hive::Modules::Migration::Report.build(
      record_source: [], reviewer: "reviewer", reviewed_at: NOW
    )
    malformed = [
      Hive::Modules::Migration::Report.canonical(nil),
      Hive::Modules::Migration::Report.canonical([]),
      Hive::Modules::Migration::Report.canonical("report"),
      Hive::Modules::Migration::Report.canonical(1),
      JSON.pretty_generate(legacy_success)
    ]

    malformed.each do |bytes|
      with_tmp_dir do |root|
        path = File.join(root, "report.json")
        File.binwrite(path, bytes)

        assert_raises(Hive::ConfigError) do
          Hive::Modules::Migration::Report.write_projection(path, projection)
        end
        assert_equal bytes, File.binread(path)
        assert_raises(Hive::ConfigError) { legacy.write(path) }
        assert_equal bytes, File.binread(path)
      end
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
    hostile_modules = legacy_success.fetch("modules").dup
    def hostile_modules.values = raise NoMethodError
    hostile = legacy_success.merge("modules" => hostile_modules)
    refute Hive::Modules::Migration::Report.valid_legacy_payload?(hostile)
  end

  def test_projection_write_rejects_oversized_serialization_before_storage
    with_tmp_dir do |root|
      path = File.join(root, "report.json")
      error = with_constant(
        Hive::Modules::Migration::Report, :MAX_REPORT_BYTES, 1
      ) do
        assert_raises(Hive::ConfigError) do
          Hive::Modules::Migration::Report.write_projection(
            path, evidence_required_projection
          )
        end
      end

      assert_equal "module migration report is malformed", error.message
      refute_path_exists path
    end
  end

  def test_writer_parser_fallbacks_are_typed_and_nonmutating
    with_tmp_dir do |root|
      path = File.join(root, "report.json")
      sentinel = "sentinel"
      File.binwrite(path, sentinel)
      parser_error = ->(*) { raise JSON::ParserError, "forced" }

      projection_error = with_replaced_singleton_method(
        Hive::Modules::Migration::ReportProjection, :from_h, parser_error
      ) do
        assert_raises(Hive::ConfigError) do
          Hive::Modules::Migration::Report.write_projection(
            path, evidence_required_projection
          )
        end
      end
      assert_equal "module migration report is malformed",
                   projection_error.message
      assert_equal sentinel, File.binread(path)

      legacy = Hive::Modules::Migration::Report.build(
        record_source: [], reviewer: "reviewer", reviewed_at: NOW
      )
      legacy_error = with_replaced_singleton_method(
        Hive::Modules::Migration::Report, :canonical, parser_error
      ) do
        assert_raises(Hive::ConfigError) { legacy.write(path) }
      end
      assert_equal "module migration report is malformed",
                   legacy_error.message
      assert_equal sentinel, File.binread(path)
    end
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

  def with_constant(owner, name, replacement)
    original = owner.const_get(name)
    owner.send(:remove_const, name)
    owner.const_set(name, replacement)
    yield
  ensure
    owner.send(:remove_const, name)
    owner.const_set(name, original)
  end
end
