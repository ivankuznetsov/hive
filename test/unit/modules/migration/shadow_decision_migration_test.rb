require "test_helper"
require "digest"
require "json"
require "hive/modules/migration/shadow_comparator"
require "hive/modules/migration/shadow_decision_migration"

class ModulesMigrationShadowDecisionMigrationTest < Minitest::Test
  include HiveTestHelper

  START = Time.utc(2026, 7, 1)

  def test_one_off_migration_archives_v1_as_noncomparable_v2
    with_tmp_dir do |root|
      path = File.join(root, "patrol", "#{'a' * 64}.json")
      FileUtils.mkdir_p(File.dirname(path))
      v1 = v1_record
      bytes = Hive::WorkflowPackage::CanonicalJSON.generate(v1)
      File.write(path, bytes)

      result = Hive::Modules::Migration::ShadowDecisionMigration.migrate!(root: root)

      assert_equal 1, result.migrated
      assert_equal 0, result.already_current
      archive = File.join(root, "archive", "v1", "patrol", File.basename(path))
      assert_equal bytes, File.binread(archive)

      migrated = Hive::Modules::Migration::ShadowComparator.new(root: root).records.fetch(0)
      assert_equal 2, migrated.fetch("schema_version")
      refute migrated.fetch("comparable")
      assert_nil migrated.fetch("legacy_capture")
      assert_empty migrated.fetch("legacy_effects")
      assert_empty migrated.fetch("module_effects")
      assert_equal(
        {
          "source_digest" => Digest::SHA256.hexdigest(bytes),
          "source_schema_version" => 1,
          "status" => "archived_non_comparable"
        },
        migrated.fetch("migration")
      )

      repeated = Hive::Modules::Migration::ShadowDecisionMigration.migrate!(root: root)
      assert_equal 0, repeated.migrated
      assert_equal 1, repeated.already_current
    end
  end

  def test_runtime_reader_rejects_v1_without_migration
    with_tmp_dir do |root|
      path = File.join(root, "patrol", "#{'a' * 64}.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, Hive::WorkflowPackage::CanonicalJSON.generate(v1_record))

      error = assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::ShadowComparator.new(root: root).records
      end
      assert_equal "module shadow evidence is malformed", error.message
    end
  end

  def test_migration_fails_closed_on_archive_collision
    with_tmp_dir do |root|
      path = File.join(root, "patrol", "#{'a' * 64}.json")
      archive = File.join(root, "archive", "v1", "patrol", File.basename(path))
      FileUtils.mkdir_p(File.dirname(path))
      FileUtils.mkdir_p(File.dirname(archive))
      File.write(path, Hive::WorkflowPackage::CanonicalJSON.generate(v1_record))
      File.write(archive, "different")

      error = assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::ShadowDecisionMigration.migrate!(root: root)
      end
      assert_equal "module shadow v1 archive conflicts with existing bytes", error.message
    end
  end

  private

  def v1_record
    {
      "schema" => "hive-module-shadow-decision",
      "schema_version" => 1,
      "module" => "patrol",
      "decision_id" => "a" * 64,
      "trigger_digest" => "b" * 64,
      "occurred_at" => START.iso8601(6),
      "recorded_at" => (START + 1).iso8601(6),
      "evidence_source" => "legacy_mutator_capture",
      "configuration_digest" => "c" * 64,
      "comparable" => true,
      "legacy" => { "rationale" => "due" },
      "module_decision" => { "rationale" => "due" },
      "explained_differences" => [],
      "unexplained_differences" => [],
      "legacy_effects" => [ "legacy-effect" ],
      "module_effects" => [],
      "duplicate_effects" => []
    }
  end
end
