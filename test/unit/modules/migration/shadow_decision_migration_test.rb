require "test_helper"
require "digest"
require "json"
require "json_schemer"
require "open3"
require "rbconfig"
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

  def test_completed_migration_accepts_later_native_v2_evidence
    with_tmp_dir do |root|
      path = File.join(root, "patrol", "#{"a" * 64}.json")
      write_v1(path)
      migrate(root)
      checkpoint = File.binread(checkpoint_path(root))

      comparator =
        Hive::Modules::Migration::ShadowComparator.new(root: root)
      record_native_v2(
        root,
        module_name: "architecture-patrol",
        trigger_id: "post-migration",
        now: START + 60
      )

      repeated = migrate(root)

      assert_equal 0, repeated.migrated
      assert_equal 1, repeated.already_current
      assert_equal checkpoint, File.binread(checkpoint_path(root))
      assert_equal(
        [ 2, 2 ],
        comparator.each_record.map { |record| record.fetch("schema_version") }
      )
    end
  end

  def test_fresh_process_resumes_after_live_v2_replacement
    with_tmp_dir do |root|
      relative = File.join("patrol", "#{"a" * 64}.json")
      path = File.join(root, relative)
      FileUtils.mkdir_p(File.dirname(path))
      source = Hive::WorkflowPackage::CanonicalJSON.generate(v1_record)
      File.binwrite(path, source)

      child = fork do
        original = Hive::ManagedDirectory.instance_method(:atomic_write)
        Hive::ManagedDirectory.define_method(:atomic_write) do |candidate, *args,
                                                                  **options|
          result = original.bind_call(self, candidate, *args, **options)
          Process.kill("KILL", Process.pid) if candidate == relative
          result
        end
        migrate(root)
      end
      _pid, status = Process.wait2(child)

      assert_predicate status, :signaled?
      assert_equal Signal.list.fetch("KILL"), status.termsig
      checkpoint = read_json(checkpoint_path(root))
      assert_equal "pending",
                   checkpoint.dig("files", relative, "status")
      archive = File.join(root, "archive", "v1", relative)
      assert_equal source, File.binread(archive)
      assert_equal 2, read_json(path).fetch("schema_version")

      stdout, stderr, restarted = Open3.capture3(
        RbConfig.ruby,
        "-I#{File.expand_path("../../../lib", __dir__)}",
        "-e",
        <<~'RUBY',
          require "json"
          require "hive/modules/migration/shadow_decision_migration"
          result =
            Hive::Modules::Migration::ShadowDecisionMigration.migrate!(
              root: ARGV.fetch(0),
              quiescence_probe: -> { :quiescent }
            )
          STDOUT.write(
            JSON.generate(
              "migrated" => result.migrated,
              "already_current" => result.already_current
            )
          )
        RUBY
        root
      )

      assert restarted.success?, stderr
      assert_equal(
        { "migrated" => 1, "already_current" => 0 },
        JSON.parse(stdout)
      )
      assert_equal "migrated",
                   read_json(checkpoint_path(root))
                     .dig("files", relative, "status")
      assert_equal(
        1,
        Hive::Modules::Migration::ShadowDecisionMigration.ensure_complete!(
          root: root
        ).already_current
      )
    end
  end

  def test_legacy_checkpoint_recovers_matching_replacement_states
    %w[pending current].each do |status|
      with_tmp_dir do |root|
        relative = File.join("patrol", "#{"a" * 64}.json")
        path = File.join(root, relative)
        source = write_v1(path)
        migrate(root)
        File.unlink(
          File.join(root, "migrations", "shadow-decision-v2.json")
        )
        live = File.binread(path)
        legacy = {
          "schema" =>
            "hive-module-shadow-decision-migration-checkpoint",
          "schema_version" => 1,
          "status" => "in_progress",
          "files" => {
            relative => {
              "source_digest" => Digest::SHA256.hexdigest(
                status == "pending" ? source : live
              ),
              "status" => status
            }
          }
        }
        File.binwrite(
          checkpoint_path(root),
          Hive::WorkflowPackage::CanonicalJSON.generate(legacy)
        )

        result = migrate(root)

        assert_equal 1, result.migrated, status
        checkpoint = read_json(checkpoint_path(root))
        assert_equal 2, checkpoint.fetch("schema_version"), status
        assert_equal "complete", checkpoint.fetch("status"), status
        assert_equal "migrated",
                     checkpoint.dig("files", relative, "status"),
                     status
      end
    end
  end

  def test_pending_replacement_corruption_matrix_fails_without_stamp
    corruptions = {
      "missing archive" => lambda do |root, relative, _checkpoint|
        File.unlink(File.join(root, "archive", "v1", relative))
      end,
      "changed archive" => lambda do |root, relative, _checkpoint|
        File.binwrite(
          File.join(root, "archive", "v1", relative),
          "changed"
        )
      end,
      "wrong live source binding" => lambda do |root, relative, _checkpoint|
        path = File.join(root, relative)
        record = read_json(path)
        record.fetch("migration")["source_digest"] = "f" * 64
        File.binwrite(
          path,
          Hive::WorkflowPackage::CanonicalJSON.generate(record)
        )
      end,
      "wrong checkpoint destination digest" =>
        lambda do |root, relative, checkpoint|
          checkpoint.dig("files", relative)["v2_digest"] = "f" * 64
          File.binwrite(
            checkpoint_path(root),
            Hive::WorkflowPackage::CanonicalJSON.generate(checkpoint)
          )
        end,
      "wrong checkpoint archive binding" =>
        lambda do |root, relative, checkpoint|
          checkpoint.dig("files", relative)["archive_digest"] = "f" * 64
          write_json(checkpoint_path(root), checkpoint)
        end
    }
    corruptions.each do |label, corrupt|
      with_tmp_dir do |root|
        relative = File.join("patrol", "#{"a" * 64}.json")
        write_v1(File.join(root, relative))
        migrate(root)
        File.unlink(
          File.join(root, "migrations", "shadow-decision-v2.json")
        )
        checkpoint = read_json(checkpoint_path(root))
        checkpoint["status"] = "in_progress"
        checkpoint.dig("files", relative)["status"] = "pending"
        File.binwrite(
          checkpoint_path(root),
          Hive::WorkflowPackage::CanonicalJSON.generate(checkpoint)
        )
        corrupt.call(root, relative, checkpoint)

        assert_raises(Hive::ConfigError) { migrate(root) }
        refute File.exist?(
          File.join(root, "migrations", "shadow-decision-v2.json")
        ), label
      end
    end
  end

  def test_migrate_repairs_stamp_before_checkpoint_completion
    with_tmp_dir do |root|
      path = File.join(root, "patrol", "#{"a" * 64}.json")
      write_v1(path)
      migrate(root)
      checkpoint = read_json(checkpoint_path(root))
      checkpoint["status"] = "in_progress"
      File.binwrite(
        checkpoint_path(root),
        Hive::WorkflowPackage::CanonicalJSON.generate(checkpoint)
      )

      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::ShadowDecisionMigration.ensure_complete!(
          root: root
        )
      end
      assert_equal 1, migrate(root).already_current
      assert_equal "complete",
                   read_json(checkpoint_path(root)).fetch("status")
    end
  end

  def test_restart_rejects_checkpoint_state_contradictions
    with_tmp_dir do |root|
      relative, path = migrated_v1_fixture(root)
      File.unlink(stamp_path(root))
      checkpoint = read_json(checkpoint_path(root))
      checkpoint["status"] = "in_progress"
      checkpoint.dig("files", relative)["status"] = "pending"
      changed = v1_record.merge("configuration_digest" => "f" * 64)
      write_json(path, changed)
      write_json(checkpoint_path(root), checkpoint)

      assert_raises(Hive::ConfigError) { migrate(root) }
    end

    with_tmp_dir do |root|
      migrated_v1_fixture(root)
      File.unlink(stamp_path(root))

      assert_raises(Hive::ConfigError) { migrate(root) }
    end

    with_tmp_dir do |root|
      migrated_v1_fixture(root)
      File.unlink(stamp_path(root))
      File.unlink(checkpoint_path(root))

      assert_raises(Hive::ConfigError) { migrate(root) }
    end

    with_tmp_dir do |root|
      relative, = migrated_v1_fixture(root)
      File.unlink(stamp_path(root))
      checkpoint = read_json(checkpoint_path(root))
      checkpoint["status"] = "in_progress"
      checkpoint.dig("files", relative)["status"] = "unknown"
      write_json(checkpoint_path(root), checkpoint)

      assert_raises(Hive::ConfigError) { migrate(root) }
    end

    with_tmp_dir do |root|
      record = record_native_v2(
        root, module_name: "patrol", trigger_id: "current-mismatch"
      )
      migrate(root)
      File.unlink(stamp_path(root))
      relative = File.join(
        "patrol", "#{record.fetch('decision_id')}.json"
      )
      checkpoint = read_json(checkpoint_path(root))
      checkpoint["status"] = "in_progress"
      checkpoint.dig("files", relative)["v2_digest"] = "f" * 64
      write_json(checkpoint_path(root), checkpoint)

      assert_raises(Hive::ConfigError) { migrate(root) }
    end
  end

  def test_completion_and_legacy_bindings_fail_closed_on_corruption
    with_tmp_dir do |root|
      migrated_v1_fixture(root)
      stamp = read_json(stamp_path(root))
      stamp["migrated"] += 1
      write_json(stamp_path(root), stamp)

      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::ShadowDecisionMigration.ensure_complete!(
          root: root
        )
      end
    end

    with_tmp_dir do |root|
      _relative, path = migrated_v1_fixture(root)
      File.binwrite(path, "{bad")

      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::ShadowDecisionMigration.ensure_complete!(
          root: root
        )
      end
    end

    with_tmp_dir do |root|
      relative, = migrated_v1_fixture(root)
      checkpoint = read_json(checkpoint_path(root))
      checkpoint["status"] = "in_progress"
      checkpoint.dig("files", relative)["status"] = "pending"
      write_json(checkpoint_path(root), checkpoint)

      assert_raises(Hive::ConfigError) do
        Hive::Modules::Migration::ShadowDecisionMigration.ensure_complete!(
          root: root
        )
      end
    end

    with_tmp_dir do |root|
      relative, = migrated_v1_fixture(root)
      File.unlink(stamp_path(root))
      checkpoint = read_json(checkpoint_path(root))
      checkpoint["schema_version"] = 1
      checkpoint["status"] = "in_progress"
      checkpoint["files"] = {
        relative => {
          "source_digest" => "f" * 64,
          "status" => "migrated"
        }
      }
      write_json(checkpoint_path(root), checkpoint)

      assert_raises(Hive::ConfigError) { migrate(root) }
    end

    with_tmp_dir do |root|
      relative, path = migrated_v1_fixture(root)
      File.unlink(stamp_path(root))
      checkpoint = read_json(checkpoint_path(root))
      source_digest =
        checkpoint.dig("files", relative, "source_digest")
      checkpoint["schema_version"] = 1
      checkpoint["status"] = "in_progress"
      checkpoint["files"] = {
        relative => {
          "source_digest" => source_digest,
          "status" => "migrated"
        }
      }
      live = read_json(path)
      live["recorded_at"] = (START + 300).iso8601(6)
      write_json(path, live)
      write_json(checkpoint_path(root), checkpoint)

      assert_raises(Hive::ConfigError) { migrate(root) }
    end

    with_tmp_dir do |root|
      path = File.join(root, "patrol", "#{"a" * 64}.json")
      write_json(path, v1_record.merge("schema_version" => 3))

      assert_raises(Hive::ConfigError) { migrate(root) }
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
      record_native_v2(
        root,
        module_name: "architecture-patrol",
        trigger_id: "current"
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

      File.unlink(stamp_path(root))
      checkpoint = read_json(checkpoint_path(root))
      checkpoint["schema_version"] = 1
      checkpoint["status"] = "in_progress"
      checkpoint["files"] = checkpoint.fetch("files").to_h do |relative, entry|
        digest = entry.fetch(
          entry.fetch("status") == "current" ?
            "v2_digest" : "source_digest"
        )
        [
          relative,
          {
            "source_digest" => digest,
            "status" => entry.fetch("status")
          }
        ]
      end
      write_json(checkpoint_path(root), checkpoint)

      resumed = migrate(root)
      assert_equal 1, resumed.migrated
      assert_equal 1, resumed.already_current
      assert_equal 2, migrate(root).already_current
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
      record = record_native_v2(
        root,
        module_name: "patrol",
        trigger_id: "current"
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
      path = File.join(root, "patrol", "#{'a' * 64}.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{bad")
      assert_raises(Hive::ConfigError) { migrate(root) }
    end

    with_tmp_dir do |root|
      path = File.join(root, "patrol", "#{'a' * 64}.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(
        path,
        Hive::WorkflowPackage::CanonicalJSON.generate(v1_record)
      )
      checkpoint = checkpoint_path(root)
      FileUtils.mkdir_p(File.dirname(checkpoint))
      relative = path.delete_prefix("#{root}/")
      payload = {
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
        checkpoint,
        Hive::WorkflowPackage::CanonicalJSON.generate(payload)
      )
      assert_raises(Hive::ConfigError) { migrate(root) }

      File.write(
        checkpoint,
        Hive::WorkflowPackage::CanonicalJSON.generate(
          payload.merge("status" => "unknown")
        )
      )
      assert_raises(Hive::ConfigError) { migrate(root) }
      File.write(checkpoint, "{bad")
      assert_raises(Hive::ConfigError) { migrate(root) }
    end
  end

  def test_bounded_migration_reader_rejects_links_and_oversized_records
    with_tmp_dir do |root|
      target = File.join(root, "target")
      link = File.join(root, "patrol", "#{"a" * 64}.json")
      FileUtils.mkdir_p(File.dirname(link))
      File.binwrite(
        target,
        Hive::WorkflowPackage::CanonicalJSON.generate(v1_record)
      )
      File.symlink(target, link)
      assert_raises(Hive::ConfigError) { migrate(root) }
    end

    with_tmp_dir do |root|
      path = File.join(root, "patrol", "#{"a" * 64}.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(
        path,
        "x" * (
          Hive::Modules::Migration::ShadowComparator::MAX_RECORD_BYTES + 1
        )
      )
      assert_raises(Hive::ConfigError) { migrate(root) }
    end

    with_tmp_dir do |root|
      path = File.join(root, "patrol", "#{"a" * 64}.json")
      write_v1(path)
      with_constant(
        Hive::Modules::Migration::ShadowDecisionMigration,
        :MAX_CHECKPOINT_BYTES,
        64
      ) do
        assert_raises(Hive::ConfigError) { migrate(root) }
      end
    end
  end

  def test_migration_rejects_checkpoint_inventory_addition
    with_tmp_dir do |root|
      first = File.join(root, "patrol", "#{"a" * 64}.json")
      FileUtils.mkdir_p(File.dirname(first))
      File.binwrite(
        first,
        Hive::WorkflowPackage::CanonicalJSON.generate(v1_record)
      )
      child = fork do
        original = Hive::ManagedDirectory.instance_method(:atomic_write)
        Hive::ManagedDirectory.define_method(:atomic_write) do |candidate,
                                                                  *args,
                                                                  **options|
          result = original.bind_call(self, candidate, *args, **options)
          if candidate.end_with?("shadow-decision-v2-checkpoint.json")
            Process.kill("KILL", Process.pid)
          end
          result
        end
        migrate(root)
      end
      Process.wait(child)
      second = File.join(root, "patrol", "#{"e" * 64}.json")
      File.binwrite(
        second,
        Hive::WorkflowPackage::CanonicalJSON.generate(
          v1_record.merge("decision_id" => "e" * 64)
        )
      )

      assert_raises(Hive::ConfigError) { migrate(root) }
      refute File.exist?(
        File.join(root, "migrations", "shadow-decision-v2.json")
      )
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

      with_constant(
        Hive::Modules::Migration::ShadowComparator,
        :MAX_RECORDS,
        1
      ) do
        assert_raises(Hive::ConfigError) { migrate(root) }
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

  def checkpoint_path(root)
    File.join(
      root, "migrations", "shadow-decision-v2-checkpoint.json"
    )
  end

  def stamp_path(root)
    File.join(root, "migrations", "shadow-decision-v2.json")
  end

  def read_json(path)
    JSON.parse(File.binread(path))
  end

  def write_json(path, value)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(
      path,
      Hive::WorkflowPackage::CanonicalJSON.generate(value)
    )
  end

  def write_v1(path)
    FileUtils.mkdir_p(File.dirname(path))
    bytes = Hive::WorkflowPackage::CanonicalJSON.generate(v1_record)
    File.binwrite(path, bytes)
    bytes
  end

  def migrated_v1_fixture(root)
    relative = File.join("patrol", "#{"a" * 64}.json")
    path = File.join(root, relative)
    write_v1(path)
    migrate(root)
    [ relative, path ]
  end

  def record_native_v2(root, module_name:, trigger_id:, now: START)
    trigger = { "id" => trigger_id }
    architecture = module_name == "architecture-patrol"
    job_id = "job-#{trigger_id}"
    selection_input = if architecture
      {
        "kind" => "candidate",
        "job_id" => job_id,
        "phase" => "discovery"
      }
    else
      {
        "kind" => "operation",
        "operation" => "shadow-migration"
      }
    end
    selection =
      Hive::Modules::Migration::PatrolDecisionProjection.build(
        module_name: module_name,
        rationale: "due",
        job_id: architecture ? job_id : nil,
        phase: architecture ? "discovery" : nil
      )
    capture = Hive::Modules::Migration::PatrolCapture.build(
      module_name: module_name,
      project: {
        "project_id" => "project-1",
        "name" => "demo",
        "repository" => "owner/demo"
      },
      trigger: trigger,
      reservation: architecture ?
        {
          "kind" => "architecture",
          "id" => job_id,
          "job_id" => job_id,
          "window_started_at" => now.utc.iso8601(6),
          "attempt_generation" => 1
        } :
        { "kind" => "ordinary", "id" => "reservation-#{trigger_id}" },
      owner: "legacy",
      owner_epoch: 1,
      selection_input: selection_input,
      selection: selection,
      outcome_class: "complete",
      outcome: { "rationale" => "complete" },
      occurred_at: now,
      recorded_at: now
    )
    Hive::Modules::Migration::ShadowComparator.new(root: root).record!(
      module_name: module_name,
      trigger: trigger,
      legacy_capture: capture,
      module_projection: capture.selection,
      configuration_digest: "d" * 64,
      occurred_at: now
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
