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
    :attempt_id, :status_payload_mtime, :state_file_mtime, :action, :depends_on, :blocked_by,
    :dependency_stage, :blocked, :admission_error,
    keyword_init: true
  )

  def row(stage: "4-execute", marker: "waiting", task_generation: "task-generation-1",
          slug: "ship-it", marker_attrs: { "marker_id" => "marker-1" },
          status_payload_mtime: nil, state_file_mtime: T0, action: "ready_to_run", depends_on: nil,
          blocked_by: nil, dependency_stage: nil, blocked: false, admission_error: nil,
          folder: nil)
    folder ||= "/tmp/#{slug}"
    Row.new(
      project: "demo", slug: slug, folder: folder,
      workflow: "coding", stage: stage, marker: marker,
      marker_attrs: marker_attrs,
      task_generation: task_generation, condition_task_generation: "condition-1",
      commit_generation: 2, attempt_id: "attempt-1",
      status_payload_mtime: status_payload_mtime,
      state_file_mtime: state_file_mtime,
      action: action, depends_on: depends_on, blocked_by: blocked_by,
      dependency_stage: dependency_stage, blocked: blocked, admission_error: admission_error
    )
  end

  def test_scheduler_identity_uses_status_payload_mtime_for_controller_rows
    with_tmp_dir do |dir|
      path = File.join(dir, "private", "operational-snapshot.json")
      _store, assembler, reader = build(path)
      payload_mtime = "2026-08-25T00:17:21.900432Z"
      observed = row(
        status_payload_mtime: payload_mtime,
        state_file_mtime: Time.utc(2026, 8, 25, 0, 10, 48, 584_735)
      )

      assembler.begin_tick(now: T0)
      assembler.complete(
        rows: [ observed ], controller: {}, queue: {}, recoveries: {}, now: T0 + 1
      )

      snapshot = reader.read(now: T0 + 2)
      assert_equal payload_mtime, snapshot.dig("tasks", 0, "status_payload_mtime")
      assert_equal "2026-08-25T00:10:48.584735Z",
                   snapshot.dig("tasks", 0, "state_file_mtime")
    end
  end

  def build(path)
    store = Hive::Daemon::OperationalSnapshot::Store.new(path: path)
    cache_path = "#{path}.status-cache"
    assembler = Hive::Daemon::OperationalSnapshot::Assembler.new(
      store: store,
      status_cache_store: Hive::Daemon::OperationalSnapshot::StatusCache::Store.new(
        path: cache_path
      ),
      daemon_identity: IDENTITY, poll_interval_sec: 30
    )
    reader = Hive::Daemon::OperationalSnapshot::Reader.new(
      path: path, expected_daemon: IDENTITY
    )
    cache_reader = Hive::Daemon::OperationalSnapshot::StatusCache::Reader.new(
      path: cache_path
    )
    [ store, assembler, reader, cache_reader ]
  end

  def cache_store(path)
    Hive::Daemon::OperationalSnapshot::StatusCache::Store.new(
      path: "#{path}.status-cache"
    )
  end

  def test_complete_record_is_private_atomic_and_current
    with_tmp_dir do |dir|
      path = File.join(dir, "private", "operational-snapshot.json")
      _store, assembler, reader = build(path)
      observed = row

      assembler.begin_tick(now: T0)
      assembler.update_attempt_storage(
        "status" => "healthy",
        "layout" => { "generation" => 4, "migration" => "complete" },
        "hot" => { "records" => 2, "invalid" => 0 },
        "maintenance" => {
          "last_started_at" => T0.iso8601(6),
          "last_completed_at" => T0.iso8601(6),
          "last_result" => { "promoted" => 1, "deleted" => 2, "cold_examined" => 2 }
        },
        "last_error" => nil,
        "degraded_reason" => nil
      )
      assembler.observe(
        observed, decision: "global_cap", owner: "scheduler",
        reason: "global dispatch capacity is exhausted",
        routing: { "decision_id" => "route-decision-1", "reason" => "capacity_saturated" },
        retry_at: (T0 + 3_600).iso8601(6),
        retry_due: false,
        retry_safe: true,
        safety_reason: "worktree clean"
      )
      assembler.complete(
        rows: [ observed ], hidden_archived_task_count: 2,
        controller: { "limits" => { "global" => 2 }, "in_flight" => 2 },
        queue: { "pending" => 1 },
        recoveries: {}, now: T0 + 1
      )

      snapshot = reader.read(now: T0 + 2)

      assert_equal "current", snapshot.fetch("status")
      assert_equal "complete", snapshot.fetch("phase")
      assert_equal "global_cap", snapshot.dig("tasks", 0, "disposition", "decision")
      assert_equal (T0 + 3_600).iso8601(6),
                   snapshot.dig("tasks", 0, "disposition", "retry_at")
      assert_equal false, snapshot.dig("tasks", 0, "disposition", "retry_due")
      assert_equal true, snapshot.dig("tasks", 0, "disposition", "retry_safe")
      assert_equal "route-decision-1",
                   snapshot.dig("tasks", 0, "disposition", "routing", "decision_id")
      assert_equal 2, snapshot.dig("attempt_storage", "hot", "records")
      assert_equal "complete", snapshot.dig("attempt_storage", "layout", "migration")
      assert_equal 2, snapshot.fetch("hidden_archived_task_count")
      assert_equal 0o700, File.stat(File.dirname(path)).mode & 0o777
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_empty Dir.glob(File.join(File.dirname(path), ".*tmp*"))
    end
  end

  def test_hidden_archive_count_is_published_from_the_tick_snapshot
    with_tmp_dir do |dir|
      path = File.join(dir, "private", "operational-snapshot.json")
      _store, assembler, reader = build(path)
      observed = row

      assembler.begin_tick(now: T0)
      assembler.complete(
        rows: [ observed ], hidden_archived_task_count: 2,
        controller: {}, queue: {}, recoveries: {}, now: T0 + 1
      )

      snapshot = reader.read(now: T0 + 2)
      assert_equal "current", snapshot.fetch("status")
      assert_equal 2, snapshot.fetch("hidden_archived_task_count")
    end
  end

  def test_completed_scheduler_and_status_cache_remain_current_while_the_next_tick_runs
    with_tmp_dir do |dir|
      path = File.join(dir, "private", "operational-snapshot.json")
      _store, assembler, reader, cache_reader = build(path)
      payload = {
        "schema" => "hive-status", "schema_version" => 7, "ok" => true,
        "generated_at" => T0.iso8601(6), "projects" => []
      }

      assembler.begin_tick(now: T0)
      assembler.complete(
        rows: [], controller: {}, queue: {}, recoveries: {},
        status_payload: payload, now: T0 + 1
      )

      complete = reader.read(now: T0 + 2)
      cache = cache_reader.read(snapshot: complete, now: T0 + 2)
      refute complete.key?("status_cache")
      assert_equal payload, cache.fetch("payload")
      assert_equal "release", cache.dig("runtime", "channel")
      assert_equal 1, cache.fetch("tick_sequence")
      assert_equal (T0 + 91).iso8601(6), cache.fetch("valid_until")

      assembler.begin_tick(now: T0 + 31)
      retained_snapshot = reader.read(now: T0 + 32)
      retained = cache_reader.read(snapshot: retained_snapshot, now: T0 + 32)
      assert_equal "current", retained_snapshot.fetch("status")
      assert_equal "complete", retained_snapshot.fetch("phase")
      refute retained_snapshot.key?("status_cache")
      assert_equal payload, retained.fetch("payload")
      assert_equal 1, retained.fetch("tick_sequence")
      assert_equal 1, retained_snapshot.fetch("tick_sequence")
    end
  end

  def test_failed_later_tick_preserves_the_last_completed_scheduler_snapshot
    with_tmp_dir do |dir|
      path = File.join(dir, "private", "operational-snapshot.json")
      _store, assembler, reader = build(path)
      observed = row

      assembler.begin_tick(now: T0)
      assembler.complete(
        rows: [ observed ], controller: { "in_flight" => 1 },
        queue: { "pending" => 2 }, recoveries: {}, now: T0 + 1
      )
      completed_bytes = File.binread(path)

      assembler.begin_tick(now: T0 + 31)
      assembler.fail(reason: "status_failure", now: T0 + 32)

      assert_equal completed_bytes, File.binread(path)
      retained = reader.read(now: T0 + 33)
      assert_equal "current", retained.fetch("status")
      assert_equal 1, retained.fetch("tick_sequence")
      assert_equal 1, retained.dig("capacity", "in_flight")
      assert_equal 2, retained.dig("queue", "pending")

      assembler.begin_tick(now: T0 + 61)
      assembler.complete(
        rows: [ row(slug: "next") ], controller: { "in_flight" => 0 },
        queue: { "pending" => 0 }, recoveries: {}, now: T0 + 62
      )

      replacement = reader.read(now: T0 + 63)
      assert_equal "current", replacement.fetch("status")
      assert_equal 3, replacement.fetch("tick_sequence")
      assert_equal "next", replacement.dig("tasks", 0, "identity", "slug")
    end
  end

  def test_reader_rejects_a_malformed_status_cache
    with_tmp_dir do |dir|
      path = File.join(dir, "private", "operational-snapshot.json")
      _store, assembler, reader, cache_reader = build(path)
      assembler.begin_tick(now: T0)
      assembler.complete(rows: [], controller: {}, queue: {}, recoveries: {}, now: T0 + 1)
      cache_store(path).write(
        "schema" => Hive::Daemon::OperationalSnapshot::StatusCache::SCHEMA,
        "schema_version" => 1,
        "daemon" => IDENTITY,
        "tick_sequence" => 1,
        "published_at" => (T0 + 1).iso8601(6),
        "valid_until" => (T0 + 90).iso8601(6),
        "payload" => { "schema" => "wrong", "ok" => true }
      )

      snapshot = reader.read(now: T0 + 1)

      assert_equal "current", snapshot.fetch("status")
      assert_nil cache_reader.read(snapshot: snapshot, now: T0 + 1)
    end
  end

  def test_reader_rejects_a_status_cache_from_a_future_tick
    with_tmp_dir do |dir|
      path = File.join(dir, "private", "operational-snapshot.json")
      _store, assembler, reader, cache_reader = build(path)
      assembler.begin_tick(now: T0)
      assembler.complete(rows: [], controller: {}, queue: {}, recoveries: {}, now: T0 + 1)
      cache_store(path).write(
        "schema" => Hive::Daemon::OperationalSnapshot::StatusCache::SCHEMA,
        "schema_version" => 1,
        "daemon" => IDENTITY,
        "tick_sequence" => 2,
        "published_at" => (T0 + 1).iso8601(6),
        "valid_until" => (T0 + 90).iso8601(6),
        "payload" => {
          "schema" => "hive-status", "schema_version" => 7, "ok" => true,
          "generated_at" => T0.iso8601(6), "projects" => []
        }
      )

      snapshot = reader.read(now: T0 + 1)

      assert_equal "current", snapshot.fetch("status")
      assert_nil cache_reader.read(snapshot: snapshot, now: T0 + 1)
    end
  end

  def test_malformed_status_payload_does_not_prevent_the_scheduler_snapshot
    with_tmp_dir do |dir|
      path = File.join(dir, "private", "operational-snapshot.json")
      _store, assembler, reader, cache_reader = build(path)
      assembler.begin_tick(now: T0)

      assembler.complete(
        rows: [], controller: {}, queue: {}, recoveries: {},
        status_payload: {
          "schema" => "hive-status", "schema_version" => 7, "ok" => true,
          "generated_at" => "not-a-time", "projects" => []
        },
        now: T0 + 1
      )

      snapshot = reader.read(now: T0 + 2)
      assert_equal "current", snapshot.fetch("status")
      assert_nil cache_reader.read(snapshot: snapshot, now: T0 + 2)
    end
  end

  def test_status_cache_write_failure_does_not_prevent_the_scheduler_snapshot
    with_tmp_dir do |dir|
      path = File.join(dir, "private", "operational-snapshot.json")
      store = Hive::Daemon::OperationalSnapshot::Store.new(path: path)
      failing_cache_store = Object.new
      failing_cache_store.define_singleton_method(:write) { |_record| raise Errno::EIO, "full" }
      assembler = Hive::Daemon::OperationalSnapshot::Assembler.new(
        store: store, status_cache_store: failing_cache_store,
        daemon_identity: IDENTITY, poll_interval_sec: 30
      )
      reader = Hive::Daemon::OperationalSnapshot::Reader.new(
        path: path, expected_daemon: IDENTITY
      )
      payload = {
        "schema" => "hive-status", "schema_version" => 7, "ok" => true,
        "generated_at" => T0.iso8601(6), "projects" => []
      }

      assembler.begin_tick(now: T0)
      assembler.complete(
        rows: [], controller: {}, queue: {}, recoveries: {},
        status_payload: payload, now: T0 + 1
      )

      assert_equal "current", reader.read(now: T0 + 2).fetch("status")
    end
  end

  def test_status_cache_reader_rejects_malformed_snapshot_deadline
    with_tmp_dir do |dir|
      cache_reader = Hive::Daemon::OperationalSnapshot::StatusCache::Reader.new(
        path: File.join(dir, "missing-cache.json")
      )
      snapshot = {
        "status" => "current", "tick_sequence" => 1, "daemon" => IDENTITY,
        "observed_at" => T0.iso8601(6), "valid_until" => "not-a-time"
      }

      assert_nil cache_reader.read(snapshot: snapshot, now: T0)
    end
  end

  def test_current_snapshot_validity_clamps_a_cache_created_before_reconfigure
    with_tmp_dir do |dir|
      path = File.join(dir, "private", "operational-snapshot.json")
      _store, assembler, reader, cache_reader = build(path)
      payload = {
        "schema" => "hive-status", "schema_version" => 7, "ok" => true,
        "generated_at" => T0.iso8601(6), "projects" => []
      }
      assembler.reconfigure(poll_interval_sec: 300)
      assembler.begin_tick(now: T0)
      assembler.complete(
        rows: [], controller: {}, queue: {}, recoveries: {},
        status_payload: payload, now: T0 + 1
      )
      assembler.reconfigure(poll_interval_sec: 30)
      assembler.begin_tick(now: T0 + 61)

      retained = reader.read(now: T0 + 92)
      assert_equal "stale", retained.fetch("status")
      assert_nil cache_reader.read(snapshot: retained, now: T0 + 92)
    end
  end

  def test_shutdown_acknowledgement_is_generation_bound_and_read_only
    with_tmp_dir do |dir|
      path = File.join(dir, "private", "operational-snapshot.json")
      _store, assembler, reader = build(path)
      assembler.begin_tick(now: T0)
      assembler.shutdown(
        admission_closed: true, drained: true,
        child_inventory: [ { pid: 77, pgid: 77, start_time: "child-start" } ],
        now: T0 + 1
      )
      before = File.binread(path)

      acknowledgement = reader.shutdown_acknowledgement(
        expected_daemon: IDENTITY, now: T0 + 2
      )

      assert_equal before, File.binread(path)
      assert_equal true, acknowledgement.fetch("admission_closed")
      assert_equal [ 77 ], acknowledgement.fetch("child_inventory").map { |entry| entry.fetch("pid") }
      assert_nil reader.shutdown_acknowledgement(
        expected_daemon: IDENTITY.merge("generation" => "other"), now: T0 + 2
      )
    end
  end

  def test_shutdown_acknowledgement_degrades_unavailable_storage_to_nil
    with_tmp_dir do |dir|
      reader = Hive::Daemon::OperationalSnapshot::Reader.new(
        path: File.join(dir, "missing", "snapshot.json"),
        expected_daemon: IDENTITY
      )

      assert_nil reader.shutdown_acknowledgement(
        expected_daemon: IDENTITY,
        now: T0
      )
    end
  end

  def test_runtime_ready_is_published_and_retained_on_later_records
    with_tmp_dir do |dir|
      path = File.join(dir, "private", "operational-snapshot.json")
      _store, assembler, _reader = build(path)

      assembler.runtime_ready(now: T0)
      ready = JSON.parse(File.binread(path))
      assert_equal true, ready.fetch("runtime_ready")
      assert_equal "complete", ready.fetch("phase")

      assembler.begin_tick(now: T0 + 1)
      started = JSON.parse(File.binread(path))
      assert_equal true, started.fetch("runtime_ready")
      assert_equal "started", started.fetch("phase")

      assembler.shutdown(
        admission_closed: true, drained: true,
        child_inventory: [], now: T0 + 2
      )
      shutdown = JSON.parse(File.binread(path))
      assert_equal true, shutdown.fetch("runtime_ready")
      assert shutdown.key?("shutdown")
    end
  end

  def test_reconfigured_validity_is_measured_from_tick_completion
    with_tmp_dir do |dir|
      path = File.join(dir, "private", "operational-snapshot.json")
      _store, assembler, reader = build(path)
      observed = row

      assembler.begin_tick(now: T0)
      assembler.reconfigure(poll_interval_sec: 5)
      assembler.complete(
        rows: [ observed ],
        controller: {}, queue: {}, recoveries: {}, now: T0 + 40
      )

      current = reader.read(now: T0 + 54)
      assert_equal "current", current.fetch("status")
      assert_equal T0.iso8601(6), current.dig("source_window", "started_at")
      assert_equal (T0 + 40).iso8601(6), current.dig("source_window", "completed_at")
      assert_equal (T0 + 55).iso8601(6), current.fetch("valid_until")
      assert_equal "stale", reader.read(now: T0 + 56).fetch("status")
    end
  end

  def test_terminal_recovery_does_not_hide_a_fresh_failure_marker
    with_tmp_dir do |dir|
      path = File.join(dir, "private", "operational-snapshot.json")
      _store, assembler, reader = build(path)
      fresh = row(
        marker: "error",
        marker_attrs: { "reason" => "timeout", "marker_id" => "marker-2" }
      )
      receipt = {
        "status" => "terminal",
        "request_id" => "recovery-1",
        "attempt_id" => "attempt-1",
        "phase" => "terminal",
        "terminal_outcome" => "failed"
      }
      recoveries = {
        "coordinator" => {
          "receipts" => [
            {
              "project" => "demo",
              "slug" => "ship-it",
              "stage" => "4-execute",
              "recovery_phase" => "terminal",
              "expected_marker_name" => "error",
              "expected_marker_attrs" => {
                "reason" => "timeout",
                "marker_id" => "marker-1"
              },
              "receipt" => receipt
            }
          ]
        }
      }

      assembler.begin_tick(now: T0)
      assembler.observe(
        fresh,
        decision: "retry_cooldown",
        owner: "scheduler",
        reason: "new marker is cooling down",
        retry_at: (T0 + 3_600).iso8601(6)
      )
      assembler.complete(
        rows: [ fresh ],
        controller: {},
        queue: {},
        recoveries: recoveries,
        now: T0 + 1
      )

      disposition = reader.read(now: T0 + 2).dig("tasks", 0, "disposition")
      assert_equal "retry_cooldown", disposition.fetch("decision")
      refute disposition.key?("recovery")
    end
  end

  def test_terminal_recovery_remains_visible_with_successful_workflow_marker
    with_tmp_dir do |dir|
      path = File.join(dir, "private", "operational-snapshot.json")
      _store, assembler, reader = build(path)
      completed = row(marker: "waiting", marker_attrs: {})
      receipt = {
        "status" => "terminal",
        "request_id" => "recovery-1",
        "attempt_id" => "attempt-1",
        "phase" => "terminal",
        "terminal_outcome" => "succeeded"
      }
      recoveries = {
        "coordinator" => {
          "receipts" => [
            {
              "project" => "demo",
              "slug" => "ship-it",
              "stage" => "4-execute",
              "recovery_phase" => "terminal",
              "expected_marker_name" => "error",
              "expected_marker_attrs" => { "reason" => "timeout" },
              "receipt" => receipt
            }
          ]
        }
      }

      assembler.begin_tick(now: T0)
      assembler.complete(
        rows: [ completed ],
        controller: {}, queue: {}, recoveries: recoveries, now: T0 + 1
      )

      disposition = reader.read(now: T0 + 2).dig("tasks", 0, "disposition")
      assert_equal "attempt_terminal_replay", disposition.fetch("decision")
      assert_equal receipt, disposition.fetch("recovery")
    end
  end

  def test_terminal_recovery_does_not_overlay_a_different_live_attempt
    with_tmp_dir do |dir|
      path = File.join(dir, "private", "operational-snapshot.json")
      _store, assembler, reader = build(path)
      live = row(marker: "agent_working", marker_attrs: {})
      live.attempt_id = "attempt-2"
      receipt = {
        "status" => "terminal",
        "request_id" => "recovery-1",
        "attempt_id" => "attempt-1",
        "phase" => "terminal",
        "terminal_outcome" => "failed"
      }
      recoveries = {
        "coordinator" => {
          "receipts" => [
            {
              "project" => "demo",
              "slug" => "ship-it",
              "stage" => "4-execute",
              "recovery_phase" => "terminal",
              "expected_marker_name" => "error",
              "expected_marker_attrs" => { "reason" => "timeout" },
              "receipt" => receipt
            }
          ]
        }
      }

      assembler.begin_tick(now: T0)
      assembler.observe(
        live, decision: "in_flight", owner: "agent",
        reason: "a newer durable attempt is running"
      )
      assembler.complete(
        rows: [ live ],
        controller: {}, queue: {}, recoveries: recoveries, now: T0 + 1
      )

      disposition = reader.read(now: T0 + 2).dig("tasks", 0, "disposition")
      assert_equal "in_flight", disposition.fetch("decision")
      refute disposition.key?("recovery")
    end
  end

  def test_recovery_overlay_matches_the_exact_marker_generation_and_post_clear_state
    with_tmp_dir do |dir|
      _store, assembler, _reader = build(File.join(dir, "snapshot.json"))
      task = {
        "stage" => "4-execute",
        "marker" => "error",
        "marker_attrs" => { "marker_id" => "marker-1", "reason" => "timeout" }
      }
      index = { [ "demo", "ship-it" ] => task }
      admitted = {
        "project" => "demo",
        "slug" => "ship-it",
        "recovery_phase" => "admitted",
        "expected_marker_name" => "error",
        "expected_marker_attrs" => {
          "marker_id" => "marker-1", "reason" => "timeout"
        }
      }

      assert_same task, assembler.send(:find_recovery_task, index, admitted)
      assert_nil assembler.send(
        :find_recovery_task, index,
        admitted.merge("expected_marker_name" => "review_error")
      )
      assert_nil assembler.send(
        :find_recovery_task, index,
        admitted.merge(
          "expected_marker_attrs" => {
            "marker_id" => "marker-2", "reason" => "timeout"
          }
        )
      )

      cleared = admitted.merge("recovery_phase" => "cleared")
      task["marker"] = "none"
      assert_same task, assembler.send(:find_recovery_task, index, cleared)
      task["marker"] = "error"
      assert_nil assembler.send(:find_recovery_task, index, cleared)
    end
  end

  def test_markerless_recovery_overlay_requires_the_exact_generation_and_no_failure_marker
    with_tmp_dir do |dir|
      _store, assembler, _reader = build(File.join(dir, "snapshot.json"))
      task = {
        "stage" => "4-execute", "marker" => "none", "marker_attrs" => {},
        "task_generation" => "generation-1"
      }
      index = { [ "demo", "ship-it" ] => task }
      markerless = {
        "project" => "demo", "slug" => "ship-it",
        "recovery_variant" => "admission_failure",
        "task_generation" => "generation-1"
      }

      assert_same task, assembler.send(:find_recovery_task, index, markerless)
      assert_nil assembler.send(
        :find_recovery_task, index, markerless.merge("task_generation" => "generation-2")
      )
      task["marker"] = "error"
      assert_nil assembler.send(:find_recovery_task, index, markerless)
    end
  end

  def test_provider_hold_without_stage_or_reason_still_matches_the_current_task
    with_tmp_dir do |dir|
      path = File.join(dir, "private", "operational-snapshot.json")
      _store, assembler, reader = build(path)
      held = row(
        marker: "error",
        marker_attrs: {
          "reason" => "limits_reached", "provider" => "codex",
          "retry_after" => (T0 + 3_600).iso8601
        }
      )

      assembler.begin_tick(now: T0)
      assembler.complete(
        rows: [ held ], controller: {}, queue: {},
        recoveries: {}, now: T0 + 1
      )

      task = reader.read(now: T0 + 2).fetch("tasks").first
      assert_equal "provider_hold", task.dig("disposition", "decision")
      assert_equal "provider", task.dig("disposition", "owner")
      assert_includes task.dig("disposition", "reason"), "codex quota hold"
    end
  end

  def test_duplicate_project_slug_rows_fail_the_whole_snapshot_closed
    with_tmp_dir do |dir|
      path = File.join(dir, "private", "operational-snapshot.json")
      _store, assembler, reader = build(path)
      held = row(
        stage: "4-execute", marker: "error", folder: "/tmp/4-execute/ship-it",
        marker_attrs: { "reason" => "limits_reached", "provider" => "codex" }
      )
      replacement = row(stage: "5-open-pr", folder: "/tmp/5-open-pr/ship-it")

      assembler.begin_tick(now: T0)
      assembler.complete(
        rows: [ held, replacement ],
        controller: {}, queue: {}, recoveries: {}, now: T0 + 1
      )

      snapshot = reader.read(now: T0 + 2)
      assert_equal "unavailable", snapshot.fetch("status")
      assert_equal "failed", snapshot.fetch("phase")
      assert_equal "duplicate_task_identity: demo:ship-it", snapshot.fetch("reason")
      assert_empty snapshot.fetch("tasks")
      assert_empty snapshot.fetch("provider_holds")
    end
  end

  def test_duplicate_rows_in_a_later_tick_do_not_erase_the_last_completed_snapshot
    with_tmp_dir do |dir|
      path = File.join(dir, "private", "operational-snapshot.json")
      _store, assembler, reader = build(path)
      original = row

      assembler.begin_tick(now: T0)
      assembler.complete(
        rows: [ original ], controller: {}, queue: {}, recoveries: {}, now: T0 + 1
      )
      assembler.begin_tick(now: T0 + 31)
      assembler.complete(
        rows: [ original, row(stage: "5-open-pr", folder: "/tmp/5-open-pr/ship-it") ],
        controller: {}, queue: {}, recoveries: {}, now: T0 + 32
      )

      retained = reader.read(now: T0 + 33)
      assert_equal "current", retained.fetch("status")
      assert_equal 1, retained.fetch("tick_sequence")
      assert_equal [ "ship-it" ], retained.fetch("tasks").map { |task| task.dig("identity", "slug") }
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

  def test_reader_rejects_expired_previous_generation_and_corrupt_records
    with_tmp_dir do |dir|
      path = File.join(dir, "snapshot", "state.json")
      _store, assembler, reader = build(path)
      observed = row
      assembler.begin_tick(now: T0)
      assembler.complete(
        rows: [ observed ], controller: {}, queue: {},
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

  def test_reader_rejects_a_complete_record_without_a_source_window
    with_tmp_dir do |dir|
      path = File.join(dir, "snapshot", "state.json")
      _store, assembler, reader = build(path)
      assembler.begin_tick(now: T0)
      assembler.complete(
        rows: [ row ], controller: {}, queue: {}, recoveries: {}, now: T0 + 1
      )
      record = JSON.parse(File.read(path))
      record.delete("source_window")
      File.write(path, JSON.generate(record))

      snapshot = reader.read(now: T0 + 2)

      assert_equal "invalid", snapshot.fetch("status")
      assert_equal "snapshot_invalid", snapshot.fetch("reason")
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

  def test_assembler_normalizes_hash_rows_strings_arrays_and_times
    with_tmp_dir do |dir|
      _store, assembler, _reader = build(File.join(dir, "snapshot", "state.json"))

      assert_equal "symbol", assembler.send(:value, { field: "symbol" }, :field)
      assert_equal "string", assembler.send(:value, { "field" => "string" }, :field)
      assert_nil assembler.send(:value, {}, :field)
      assert_equal "already-normalized", assembler.send(:time_string, "already-normalized")
      assert_equal(
        [ { "at" => T0.iso8601(6) } ],
        assembler.send(:canonical, [ { at: T0 } ])
      )
    end
  end

  def test_reader_distinguishes_missing_and_unreadable_snapshots
    with_tmp_dir do |dir|
      missing = Hive::Daemon::OperationalSnapshot::Reader.new(
        path: File.join(dir, "missing", "state.json"), expected_daemon: IDENTITY
      ).read(now: T0)
      assert_equal "unavailable", missing.fetch("status")
      assert_equal "snapshot_missing", missing.fetch("reason")

      parent = File.join(dir, "snapshot")
      FileUtils.mkdir_p(parent, mode: 0o700)
      path = File.join(parent, "state.json")
      File.write(path, "{}", mode: "w", perm: 0o600)
      original_read = File.method(:read)
      unreadable = with_replaced_singleton_method(File, :read, lambda { |candidate, *args|
        raise Errno::EIO, "forced read failure" if candidate == path

        original_read.call(candidate, *args)
      }) do
        Hive::Daemon::OperationalSnapshot::Reader.new(
          path: path, expected_daemon: IDENTITY
        ).read(now: T0)
      end

      assert_equal "unavailable", unreadable.fetch("status")
      assert_equal "snapshot_unreadable", unreadable.fetch("reason")
      assert_match(/Errno::EIO/, unreadable.fetch("detail"))
    end
  end

  def test_auto_daemon_identity_validates_pid_record_and_process_generation
    with_tmp_dir do |dir|
      pid_path = File.join(dir, ".daemon.pid")
      reader = Hive::Daemon::OperationalSnapshot::Reader.new(
        path: File.join(dir, "state.json"), pid_path: pid_path
      )

      File.write(pid_path, YAML.dump([]))
      assert_equal :unavailable, reader.send(:expected_daemon)

      File.write(pid_path, YAML.dump("pid" => "bad", "process_start_time" => ""))
      assert_equal :unavailable, reader.send(:expected_daemon)

      File.write(pid_path, YAML.dump("pid" => 12_345, "process_start_time" => "process-start-1"))
      identity = with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { true }) do
        with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(_pid) { "process-start-1" }) do
          reader.send(:expected_daemon)
        end
      end
      assert_equal Hive::Daemon::OperationalSnapshot.daemon_identity(
        pid: 12_345, process_start_time: "process-start-1"
      ), identity

      mismatch = with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { true }) do
        with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(_pid) { "different-start" }) do
          reader.send(:expected_daemon)
        end
      end
      assert_equal :unavailable, mismatch

      gone = with_replaced_singleton_method(
        Process, :kill, ->(_signal, _pid) { raise Errno::ESRCH, "gone" }
      ) do
        reader.send(:expected_daemon)
      end
      assert_equal :unavailable, gone
    end
  end

  def test_complete_rejects_invalid_hidden_archive_counts
    with_tmp_dir do |dir|
      _store, assembler, _reader = build(File.join(dir, "snapshot.json"))
      assembler.begin_tick(now: T0)

      error = assert_raises(ArgumentError) do
        assembler.complete(
          rows: [], hidden_archived_task_count: -1,
          controller: {}, queue: {}, recoveries: {}, now: T0 + 1
        )
      end

      assert_includes error.message, "hidden_archived_task_count"
      assert_includes error.message, "non-negative integer"
    end
  end
end
