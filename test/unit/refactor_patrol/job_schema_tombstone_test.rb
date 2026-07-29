require "test_helper"
require "hive/refactor_patrol/job_schema_tombstone"
require "hive/refactor_patrol/job_store"

class RefactorPatrolJobSchemaTombstoneTest < Minitest::Test
  include HiveTestHelper

  def test_native_tombstone_is_canonical_and_complete_without_a_snapshot
    with_tmp_dir do |root|
      tombstone = tombstone(root)
      payload = tombstone.write(
        origin: "native",
        status: "complete",
        transaction_id: "native-#{"a" * 32}"
      )

      assert_equal payload, tombstone.read
      assert tombstone.assert_complete!(payload, snapshot_id: nil)
      assert_equal(
        Hive::WorkflowPackage::CanonicalJSON.generate(payload),
        File.binread(File.join(root, "jobs"))
      )
    end
  end

  def test_migrated_tombstone_progresses_from_sealed_to_complete
    with_tmp_dir do |root|
      tombstone = tombstone(root)
      transaction_id = "migration-#{"b" * 32}"
      archive_name = ".job-schema-v3-source-#{"b" * 32}"
      sealed = tombstone.write(
        origin: "migrated",
        status: "sealed",
        transaction_id: transaction_id,
        archive_name: archive_name
      )
      assert_equal "sealed", sealed.fetch("status")

      snapshot_id = "snapshot-#{"c" * 64}"
      complete = tombstone.write(
        origin: "migrated",
        status: "complete",
        transaction_id: transaction_id,
        archive_name: archive_name,
        snapshot_id: snapshot_id
      )

      assert_equal complete, tombstone.read
      assert tombstone.assert_complete!(
        complete, snapshot_id: snapshot_id
      )
    end
  end

  def test_rejects_noncanonical_mismatched_and_linked_tombstones
    with_tmp_dir do |root|
      tombstone = tombstone(root)
      payload = tombstone.build(
        origin: "migrated",
        status: "complete",
        transaction_id: "migration-#{"d" * 32}",
        archive_name: ".job-schema-v3-source-#{"d" * 32}",
        snapshot_id: "snapshot-#{"e" * 64}"
      )
      File.binwrite(
        File.join(root, "jobs"), JSON.pretty_generate(payload)
      )
      assert_raises(Hive::RefactorPatrol::JobStore::CorruptRecord) do
        tombstone.read
      end

      tombstone.write(
        origin: "migrated",
        status: "complete",
        transaction_id: "migration-#{"d" * 32}",
        archive_name: ".job-schema-v3-source-#{"d" * 32}",
        snapshot_id: "snapshot-#{"e" * 64}"
      )
      assert_raises(Hive::RefactorPatrol::JobStore::InconsistentRecord) do
        tombstone.assert_complete!(
          tombstone.read, snapshot_id: "snapshot-#{"f" * 64}"
        )
      end

      File.rename(
        File.join(root, "jobs"), File.join(root, "real-jobs")
      )
      File.symlink("real-jobs", File.join(root, "jobs"))
      assert_raises(Hive::ConfigError) { tombstone.read }
    end
  end

  private

  def tombstone(root)
    directory = Hive::ManagedDirectory.new(
      root: root, label: "test JobStore legacy namespace"
    )
    directory.prepare!
    Hive::RefactorPatrol::JobSchemaTombstone.new(
      directory: directory,
      project_id: "project-demo",
      target_version: 3,
      corrupt_record: Hive::RefactorPatrol::JobStore::CorruptRecord,
      inconsistent_record:
        Hive::RefactorPatrol::JobStore::InconsistentRecord
    )
  end
end
