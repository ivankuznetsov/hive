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
    :attempt_id, :state_file_mtime, :action, :depends_on, :blocked_by,
    :dependency_stage, :blocked, :admission_error,
    keyword_init: true
  )

  def row(stage: "4-execute", marker: "waiting", task_generation: "task-generation-1",
          slug: "ship-it", marker_attrs: { "marker_id" => "marker-1" },
          state_file_mtime: T0, action: "ready_to_run", depends_on: nil,
          blocked_by: nil, dependency_stage: nil, blocked: false, admission_error: nil,
          folder: nil)
    folder ||= "/tmp/#{slug}"
    Row.new(
      project: "demo", slug: slug, folder: folder,
      workflow: "coding", stage: stage, marker: marker,
      marker_attrs: marker_attrs,
      task_generation: task_generation, condition_task_generation: "condition-1",
      commit_generation: 2, attempt_id: "attempt-1", state_file_mtime: state_file_mtime,
      action: action, depends_on: depends_on, blocked_by: blocked_by,
      dependency_stage: dependency_stage, blocked: blocked, admission_error: admission_error
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
        reason: "global dispatch capacity is exhausted",
        retry_at: (T0 + 3_600).iso8601(6),
        retry_due: false,
        retry_safe: true,
        safety_reason: "worktree clean"
      )
      assembler.complete(
        initial_rows: [ observed ], final_rows: [ observed ],
        initial_hidden_archived_task_count: 2,
        final_hidden_archived_task_count: 2,
        controller: { "limits" => { "global" => 2 }, "in_flight" => 2 },
        queue: { "pending" => 1 }, recoveries: {}, now: T0 + 1
      )

      snapshot = reader.read(now: T0 + 2)

      assert_equal "current", snapshot.fetch("status")
      assert_equal "complete", snapshot.fetch("phase")
      assert_equal "global_cap", snapshot.dig("tasks", 0, "disposition", "decision")
      assert_equal (T0 + 3_600).iso8601(6),
                   snapshot.dig("tasks", 0, "disposition", "retry_at")
      assert_equal false, snapshot.dig("tasks", 0, "disposition", "retry_due")
      assert_equal true, snapshot.dig("tasks", 0, "disposition", "retry_safe")
      assert_equal 2, snapshot.fetch("hidden_archived_task_count")
      assert_equal 0o700, File.stat(File.dirname(path)).mode & 0o777
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_empty Dir.glob(File.join(File.dirname(path), ".*tmp*"))
    end
  end

  def test_hidden_archive_count_change_is_published_from_revalidated_snapshot
    with_tmp_dir do |dir|
      path = File.join(dir, "private", "operational-snapshot.json")
      _store, assembler, reader = build(path)
      observed = row

      assembler.begin_tick(now: T0)
      assembler.complete(
        initial_rows: [ observed ], final_rows: [ observed ],
        initial_hidden_archived_task_count: 1,
        final_hidden_archived_task_count: 2,
        controller: {}, queue: {}, recoveries: {}, now: T0 + 1
      )

      snapshot = reader.read(now: T0 + 2)
      assert_equal "current", snapshot.fetch("status")
      assert_equal 2, snapshot.fetch("hidden_archived_task_count")
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
        initial_rows: [ observed ], final_rows: [ observed ],
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
        initial_rows: [ fresh ],
        final_rows: [ fresh ],
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
        initial_rows: [ completed ], final_rows: [ completed ],
        controller: {}, queue: {}, recoveries: recoveries, now: T0 + 1
      )

      disposition = reader.read(now: T0 + 2).dig("tasks", 0, "disposition")
      assert_equal "attempt_terminal_replay", disposition.fetch("decision")
      assert_equal receipt, disposition.fetch("recovery")
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
        initial_rows: [ held ], final_rows: [ held ], controller: {}, queue: {},
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
        initial_rows: [ held, replacement ], final_rows: [ held, replacement ],
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

  def test_policy_bearing_changes_invalidate_the_tick_disposition
    with_tmp_dir do |dir|
      path = File.join(dir, "snapshot", "state.json")
      _store, assembler, reader = build(path)
      before = row
      after = row(
        marker_attrs: { "marker_id" => "marker-2" },
        state_file_mtime: T0 + 1,
        action: "admission_error",
        depends_on: "demo:base",
        blocked_by: "demo:base",
        dependency_stage: "7-artifacts",
        blocked: true,
        admission_error: {
          "reason_code" => "dependency_task_missing",
          "offending_ref" => "demo:base",
          "safe_correction" => "repair the dependency"
        }
      )

      assembler.begin_tick(now: T0)
      assembler.observe(before, decision: "global_cap", owner: "scheduler", reason: "full")
      assembler.complete(
        initial_rows: [ before ], final_rows: [ after ], controller: {}, queue: {},
        recoveries: {}, now: T0 + 1
      )

      task = reader.read(now: T0 + 2).fetch("tasks").first
      assert_equal "unavailable", task.dig("disposition", "status")
      assert_equal "changed_during_tick", task.dig("disposition", "reason")
      assert_equal "admission_error", task.fetch("action")
      assert_equal true, task.fetch("blocked")
      assert_equal "dependency_task_missing", task.dig("admission_error", "reason_code")
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
end
