require "test_helper"
require "digest"
require "json"
require "json_schemer"
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

      result = migrate(root)

      assert_equal 1, result.migrated
      assert_equal 0, result.already_current
      archive = File.join(root, "archive", "v1", "patrol", File.basename(path))
      assert_equal bytes, File.binread(archive)

      migrated = Hive::Modules::Migration::ShadowComparator.new(root: root)
        .each_record.to_a.fetch(0)
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
      schema = JSONSchemer.schema(
        JSON.parse(
          File.read(
            File.join(
              Hive::Schemas.schema_dir,
              "hive-module-shadow-decision.v2.json"
            )
          )
        )
      )
      assert schema.valid?(migrated), schema.validate(migrated).to_a.inspect

      repeated = migrate(root)
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
        Hive::Modules::Migration::ShadowComparator.new(root: root)
          .each_record.to_a
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
        migrate(root)
      end
      assert_equal "module shadow v1 archive conflicts with existing bytes", error.message
    end
  end

  def test_migration_rejects_symlinked_archive_files_and_directories
    with_tmp_dir do |root|
      path = File.join(root, "patrol", "#{'a' * 64}.json")
      archive = File.join(root, "archive", "v1", "patrol", File.basename(path))
      outside = File.join(root, "outside")
      FileUtils.mkdir_p(File.dirname(path))
      FileUtils.mkdir_p(File.dirname(archive))
      bytes = Hive::WorkflowPackage::CanonicalJSON.generate(v1_record)
      File.write(path, bytes)
      File.write(outside, bytes)
      File.symlink(outside, archive)

      assert_raises(Hive::ConfigError) { migrate(root) }
      assert_equal bytes, File.binread(outside)
    end

    with_tmp_dir do |root|
      path = File.join(root, "patrol", "#{'a' * 64}.json")
      archive_parent = File.join(root, "archive", "v1")
      outside = File.join(root, "outside")
      FileUtils.mkdir_p(File.dirname(path))
      FileUtils.mkdir_p(File.dirname(archive_parent))
      FileUtils.mkdir_p(File.join(outside, "patrol"))
      File.write(path, Hive::WorkflowPackage::CanonicalJSON.generate(v1_record))
      File.symlink(outside, archive_parent)

      assert_raises(Hive::ConfigError) { migrate(root) }
      assert_empty Dir.children(File.join(outside, "patrol"))
    end
  end

  def test_mixed_partial_conversion_resumes_and_stamps_only_after_zero_v1
    with_tmp_dir do |root|
      current = Hive::Modules::Migration::ShadowComparator.new(root: root)
      trigger = { "id" => "current" }
      capture = Hive::Modules::Migration::PatrolCapture.build(
        module_name: "architecture-patrol",
        project: {
          "project_id" => "project-1",
          "name" => "demo",
          "repository" => "owner/demo"
        },
        trigger: trigger,
        reservation: { "kind" => "architecture", "id" => "job-1" },
        owner: "legacy",
        owner_epoch: 1,
        selection_input: {
          "kind" => "candidate",
          "job_id" => "job-1",
          "phase" => "discovery"
        },
        selection:
          Hive::Modules::Migration::PatrolDecisionProjection.build(
            module_name: "architecture-patrol",
            rationale: "due",
            job_id: "job-1",
            phase: "discovery"
          ),
        outcome_class: "complete",
        outcome: { "rationale" => "complete" },
        occurred_at: START,
        recorded_at: START
      )
      current.record!(
        module_name: "architecture-patrol",
        trigger: trigger,
        legacy_capture: capture,
        module_projection: capture.selection,
        configuration_digest: "d" * 64,
        occurred_at: START
      )
      v1_path = File.join(root, "patrol", "#{'a' * 64}.json")
      FileUtils.mkdir_p(File.dirname(v1_path))
      File.write(
        v1_path,
        Hive::WorkflowPackage::CanonicalJSON.generate(v1_record)
      )

      result = migrate(root)

      assert_equal 1, result.migrated
      assert_equal 1, result.already_current
      assert_equal [ 2, 2 ],
                   Hive::Modules::Migration::ShadowComparator.new(root: root)
                     .each_record.map { |record| record.fetch("schema_version") }
      assert File.file?(
        File.join(root, "migrations", "shadow-decision-v2.json")
      )
    end
  end

  def test_migration_requires_quiescence_and_completed_stamp_rejects_late_v1
    with_tmp_dir do |root|
      error = assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::ShadowDecisionMigration.migrate!(
          root: root,
          quiescence_probe: -> { :live }
        )
      end
      assert_equal(
        "module shadow v1 evidence migration requires quiescence",
        error.message
      )

      path = File.join(root, "patrol", "#{'a' * 64}.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, Hive::WorkflowPackage::CanonicalJSON.generate(v1_record))
      migrate(root)
      late = File.join(root, "patrol", "#{'e' * 64}.json")
      File.write(late, Hive::WorkflowPackage::CanonicalJSON.generate(
        v1_record.merge("decision_id" => "e" * 64)
      ))

      assert_raises(Hive::ConfigError) { migrate(root) }
    end
  end

  def test_migration_wraps_missing_stamp_malformed_json_and_invalid_v1
    with_tmp_dir do |root|
      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::ShadowDecisionMigration.ensure_complete!(
          root: root
        )
      end
    end

    with_tmp_dir do |root|
      stamp = File.join(root, "migrations", "shadow-decision-v2.json")
      FileUtils.mkdir_p(File.dirname(stamp))
      File.write(stamp, "{bad")
      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::ShadowDecisionMigration.ensure_complete!(
          root: root
        )
      end
    end

    with_tmp_dir do |root|
      path = File.join(root, "patrol", "#{'a' * 64}.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{bad")
      assert_raises(Hive::ConfigError) { migrate(root) }
    end

    with_tmp_dir do |root|
      path = File.join(root, "patrol", "#{'a' * 64}.json")
      FileUtils.mkdir_p(File.dirname(path))
      malformed = v1_record.merge("occurred_at" => "not-a-time")
      File.write(
        path,
        Hive::WorkflowPackage::CanonicalJSON.generate(malformed)
      )
      assert_raises(Hive::ConfigError) { migrate(root) }
    end
  end

  def test_migration_rejects_noncanonical_v2_and_reuses_exact_archive
    with_tmp_dir do |root|
      comparator = Hive::Modules::Migration::ShadowComparator.new(root: root)
      trigger = { "id" => "current" }
      capture = Hive::Modules::Migration::PatrolCapture.build(
        module_name: "patrol",
        project: {
          "project_id" => "project-1",
          "name" => "demo",
          "repository" => "owner/demo"
        },
        trigger: trigger,
        reservation: { "kind" => "ordinary", "id" => "reservation-1" },
        owner: "legacy",
        owner_epoch: 1,
        selection_input: {
          "kind" => "operation",
          "operation" => "shadow-migration"
        },
        selection:
          Hive::Modules::Migration::PatrolDecisionProjection.build(
            module_name: "patrol",
            rationale: "due"
          ),
        outcome_class: "complete",
        outcome: {},
        occurred_at: START,
        recorded_at: START
      )
      record = comparator.record!(
        module_name: "patrol",
        trigger: trigger,
        legacy_capture: capture,
        module_projection: capture.selection,
        configuration_digest: "c" * 64,
        occurred_at: START
      )
      path = File.join(
        root, "patrol", "#{record.fetch('decision_id')}.json"
      )
      File.write(path, JSON.pretty_generate(record))
      assert_raises(Hive::ConfigError) { migrate(root) }
    end

    with_tmp_dir do |root|
      path = File.join(root, "patrol", "#{'a' * 64}.json")
      archive = File.join(
        root, "archive", "v1", "patrol", File.basename(path)
      )
      FileUtils.mkdir_p(File.dirname(path))
      FileUtils.mkdir_p(File.dirname(archive))
      bytes = Hive::WorkflowPackage::CanonicalJSON.generate(v1_record)
      File.write(path, bytes)
      File.write(archive, bytes)

      assert_equal 1, migrate(root).migrated
      assert_equal bytes, File.binread(archive)
    end
  end

  def test_checkpoint_inventory_and_shape_corruption_fail_closed
    with_tmp_dir do |root|
      migrator = Hive::Modules::Migration::ShadowDecisionMigration.new(
        root: root,
        quiescence_probe: -> { :quiescent }
      )
      path = File.join(root, "patrol", "#{'a' * 64}.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{bad")
      assert_raises(Hive::ConfigError) do
        migrator.send(:validate_zero_v1!)
      end
    end

    with_tmp_dir do |root|
      migrator = Hive::Modules::Migration::ShadowDecisionMigration.new(
        root: root,
        quiescence_probe: -> { :quiescent }
      )
      path = File.join(root, "patrol", "#{'a' * 64}.json")
      checkpoint_path = migrator.send(:checkpoint_path)
      FileUtils.mkdir_p(File.dirname(checkpoint_path))
      relative = path.delete_prefix("#{root}/")
      checkpoint = {
        "schema" =>
          "hive-module-shadow-decision-migration-checkpoint",
        "schema_version" => 1,
        "status" => "in_progress",
        "files" => {
          relative => {
            "source_digest" => "0" * 64,
            "status" => "pending"
          }
        }
      }
      File.write(
        checkpoint_path,
        Hive::WorkflowPackage::CanonicalJSON.generate(checkpoint)
      )
      assert_raises(Hive::ConfigError) do
        migrator.send(:checkpoint!, path, "changed", "pending")
      end

      File.write(
        checkpoint_path,
        Hive::WorkflowPackage::CanonicalJSON.generate(
          checkpoint.merge("status" => "unknown")
        )
      )
      assert_raises(Hive::ConfigError) do
        migrator.send(:read_checkpoint)
      end
      File.write(checkpoint_path, "{bad")
      assert_raises(Hive::ConfigError) do
        migrator.send(:read_checkpoint)
      end
    end
  end

  def test_bounded_migration_reader_detects_links_and_growth_races
    with_tmp_dir do |root|
      migrator = Hive::Modules::Migration::ShadowDecisionMigration.new(
        root: root,
        quiescence_probe: -> { :quiescent }
      )
      target = File.join(root, "target")
      link = File.join(root, "link")
      File.write(target, "{}")
      File.symlink(target, link)
      assert_raises(Hive::ConfigError) do
        migrator.send(:bounded_read, link)
      end

      path = File.join(root, "record")
      File.write(path, "{}")
      oversized = "x" * (
        Hive::Modules::Migration::ShadowComparator::MAX_RECORD_BYTES + 1
      )
      proxy = Object.new
      proxy.define_singleton_method(:stat) { File.lstat(path) }
      proxy.define_singleton_method(:read) { |_limit| oversized }
      original = File.method(:open)
      replacement = lambda do |candidate, *args, **kwargs, &block|
        unless candidate == path
          next original.call(
            candidate, *args, **kwargs, &block
          )
        end

        block.call(proxy)
      end
      with_replaced_singleton_method(
        File, :open, replacement
      ) do
        assert_raises(Hive::ConfigError) do
          migrator.send(:bounded_read, path)
        end
      end
    end
  end

  def test_migration_inventory_rejects_combined_excess_before_body_reads
    with_tmp_dir do |root|
      %w[patrol architecture-patrol].each_with_index do |module_name, index|
        directory = File.join(root, module_name)
        FileUtils.mkdir_p(directory)
        File.write(
          File.join(directory, "#{index.to_s(16).rjust(64, '0')}.json"),
          "unread"
        )
      end
      migrator = Hive::Modules::Migration::ShadowDecisionMigration.new(
        root: root,
        quiescence_probe: -> { :quiescent }
      )

      with_constant(
        Hive::Modules::Migration::ShadowComparator,
        :MAX_RECORDS,
        1
      ) do
        assert_raises(Hive::ConfigError) do
          migrator.send(:evidence_paths).to_a
        end
      end
    end
  end

  private

  def with_constant(owner, name, replacement)
    original = owner.const_get(name, false)
    owner.send(:remove_const, name)
    owner.const_set(name, replacement)
    yield
  ensure
    owner.send(:remove_const, name) if owner.const_defined?(name, false)
    owner.const_set(name, original)
  end

  def migrate(root)
    Hive::Modules::Migration::ShadowDecisionMigration.migrate!(
      root: root,
      quiescence_probe: -> { :quiescent }
    )
  end

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
