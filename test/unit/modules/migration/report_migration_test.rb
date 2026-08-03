require "test_helper"
require "digest"
require "hive/modules/migration/report_migration"

class ModulesMigrationReportMigrationTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 3, 12)

  def test_forward_migration_archives_exact_v1_and_emits_evidence_required
    with_tmp_dir do |root|
      path = File.join(root, "report.json")
      source = legacy_success(configuration_digest: nil)
      File.binwrite(path, Hive::Modules::Migration::Report.canonical(source))

      report = Hive::Modules::Migration::ReportMigration.forward(
        path: path, qualifications: [], generated_at: NOW
      )

      assert_equal "evidence_required", report.status
      assert_equal 2, report.payload.fetch("schema_version")
      assert_equal 1, report.migration.fetch("source_schema_version")
      assert_equal Digest::SHA256.hexdigest(
        Hive::Modules::Migration::Report.canonical(source)
      ), report.migration.fetch("source_digest")
      assert_equal Hive::Modules::Migration::Report.canonical(source),
                   File.binread(File.join(root, "report.v1.archive.json"))
      assert_equal report.to_h,
                   Hive::Modules::Migration::Report.load(path).to_h
    end
  end

  def test_complete_authoritative_qualifications_project_during_migration
    with_tmp_dir do |root|
      path = File.join(root, "report.json")
      File.binwrite(
        path,
        Hive::Modules::Migration::Report.canonical(legacy_success)
      )
      report = Hive::Modules::Migration::ReportMigration.forward(
        path: path,
        qualifications: [
          qualification("deterministic"),
          qualification("installed_live")
        ],
        generated_at: NOW
      )

      assert report.eligible?
      assert_equal "projected", report.migration.fetch("disposition")
      assert_equal %w[deterministic installed_live],
                   report.lanes.keys
    end
  end

  def test_forward_migration_is_idempotent_and_retention_is_fixed
    with_tmp_dir do |root|
      path = File.join(root, "report.json")
      File.binwrite(
        path,
        Hive::Modules::Migration::Report.canonical(legacy_error)
      )
      first = Hive::Modules::Migration::ReportMigration.forward(
        path: path, qualifications: [], generated_at: NOW
      )
      first_bytes = File.binread(path)
      second = Hive::Modules::Migration::ReportMigration.forward(
        path: path, qualifications: [], generated_at: NOW + 60
      )

      assert_equal first.report_id, second.report_id
      assert_equal first_bytes, File.binread(path)
      assert_equal %w[
        .mutation.lock report.json report.migration.json
        report.v1.archive.json
      ], Dir.children(root).sort
    end
  end

  def test_migration_receipt_does_not_bind_later_report_replacement
    with_tmp_dir do |root|
      path = File.join(root, "report.json")
      File.binwrite(
        path,
        Hive::Modules::Migration::Report.canonical(legacy_success)
      )
      migrated = Hive::Modules::Migration::ReportMigration.forward(
        path: path, qualifications: [], generated_at: NOW
      )
      receipt_path = File.join(root, "report.migration.json")
      receipt_bytes = File.binread(receipt_path)
      replacement = Hive::Modules::Migration::ReportProjection.merge(
        existing: migrated,
        qualification: qualification("deterministic"),
        generated_at: NOW + 60
      )
      Hive::Modules::Migration::Report.write_projection(
        path, replacement,
        expected_digest: Digest::SHA256.hexdigest(File.binread(path))
      )

      loaded = Hive::Modules::Migration::ReportMigration.forward(
        path: path, qualifications: [], generated_at: NOW + 120
      )
      assert_equal replacement.report_id, loaded.report_id
      assert_equal receipt_bytes, File.binread(receipt_path)
    end
  end

  def test_missing_receipt_after_successor_fails_closed_without_reconstruction
    with_tmp_dir do |root|
      path = File.join(root, "report.json")
      File.binwrite(
        path,
        Hive::Modules::Migration::Report.canonical(legacy_success)
      )
      migrated = Hive::Modules::Migration::ReportMigration.forward(
        path: path, qualifications: [], generated_at: NOW
      )
      replacement = Hive::Modules::Migration::ReportProjection.merge(
        existing: migrated,
        qualification: qualification("deterministic"),
        generated_at: NOW + 60
      )
      Hive::Modules::Migration::Report.write_projection(
        path, replacement,
        expected_digest: Digest::SHA256.hexdigest(File.binread(path))
      )
      receipt_path = File.join(root, "report.migration.json")
      File.delete(receipt_path)

      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::ReportMigration.required?(path)
      end
      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::ReportMigration.forward(
          path: path, qualifications: [], generated_at: NOW + 120
        )
      end
      refute_path_exists receipt_path
    end
  end

  def test_reverse_migration_restores_exact_released_shape_with_caller_cas
    with_tmp_dir do |root|
      path = File.join(root, "report.json")
      source_bytes = Hive::Modules::Migration::Report.canonical(legacy_error)
      File.binwrite(path, source_bytes)
      Hive::Modules::Migration::ReportMigration.forward(
        path: path, qualifications: [], generated_at: NOW
      )
      receipt_path = File.join(root, "report.migration.json")
      receipt_bytes = File.binread(receipt_path)
      expected = Digest::SHA256.hexdigest(File.binread(path))

      Hive::Modules::Migration::ReportMigration.reverse(
        path: path, expected_digest: expected
      )

      assert_equal source_bytes, File.binread(path)
      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::Report.load(path)
      end
      assert_raises(ArgumentError) do
        Hive::Modules::Migration::ReportMigration.reverse(path: path)
      end

      remigrated = Hive::Modules::Migration::ReportMigration.forward(
        path: path, qualifications: [], generated_at: NOW + 60
      )
      assert_equal 2, remigrated.payload.fetch("schema_version")
      assert_equal receipt_bytes, File.binread(receipt_path)
      refute Hive::Modules::Migration::ReportMigration.required?(path)
    end
  end

  def test_descriptor_safe_lock_refuses_symlink_without_touching_target
    with_tmp_dir do |root|
      path = File.join(root, "report.json")
      File.binwrite(
        path,
        Hive::Modules::Migration::Report.canonical(legacy_success)
      )
      outside = File.join(root, "outside.lock")
      File.binwrite(outside, "sentinel")
      File.symlink(outside, File.join(root, ".mutation.lock"))

      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::ReportMigration.forward(
          path: path, qualifications: [], generated_at: NOW
        )
      end
      assert_equal "sentinel", File.binread(outside)
      assert_equal 1, JSON.parse(File.binread(path)).fetch("schema_version")
    end
  end

  def test_required_detects_only_canonical_v1_input
    with_tmp_dir do |root|
      path = File.join(root, "report.json")
      refute Hive::Modules::Migration::ReportMigration.required?(path)
      File.binwrite(
        path,
        Hive::Modules::Migration::Report.canonical(legacy_success)
      )
      assert Hive::Modules::Migration::ReportMigration.required?(path)
      Hive::Modules::Migration::ReportMigration.forward(
        path: path, qualifications: [], generated_at: NOW
      )
      refute Hive::Modules::Migration::ReportMigration.required?(path)
    end
  end

  def test_canonical_non_object_reports_fail_with_the_typed_error
    with_tmp_dir do |root|
      path = File.join(root, "report.json")
      [ nil, [], "report", 1 ].each do |value|
        File.binwrite(
          path, Hive::Modules::Migration::Report.canonical(value)
        )
        assert_raises(Hive::ConfigError) do
          Hive::Modules::Migration::ReportMigration.required?(path)
        end
        assert_raises(Hive::ConfigError) do
          Hive::Modules::Migration::ReportMigration.forward(
            path: path, qualifications: [], generated_at: NOW
          )
        end
      end
    end
  end

  def test_required_fails_closed_on_forged_archive_provenance
    with_tmp_dir do |root|
      path = File.join(root, "report.json")
      source = Hive::Modules::Migration::Report.canonical(legacy_success)
      File.binwrite(path, source)
      Hive::Modules::Migration::ReportMigration.forward(
        path: path, qualifications: [], generated_at: NOW
      )
      archive_path = File.join(root, "report.v1.archive.json")
      File.binwrite(
        archive_path,
        Hive::Modules::Migration::Report.canonical(legacy_error)
      )

      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::ReportMigration.required?(path)
      end

      File.binwrite(archive_path, source)
      receipt_path = File.join(root, "report.migration.json")
      receipt = JSON.parse(File.binread(receipt_path))
      receipt["source_name"] = "foreign-report.json"
      File.binwrite(
        receipt_path, Hive::Modules::Migration::Report.canonical(receipt)
      )
      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::ReportMigration.required?(path)
      end
    end
  end

  private

  def legacy_success(configuration_digest: "a" * 64)
    modules = %w[patrol architecture-patrol].to_h do |module_name|
      [ module_name, {
        "decision_count" => 10,
        "started_at" => "2026-07-01T00:00:00.000000Z",
        "ended_at" => "2026-07-08T00:00:00.000000Z",
        "elapsed_seconds" => 604_800,
        "configuration_digest" => configuration_digest,
        "unexplained_difference_count" => 0,
        "duplicate_effect_count" => 0,
        "blockers" => []
      } ]
    end
    {
      "schema" => "hive-module-migration-report",
      "schema_version" => 1,
      "generated_at" => "2026-07-08T00:00:00.000000Z",
      "reviewer" => "reviewer-1",
      "reviewed_at" => "2026-07-08T00:00:00.000000Z",
      "window" => {
        "started_at" => "2026-07-01T00:00:00.000000Z",
        "ended_at" => "2026-07-08T00:00:00.000000Z"
      },
      "modules" => modules,
      "eligible" => true,
      "blockers" => []
    }
  end

  def legacy_error
    {
      "schema" => "hive-module-migration-report",
      "schema_version" => 1,
      "ok" => false,
      "error_kind" => "config_error",
      "exit_code" => 1,
      "message" => "legacy report unavailable"
    }
  end

  def qualification(lane)
    modules = %w[patrol architecture-patrol].to_h do |module_name|
      [ module_name, {
        "decision_count" => 10,
        "decision_identities" => 10.times.map do |index|
          "decision-#{Digest::SHA256.hexdigest(
            "#{lane}:#{module_name}:#{index}"
          )}"
        end.sort.freeze,
        "decision_classes" => %w[negative positive],
        "repository_shas" => [ "7" * 40, "8" * 40 ],
        "change_windows" => %w[window-0 window-1],
        "configuration_digest" =>
          (module_name == "patrol" ? "5" : "a") * 64,
        "elapsed_seconds" => 9,
        "blockers" => []
      }.freeze ]
    end.freeze
    Hive::Modules::Migration::PatrolQualification.send(
      :create,
      {
        lane: lane, run_id: "run-#{lane}", candidate_sha: "1" * 40,
        catalog_digest: "2" * 64, source_digest: "3" * 64,
        manifest_digest: "4" * 64,
        scenario_manifest_digest: "6" * 64, status: "qualified",
        receipt_ids: 20.times.map do |index|
          "evidence-#{Digest::SHA256.hexdigest("#{lane}:#{index}")}"
        end.sort.freeze,
        decision_replay_count: 0, modules: modules, effect_count: 0,
        effect_replay_count: 0, duplicate_effects: [].freeze,
        unsettled_effects: [].freeze,
        elapsed_seconds: 9, blockers: [].freeze, supersedes: nil,
        contradiction: nil, generated_at: NOW.iso8601(6)
      }
    )
  end
end
