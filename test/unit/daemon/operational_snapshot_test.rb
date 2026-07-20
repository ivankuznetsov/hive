require "test_helper"
require "json"
require "fileutils"
require "hive/daemon/operational_snapshot"

class HiveDaemonOperationalSnapshotTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 7, 20, 10, 0, 0)
  IDENTITY = {
    "generation" => "daemon-generation-1",
    "pid" => 12_345,
    "process_start_time" => "process-start-1"
  }.freeze

  Row = Struct.new(
    :project, :slug, :folder, :workflow, :stage, :marker, :marker_attrs,
    :task_generation, :condition_task_generation, :commit_generation,
    :attempt_id, :state_file_mtime,
    keyword_init: true
  )

  def row(stage: "4-execute", marker: "waiting", task_generation: "task-generation-1",
          slug: "ship-it")
    Row.new(
      project: "demo", slug: slug, folder: "/tmp/#{slug}",
      workflow: "coding", stage: stage, marker: marker,
      marker_attrs: { "marker_id" => "marker-1" },
      task_generation: task_generation, condition_task_generation: "condition-1",
      commit_generation: 2, attempt_id: "attempt-1", state_file_mtime: T0
    )
  end

  def build(path)
    store = Hive::Daemon::OperationalSnapshot::Store.new(path: path)
    assembler = Hive::Daemon::OperationalSnapshot::Assembler.new(
      store: store, daemon_identity: IDENTITY, poll_interval_sec: 30
    )
    reader = Hive::Daemon::OperationalSnapshot::Reader.new(
      path: path, expected_daemon: IDENTITY
    )
    [ store, assembler, reader ]
  end

  def test_complete_record_is_private_atomic_and_current
    with_tmp_dir do |dir|
      path = File.join(dir, "private", "operational-snapshot.json")
      _store, assembler, reader = build(path)
      observed = row

      assembler.begin_tick(now: T0)
      assembler.observe(
        observed, decision: "global_cap", owner: "scheduler",
        reason: "global dispatch capacity is exhausted"
      )
      assembler.complete(
        initial_rows: [ observed ], final_rows: [ observed ],
        controller: { "limits" => { "global" => 2 }, "in_flight" => 2 },
        queue: { "pending" => 1 }, recoveries: {}, now: T0 + 1
      )

      snapshot = reader.read(now: T0 + 2)

      assert_equal "current", snapshot.fetch("status")
      assert_equal "complete", snapshot.fetch("phase")
      assert_equal "global_cap", snapshot.dig("tasks", 0, "disposition", "decision")
      assert_equal 0o700, File.stat(File.dirname(path)).mode & 0o777
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_empty Dir.glob(File.join(File.dirname(path), ".*tmp*"))
    end
  end

  def test_started_and_failed_records_are_never_authoritative
    with_tmp_dir do |dir|
      path = File.join(dir, "snapshot", "state.json")
      _store, assembler, reader = build(path)

      assembler.begin_tick(now: T0)
      assert_equal "unavailable", reader.read(now: T0).fetch("status")
      assert_equal "started", reader.read(now: T0).fetch("phase")

      assembler.fail(reason: "status_failure", now: T0 + 1)
      failed = reader.read(now: T0 + 1)
      assert_equal "unavailable", failed.fetch("status")
      assert_equal "failed", failed.fetch("phase")
      assert_equal "status_failure", failed.fetch("reason")
      assert_empty Array(failed["tasks"])
    end
  end

  def test_changed_row_stays_visible_with_unavailable_disposition
    with_tmp_dir do |dir|
      path = File.join(dir, "snapshot", "state.json")
      _store, assembler, reader = build(path)
      before = row
      after = row(stage: "5-open-pr", marker: "complete")

      assembler.begin_tick(now: T0)
      assembler.observe(before, decision: "dispatched", owner: "scheduler", reason: "dispatched")
      assembler.complete(
        initial_rows: [ before ], final_rows: [ after ], controller: {}, queue: {},
        recoveries: {}, now: T0 + 1
      )

      disposition = reader.read(now: T0 + 2).dig("tasks", 0, "disposition")
      assert_equal "unavailable", disposition.fetch("status")
      assert_equal "changed_during_tick", disposition.fetch("reason")
      assert_nil disposition["decision"]
    end
  end

  def test_added_and_removed_rows_are_retained_as_unavailable
    with_tmp_dir do |dir|
      path = File.join(dir, "snapshot", "state.json")
      _store, assembler, reader = build(path)
      removed = row(slug: "removed")
      added = row(slug: "added")

      assembler.begin_tick(now: T0)
      assembler.complete(
        initial_rows: [ removed ], final_rows: [ added ], controller: {}, queue: {},
        recoveries: {}, now: T0 + 1
      )

      reasons = reader.read(now: T0 + 2).fetch("tasks").to_h do |task|
        [ task.dig("identity", "slug"), task.dig("disposition", "reason") ]
      end
      assert_equal "added_during_tick", reasons.fetch("added")
      assert_equal "removed_during_tick", reasons.fetch("removed")
    end
  end

  def test_reader_rejects_expired_previous_generation_and_corrupt_records
    with_tmp_dir do |dir|
      path = File.join(dir, "snapshot", "state.json")
      _store, assembler, reader = build(path)
      observed = row
      assembler.begin_tick(now: T0)
      assembler.complete(
        initial_rows: [ observed ], final_rows: [ observed ], controller: {}, queue: {},
        recoveries: {}, now: T0
      )

      assert_equal "stale", reader.read(now: T0 + 91).fetch("status")

      other = reader.class.new(
        path: path,
        expected_daemon: IDENTITY.merge("generation" => "daemon-generation-2")
      )
      assert_equal "invalid", other.read(now: T0 + 1).fetch("status")

      File.write(path, "not json")
      assert_equal "invalid", reader.read(now: T0 + 1).fetch("status")
    end
  end

  def test_store_and_reader_reject_symlink_redirection
    with_tmp_dir do |dir|
      target_dir = File.join(dir, "target")
      FileUtils.mkdir_p(target_dir)
      redirected = File.join(dir, "snapshot")
      File.symlink(target_dir, redirected)
      path = File.join(redirected, "state.json")
      store = Hive::Daemon::OperationalSnapshot::Store.new(path: path)

      assert_raises(Hive::Daemon::OperationalSnapshot::SecurityError) do
        store.write({ "schema" => "anything" })
      end

      File.write(File.join(target_dir, "state.json"), "{}")
      reader = Hive::Daemon::OperationalSnapshot::Reader.new(
        path: path, expected_daemon: IDENTITY
      )
      assert_equal "invalid", reader.read(now: T0).fetch("status")
    end
  end
end
