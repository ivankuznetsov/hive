require "test_helper"
require "digest"
require "hive/modules/migration/report_migration"

class ModulesMigrationReportMigrationTest < Minitest::Test
  include HiveTestHelper

  FIXTURE_PATH = File.expand_path(
    "../../../fixtures/module_migration/report-v1.json",
    __dir__
  )

  def test_archives_exact_v1_and_replaces_it_with_evidence_required_v2_once
    with_legacy_report do |path, source|
      migration = Hive::Modules::Migration::ReportMigration.new(path: path)
      result = migration.ensure_current!

      assert_equal "migrated", result.status
      assert_equal Digest::SHA256.hexdigest(source), result.source_digest
      archive = File.join(File.dirname(path), result.archive_path)
      assert_equal source, File.binread(archive)
      assert File.exist?(
        File.join(File.dirname(path), "migrations", "report-v2.json")
      )

      repository =
        Hive::Modules::Migration::MigrationRepository.new(
          root: File.dirname(path)
        )
      report = repository.load_report
      assert_equal "evidence_required", report.status
      assert_includes(
        report.blockers,
        "legacy_v1_evidence_missing_candidate_and_protocol_bindings"
      )
      refute report.qualification.ready_for_operator?
      assert_equal 2, report.payload.fetch("schema_version")
      assert_equal "archived_evidence_required",
                   report.payload.dig("migration", "status")

      live = File.binread(path)
      repeated = migration.ensure_current!
      assert_equal "current", repeated.status
      assert_equal live, File.binread(path)
    end
  end

  def test_resume_after_archive_and_after_replacement_is_idempotent
    with_legacy_report do |path, _source|
      crashed = Hive::Modules::Migration::ReportMigration.new(
        path: path,
        after_archive: -> { raise "crash after archive" }
      )
      assert_raises(RuntimeError) { crashed.ensure_current! }
      assert_equal 1, JSON.parse(File.binread(path)).fetch("schema_version")

      resumed = Hive::Modules::Migration::ReportMigration.new(
        path: path
      ).ensure_current!
      assert_equal "migrated", resumed.status
      assert_equal 2, JSON.parse(File.binread(path)).fetch("schema_version")
    end

    with_legacy_report do |path, _source|
      crashed = Hive::Modules::Migration::ReportMigration.new(
        path: path,
        after_replace: -> { raise "crash after replacement" }
      )
      assert_raises(RuntimeError) { crashed.ensure_current! }
      assert_equal 2, JSON.parse(File.binread(path)).fetch("schema_version")
      refute File.exist?(
        File.join(File.dirname(path), "migrations", "report-v2.json")
      )

      resumed = Hive::Modules::Migration::ReportMigration.new(
        path: path
      ).ensure_current!
      assert_equal "current", resumed.status
      assert File.exist?(
        File.join(File.dirname(path), "migrations", "report-v2.json")
      )
    end
  end

  def test_migration_receipt_keeps_binding_the_initial_v2_replacement_after_report_rewrite
    with_legacy_report do |path, _source|
      migration = Hive::Modules::Migration::ReportMigration.new(path: path)
      migrated = migration.ensure_current!
      receipt_path = File.join(
        File.dirname(path), "migrations", "report-v2.json"
      )
      initial_receipt = File.binread(receipt_path)

      rewritten = Hive::Modules::Migration::Report.evidence_required(
        blockers: [ "installed:lane_evidence_missing" ],
        reviewer: "operator",
        reviewed_at: Time.utc(2026, 7, 30, 12),
        migration: migrated.report.payload.fetch("migration")
      )
      Hive::Modules::Migration::MigrationRepository.new(
        root: File.dirname(path)
      ).write_report(rewritten)

      repeated = migration.ensure_current!
      assert_equal "current", repeated.status
      assert_equal initial_receipt, File.binread(receipt_path)
      assert_equal rewritten.payload, repeated.report.payload
    end
  end

  def test_v1_null_configuration_digests_are_archived_as_unknown
    with_tmp_dir do |root|
      path = File.join(root, "report.json")
      payload = JSON.parse(File.binread(FIXTURE_PATH))
      payload.fetch("modules").each_value do |row|
        row["configuration_digest"] = nil
      end
      File.binwrite(
        path,
        Hive::Modules::Migration::Report.canonical(payload)
      )

      result = Hive::Modules::Migration::ReportMigration.new(
        path: path
      ).ensure_current!

      assert_equal "migrated", result.status
      assert_equal(
        {
          "architecture-patrol" => nil,
          "patrol" => nil
        },
        result.report.configuration_digests
      )
    end
  end

  def test_v1_error_envelope_is_archived_and_replaced_deterministically
    with_tmp_dir do |root|
      path = File.join(root, "report.json")
      source = Hive::Modules::Migration::Report.canonical(
        {
          "schema" => "hive-module-migration-report",
          "schema_version" => 1,
          "ok" => false,
          "error_kind" => "collection_failed",
          "exit_code" => 1,
          "message" => "legacy collector failed secret=redacted"
        }
      )
      File.binwrite(path, source)

      migration = Hive::Modules::Migration::ReportMigration.new(
        path: path
      )
      result = migration.ensure_current!

      assert_equal "migrated", result.status
      assert_equal "evidence_required", result.report.status
      assert_equal(
        [ "legacy_v1_error_report_archived" ],
        result.report.blockers
      )
      refute_includes File.binread(path), "legacy collector failed"
      archive = File.join(root, result.archive_path)
      assert_equal source, File.binread(archive)
      replacement = File.binread(path)

      assert_equal "current", migration.ensure_current!.status
      assert_equal replacement, File.binread(path)
    end
  end

  def test_missing_report_is_absent_and_native_v2_is_current
    with_tmp_dir do |root|
      path = File.join(root, "report.json")
      absent = Hive::Modules::Migration::ReportMigration.new(
        path: path
      ).ensure_current!
      assert_equal "absent", absent.status
      refute File.exist?(path)

      report = Hive::Modules::Migration::Report.evidence_required(
        blockers: [ "lane_evidence_missing" ],
        reviewer: "operator",
        reviewed_at: Time.utc(2026, 7, 30)
      )
      Hive::Modules::Migration::MigrationRepository.new(
        root: root
      ).write_report(report)
      current = Hive::Modules::Migration::ReportMigration.new(
        path: path
      ).ensure_current!
      assert_equal "current", current.status
      assert_nil current.report.payload.fetch("migration")
    end
  end

  def test_changed_archive_and_malformed_v1_fail_closed
    with_legacy_report do |path, _source|
      result = Hive::Modules::Migration::ReportMigration.new(
        path: path
      ).ensure_current!
      archive = File.join(File.dirname(path), result.archive_path)
      File.binwrite(archive, "{}")
      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::ReportMigration.new(
          path: path
        ).ensure_current!
      end
    end

    with_tmp_dir do |root|
      path = File.join(root, "report.json")
      File.binwrite(
        path,
        "{\"schema\":\"hive-module-migration-report\",\"schema_version\":1}"
      )
      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::ReportMigration.new(
          path: path
        ).ensure_current!
      end
    end
  end

  def test_corrupt_receipt_and_unsafe_missing_receipt_repair_fail_closed
    with_legacy_report do |path, _source|
      migration =
        Hive::Modules::Migration::ReportMigration.new(
          path: path
        )
      migration.ensure_current!
      receipt_path = File.join(
        File.dirname(path),
        "migrations",
        "report-v2.json"
      )
      File.binwrite(receipt_path, "{}")

      error = assert_raises(Hive::ConfigError) do
        migration.ensure_current!
      end
      assert_match(/receipt conflicts/, error.message)
    end

    with_legacy_report do |path, _source|
      migration =
        Hive::Modules::Migration::ReportMigration.new(
          path: path
        )
      migrated = migration.ensure_current!
      evolved = Hive::Modules::Migration::Report.evidence_required(
        blockers: [ "fresh_evidence_required" ],
        reviewer: "operator",
        reviewed_at: Time.utc(2026, 7, 30, 13),
        migration: migrated.migration
      )
      repository =
        Hive::Modules::Migration::MigrationRepository.new(
          root: File.dirname(path)
        )
      repository.write_report(evolved)
      receipt_path = File.join(
        File.dirname(path),
        "migrations",
        "report-v2.json"
      )
      File.unlink(receipt_path)
      evolved_bytes = File.binread(path)

      error = assert_raises(Hive::ConfigError) do
        migration.ensure_current!
      end
      assert_match(/missing after report evolution/, error.message)
      refute File.exist?(receipt_path)
      assert_equal evolved_bytes, File.binread(path)
    end
  end

  private

  def with_legacy_report
    with_tmp_dir do |root|
      path = File.join(root, "report.json")
      source = File.binread(FIXTURE_PATH)
      File.binwrite(path, source)
      yield path, source
    end
  end
end
