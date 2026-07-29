require "test_helper"
require "digest"
require "json"
require "hive/modules/migration/occurrence_recovery_index"
require "hive/modules/migration/occurrence_record_validator"
require "hive/workflow_package/canonical_json"

class ModulesMigrationOccurrenceRecoveryIndexTest < Minitest::Test
  include HiveTestHelper

  def test_write_publishes_one_sorted_bounded_canonical_projection
    with_index do |index, root|
      ids = [ occurrence_id("second"), occurrence_id("first") ]

      written = index.write(generation: 7, occurrence_ids: ids)

      assert_equal ids.sort, written.fetch("occurrence_ids")
      assert_equal written, index.snapshot
      path = File.join(root, "recovery-index.json")
      assert_equal(
        Hive::WorkflowPackage::CanonicalJSON.generate(written),
        File.binread(path)
      )
      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  def test_invalid_or_noncanonical_projection_is_repairable
    with_index do |index, root|
      path = File.join(root, "recovery-index.json")
      File.write(path, "{bad")
      assert_nil index.snapshot

      wrong_module = {
        "schema" =>
          Hive::Modules::Migration::OccurrenceRecoveryIndex::SCHEMA,
        "schema_version" => 1,
        "module" => "architecture-patrol",
        "generation" => 0,
        "occurrence_ids" => []
      }
      File.write(
        path,
        Hive::WorkflowPackage::CanonicalJSON.generate(wrong_module)
      )
      assert_nil index.snapshot

      File.write(path, JSON.pretty_generate(wrong_module.merge(
        "module" => "patrol"
      )))
      assert_nil index.snapshot
    end
  end

  def test_write_rejects_overflow_duplicates_and_invalid_generation
    with_index do |index, _root|
      overflow =
        (
          Hive::Modules::Migration::OccurrenceRecoveryIndex::MAX_OCCURRENCES +
          1
        ).times.map { |index_value| occurrence_id(index_value.to_s) }
      assert_raises(Hive::ConfigError) do
        index.write(generation: 0, occurrence_ids: overflow)
      end
      id = occurrence_id("duplicate")
      assert_raises(Hive::ConfigError) do
        index.write(generation: 0, occurrence_ids: [ id, id ])
      end
      assert_raises(Hive::ConfigError) do
        index.write(generation: -1, occurrence_ids: [])
      end
    end
  end

  def test_index_symlink_cannot_redirect_read_or_write
    with_index do |index, root|
      index.write(generation: 0, occurrence_ids: [])
      path = File.join(root, "recovery-index.json")
      outside = File.join(File.dirname(root), "outside-index.json")
      File.write(outside, "external")
      FileUtils.rm_f(path)
      File.symlink(outside, path)
      before = File.binread(outside)

      assert_raises(Hive::ConfigError) { index.snapshot }
      assert_raises(Hive::ConfigError) do
        index.write(generation: 1, occurrence_ids: [])
      end
      assert_equal before, File.binread(outside)
    end
  end

  private

  def with_index
    with_tmp_dir do |root|
      validator =
        Hive::Modules::Migration::OccurrenceRecordValidator.new(
          module_name: "patrol"
        )
      index =
        Hive::Modules::Migration::OccurrenceRecoveryIndex.new(
          root: root,
          module_name: "patrol",
          validator: validator
        )
      yield index, root
    end
  end

  def occurrence_id(value)
    "occ-#{Digest::SHA256.hexdigest(value)}"
  end
end
