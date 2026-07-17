require "test_helper"
require "hive/scheduling_proof/snapshot_store"

class SchedulingProofSnapshotStoreTest < Minitest::Test
  include HiveTestHelper

  def test_atomically_replaces_owner_private_snapshot
    with_tmp_dir do |dir|
      path = File.join(dir, "scheduler.json")
      store = Hive::SchedulingProof::SnapshotStore.new(path: path)
      store.write(snapshot("first"))
      store.write(snapshot("second"))

      result = store.read
      assert_equal :ok, result.status
      assert_equal "second", result.snapshot.fetch("daemon_instance_id")
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_empty Dir.glob(File.join(dir, ".*.tmp.*"))
    end
  end

  def test_corrupt_and_newer_snapshots_fail_closed_without_rewrite
    with_tmp_dir do |dir|
      path = File.join(dir, "scheduler.json")
      File.write(path, "not-json")
      store = Hive::SchedulingProof::SnapshotStore.new(path: path)
      assert_equal :corrupt, store.read.status
      assert_raises(Hive::SchedulingProof::SnapshotStore::CorruptSnapshot) do
        store.write(snapshot("replacement"))
      end
      assert_equal "not-json", File.read(path)

      File.write(path, JSON.generate(snapshot("future").merge("schema_version" => 2)))
      assert_equal :newer_schema, store.read.status
      assert_raises(Hive::SchedulingProof::SnapshotStore::NewerSchema) do
        store.write(snapshot("replacement"))
      end
      assert_equal 2, JSON.parse(File.read(path)).fetch("schema_version")
    end
  end

  def test_missing_snapshot_is_an_ordinary_result
    with_tmp_dir do |dir|
      result = Hive::SchedulingProof::SnapshotStore.new(path: File.join(dir, "missing.json")).read
      assert_equal :missing, result.status
      assert_nil result.snapshot
    end
  end

  private

  def snapshot(instance)
    {
      "schema" => "hive-scheduler-snapshot", "schema_version" => 1,
      "daemon_instance_id" => instance, "daemon_state" => "running",
      "heartbeat_at" => "2026-07-17T12:00:00Z", "poll_interval_sec" => 30,
      "configuration_fingerprint" => "abc", "tick_health" => "ok",
      "unavailable_live_claims" => [], "tasks" => [],
      "fleet" => { "configured_slots" => 3, "owners" => [], "candidates" => [] }
    }
  end
end
