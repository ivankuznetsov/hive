require "test_helper"
require "hive/attempts/capacity_snapshot"

class AttemptsCapacitySnapshotTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)
  CLAIM_CAPABILITY = "c" * 64

  def test_live_reservations_are_authoritative_and_terminal_lost_are_excluded
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      live = create(store, attempt_id: "live", project: "p1", task_slug: "s1")
      claimed = store.claim(
        live, owner: owner, claim_capability: CLAIM_CAPABILITY,
        first_heartbeat_timeout_sec: 30, now: NOW + 1
      )
      store.first_heartbeat(claimed, stale_sec: 30, now: NOW + 2)

      lost = create(store, attempt_id: "lost", project: "p1", task_slug: "s2", generation: "g2")
      store.mark_lost(lost, reason: "owner_gone", now: NOW + 1)

      snapshot = Hive::Attempts::CapacitySnapshot.build(store: store, now: NOW + 3)
      assert_equal 1, snapshot.global_count
      assert_equal 1, snapshot.project_count("p1")
      assert snapshot.task_reserved?(project: "p1", task_slug: "s1")
      refute snapshot.task_reserved?(project: "p1", task_slug: "s2")
      assert_equal 2, snapshot.daily_count("p1", NOW.to_date),
                   "daily starts retain lost work while live capacity excludes it"
    end
  end

  def test_corrupt_records_reserve_global_capacity_fail_closed
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      File.write(File.join(store.records_root, "corrupt.json"), "{")

      snapshot = Hive::Attempts::CapacitySnapshot.build(store: store, now: NOW)
      assert_equal 1, snapshot.global_count
      assert_equal 1, snapshot.invalid_count
      assert snapshot.at_limit?(project: "p1", task_slug: "s1", date: NOW.to_date,
                                max_global: 1, max_per_project: 2, max_daily: 10)
    end
  end

  def test_invalid_future_timestamp_is_ignored_by_daily_accounting
    record = Object.new
    record.define_singleton_method(:live?) { false }
    record.define_singleton_method(:receipt) { nil }
    record.define_singleton_method(:[]) do |key|
      { "accepted_at" => "not-a-time", "project" => "demo" }.fetch(key)
    end
    scan = Hive::Attempts::Scan.new(records: [ record ], invalid_records: [])
    store = Object.new
    store.define_singleton_method(:scan) { scan }

    snapshot = Hive::Attempts::CapacitySnapshot.build(store: store, now: NOW)
    assert_equal 0, snapshot.daily_count("demo", NOW.to_date)
  end

  private

  def create(store, attempt_id:, project:, task_slug:, generation: "g1")
    store.create_launching(
      attempt_id: attempt_id, request_id: "r-#{attempt_id}", predecessor_attempt_id: nil,
      task_id: "42", project: project, task_slug: task_slug, intended_stage: "4-execute",
      task_generation: generation, progress_token: "progress", provider: "codex",
      worker_argv: [ "hive", "run", task_slug ],
      claim_capability_digest: Hive::Attempts::Capability.digest(CLAIM_CAPABILITY),
      starting_revision: "a" * 40, retry_charge: 0, inherited_outputs: [],
      launch_timeout_sec: 30, now: NOW
    )
  end

  def owner
    { "pid" => Process.pid, "start_fingerprint" => "start",
      "session_id" => Process.getsid(0), "process_group_id" => Process.getpgrp }
  end
end
