require "test_helper"
require "json_schemer"
require "timeout"
require "hive/running_status"

class RunningStatusTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 8, 24, 12, 0, 0)

  def test_empty_snapshot_is_small_complete_and_schema_valid
    with_project do |project, _hive_state|
      payload = status.payload([ project ], now: NOW)

      assert_equal "hive-running-status", payload.fetch("schema")
      assert_equal 2, payload.fetch("schema_version")
      assert_equal 0, payload.dig("source", "lease_rows_scanned")
      assert_equal 10_000, payload.dig("limits", "max_lease_rows_scanned")
      assert_equal [], payload.fetch("tasks")
      assert_equal 0, payload.fetch("count")
      assert_equal 0, payload.fetch("observed_count")
      assert_equal true, payload.fetch("observed_count_exact")
      assert_equal true, payload.fetch("complete")
      assert_equal "release", payload.dig("runtime", "channel")
      assert_equal false, payload.fetch("truncated")
      assert_equal true, payload.fetch("omitted_count_exact")
      assert_operator JSON.generate(payload).bytesize, :<, 64 * 1024
      assert_schema_valid(payload)
    end
  end

  def test_dogfood_snapshot_identifies_the_active_build
    sha = "0864de726d9a75f7bc46610a89db851c90b402ee"
    runtime = Hive::RuntimeIdentity.new(environment: {
      "HIVE_RUNTIME_CHANNEL" => "dogfood",
      "HIVE_RUNTIME_BUILD_SHA" => sha,
      "HIVE_RUNTIME_DEPLOYMENT_ID" => "hive-dogfood-0864de726"
    }).to_h
    payload = Hive::RunningStatus.new(
      daemon_state: daemon_state.merge(runtime: runtime),
      runtime_identity: runtime
    ).payload([], now: NOW)

    assert_equal "dogfood", payload.dig("runtime", "channel")
    assert_equal sha, payload.dig("runtime", "build_sha")
    assert_schema_valid(payload)
  end

  def test_live_daemon_runtime_wins_over_the_observing_cli_runtime
    sha = "0864de726d9a75f7bc46610a89db851c90b402ee"
    observer_runtime = Hive::RuntimeIdentity.new(environment: {
      "HIVE_RUNTIME_CHANNEL" => "dogfood",
      "HIVE_RUNTIME_BUILD_SHA" => sha,
      "HIVE_RUNTIME_DEPLOYMENT_ID" => "hive-dogfood-0864de726"
    }).to_h
    payload = Hive::RunningStatus.new(
      daemon_state: daemon_state.merge(runtime: Hive::RuntimeIdentity.new.to_h),
      runtime_identity: observer_runtime
    ).payload([], now: NOW)

    assert_equal "release", payload.dig("runtime", "channel")
    assert_nil payload.dig("runtime", "build_sha")
    assert_schema_valid(payload)
  end

  def test_live_legacy_daemon_runtime_fails_closed_instead_of_using_the_observer
    sha = "0864de726d9a75f7bc46610a89db851c90b402ee"
    observer_runtime = Hive::RuntimeIdentity.new(environment: {
      "HIVE_RUNTIME_CHANNEL" => "dogfood",
      "HIVE_RUNTIME_BUILD_SHA" => sha,
      "HIVE_RUNTIME_DEPLOYMENT_ID" => "hive-dogfood-0864de726"
    }).to_h
    payload = Hive::RunningStatus.new(
      daemon_state: daemon_state(runtime: nil),
      runtime_identity: observer_runtime
    ).payload([], now: NOW)

    assert_equal "unknown", payload.dig("runtime", "channel")
    assert_nil payload.dig("runtime", "build_sha")
    assert_schema_valid(payload)
  end

  def test_missing_hive_state_path_is_unavailable_not_relative_to_cwd
    project = { "name" => "missing", "path" => Dir.pwd, "hive_state_path" => nil }

    payload = status.payload([ project ], now: NOW)

    assert_equal [], payload.fetch("tasks")
    assert_equal 1, payload.dig("source", "projects_unavailable")
    assert_equal false, payload.fetch("complete")
  end

  def test_missing_stages_root_marks_project_unavailable
    with_tmp_dir do |project_root|
      project = {
        "name" => "missing-stages",
        "path" => project_root,
        "hive_state_path" => File.join(project_root, ".hive-state")
      }

      payload = status.payload([ project ], now: NOW)

      assert_equal [], payload.fetch("tasks")
      assert_equal 1, payload.dig("source", "projects_unavailable")
      assert_equal false, payload.fetch("complete")
    end
  end

  def test_project_scan_failure_marks_only_that_project_unavailable
    failing_status = Class.new(Hive::RunningStatus) do
      private

      def real_directory?(_path)
        raise Errno::EIO, "project became unreadable"
      end
    end.new(daemon_state: daemon_state)
    project = { "name" => "unreadable", "hive_state_path" => "/unreadable" }

    payload = failing_status.payload([ project ], now: NOW)

    assert_equal [], payload.fetch("tasks")
    assert_equal 1, payload.dig("source", "projects_unavailable")
    assert_equal false, payload.fetch("complete")
  end

  def test_live_task_lock_without_agent_pid_is_running
    with_project do |project, hive_state|
      folder = task_folder(hive_state, "1-inbox", "lock-only-task")
      write_lock(folder, "pid" => Process.pid, "lock_id" => "lock-only")

      row = status.payload([ project ], now: NOW).fetch("tasks").fetch(0)

      assert_equal "running", row.fetch("status")
      assert_equal "agent_running", row.fetch("action")
      assert_nil row.fetch("marker")
      assert_equal true, row.dig("liveness", "running")
      assert_equal "task_lock", row.dig("liveness", "source")
      assert_equal true, row.dig("liveness", "task_lock_alive")
      assert_nil row.dig("liveness", "agent_pid_alive")
    end
  end

  def test_live_pid_without_recorded_identity_is_stale
    with_project do |project, hive_state|
      folder = task_folder(hive_state, "1-inbox", "unverified-task")
      write_lock(
        folder,
        "pid" => Process.pid, "process_start_time" => nil,
        "lock_id" => "unverified"
      )

      payload = status.payload([ project ], now: NOW)

      assert_equal [], payload.fetch("tasks")
      assert_equal 1, payload.dig("source", "stale_locks")
    end
  end

  def test_descriptor_valid_numeric_and_long_stage_name_is_scanned
    with_project do |project, hive_state|
      stage = "2-9numeric-and-#{'long' * 30}"
      folder = task_folder(hive_state, stage, "custom-stage-task")
      write_lock(folder, "pid" => Process.pid, "lock_id" => "custom-stage")

      row = status.payload([ project ], now: NOW).fetch("tasks").fetch(0)

      assert_equal stage, row.fetch("stage")
      assert_equal true, row.dig("liveness", "running")
    end
  end

  def test_live_agent_pid_keeps_orphaned_task_visible
    with_project do |project, hive_state|
      folder = task_folder(hive_state, "4-execute", "live-agent-task")
      write_lock(
        folder,
        "pid" => 2_147_483_647,
        "process_start_time" => "dead-runner",
        "claude_pid" => Process.pid,
        "claude_pid_start_time" => Hive::Lock.process_start_time(Process.pid),
        "lock_id" => "live-agent"
      )

      row = status.payload([ project ], now: NOW).fetch("tasks").fetch(0)

      assert_equal "agent_pid", row.dig("liveness", "source")
      assert_equal false, row.dig("liveness", "task_lock_alive")
      assert_equal true, row.dig("liveness", "agent_pid_alive")
      assert_equal Process.pid, row.dig("liveness", "agent_pid")
    end
  end

  def test_runner_and_agent_identities_are_both_reported
    with_project do |project, hive_state|
      folder = task_folder(hive_state, "4-execute", "two-live-processes")
      write_lock(
        folder,
        "pid" => Process.pid,
        "claude_pid" => Process.pid,
        "claude_pid_start_time" => live_start_time,
        "lock_id" => "both-live"
      )

      row = status.payload([ project ], now: NOW).fetch("tasks").fetch(0)

      assert_equal "task_lock_and_agent_pid", row.dig("liveness", "source")
      assert_equal true, row.dig("liveness", "task_lock_alive")
      assert_equal true, row.dig("liveness", "agent_pid_alive")
      assert_equal Process.pid, row.dig("liveness", "runner_pid")
      assert_equal Process.pid, row.dig("liveness", "agent_pid")
    end
  end

  def test_invalid_agent_pid_is_reported_dead_without_hiding_live_runner
    with_project do |project, hive_state|
      folder = task_folder(hive_state, "4-execute", "invalid-agent-pid")
      write_lock(
        folder,
        "pid" => Process.pid,
        "claude_pid" => "not-an-integer",
        "lock_id" => "invalid-agent"
      )

      row = status.payload([ project ], now: NOW).fetch("tasks").fetch(0)

      assert_equal true, row.dig("liveness", "task_lock_alive")
      assert_equal false, row.dig("liveness", "agent_pid_alive")
      assert_nil row.dig("liveness", "agent_pid")
    end
  end

  def test_stale_lock_is_omitted
    with_project do |project, hive_state|
      folder = task_folder(hive_state, "3-plan", "stale-task")
      write_lock(folder, "pid" => 2_147_483_647, "lock_id" => "stale")

      payload = status.payload([ project ], now: NOW)

      assert_equal [], payload.fetch("tasks")
      assert_equal 1, payload.dig("source", "stale_locks")
    end
  end

  def test_stale_sql_holders_before_a_live_holder_do_not_hide_live_work
    with_project do |project, hive_state|
      (Hive::RunningStatus::MAX_TASKS + 2).times do |index|
        folder = task_folder(hive_state, "3-plan", format("stale-%03d", index))
        write_lock(folder, "pid" => 2_147_483_647, "process_start_time" => "dead")
      end
      live = task_folder(hive_state, "4-execute", "live-after-stale")
      write_lock(live, "pid" => Process.pid)

      payload = status.payload([ project ], now: NOW)

      assert_equal [ "live-after-stale" ], payload.fetch("tasks").map { |row| row.fetch("slug") }
      assert_equal Hive::RunningStatus::MAX_TASKS + 2,
                   payload.dig("source", "stale_locks")
    end
  end

  def test_reused_runner_pid_with_mismatched_start_time_is_stale
    with_project do |project, hive_state|
      folder = task_folder(hive_state, "3-plan", "reused-pid-task")
      write_lock(
        folder,
        "pid" => Process.pid,
        "process_start_time" => "not-the-live-process-start",
        "lock_id" => "reused"
      )

      payload = status.payload([ project ], now: NOW)

      assert_equal [], payload.fetch("tasks")
      assert_equal 1, payload.dig("source", "stale_locks")
    end
  end

  def test_reused_agent_pid_with_mismatched_start_time_is_stale
    with_project do |project, hive_state|
      folder = task_folder(hive_state, "4-execute", "reused-agent-task")
      write_lock(
        folder,
        "pid" => 2_147_483_647,
        "process_start_time" => "dead-runner",
        "claude_pid" => Process.pid,
        "claude_pid_start_time" => "not-the-live-process-start",
        "lock_id" => "reused-agent"
      )

      payload = status.payload([ project ], now: NOW)

      assert_equal [], payload.fetch("tasks")
      assert_equal 1, payload.dig("source", "stale_locks")
    end
  end

  def test_out_of_range_pid_is_stale_instead_of_aborting_snapshot
    with_project do |project, hive_state|
      folder = task_folder(hive_state, "1-inbox", "huge-pid-task")
      write_lock(
        folder,
        "pid" => 10**100,
        "process_start_time" => "impossible",
        "lock_id" => "huge-pid"
      )

      payload = status.payload([ project ], now: NOW)

      assert_equal [], payload.fetch("tasks")
      assert_equal 1, payload.dig("source", "stale_locks")
    end
  end

  def test_transition_during_lock_read_is_skipped
    with_project do |project, hive_state|
      folder = task_folder(hive_state, "2-brainstorm", "moving-task")
      write_lock(folder, "pid" => Process.pid, "lock_id" => "moving")
      FileUtils.mv(folder, "#{folder}-moved")

      payload = status.payload([ project ], now: NOW)

      assert_equal [], payload.fetch("tasks")
      assert_equal 1, payload.dig("source", "transition_skips")
    end
  end

  def test_malformed_metadata_does_not_hide_a_live_task
    with_project do |project, hive_state|
      folder = task_folder(hive_state, "1-inbox", "bad-meta-task")
      write_lock(folder, "pid" => Process.pid, "lock_id" => "bad-meta")
      File.write(File.join(folder, "meta.yml"), "display_name: [unterminated\n")

      row = status.payload([ project ], now: NOW).fetch("tasks").fetch(0)

      assert_equal "bad-meta-task", row.fetch("slug")
      assert_nil row.fetch("display_name")
      assert_equal "invalid", row.fetch("metadata_status")
      assert_equal true, row.dig("liveness", "running")
    end
  end

  def test_malformed_lock_is_omitted_and_counted
    with_project do |project, hive_state|
      folder = task_folder(hive_state, "1-inbox", "bad-lock-task")
      write_corrupt_lease(folder, "[")

      payload = status.payload([ project ], now: NOW)

      assert_equal [], payload.fetch("tasks")
      assert_equal 1, payload.dig("source", "malformed_locks")
    end
  end

  def test_structurally_invalid_lease_is_omitted_without_hiding_other_live_work
    with_project do |project, hive_state|
      invalid = task_folder(hive_state, "1-inbox", "invalid-holder")
      write_lock(invalid, "pid" => "not-an-integer")
      live = task_folder(hive_state, "4-execute", "live-holder")
      write_lock(live, "pid" => Process.pid)

      payload = status.payload([ project ], now: NOW)

      assert_equal [ "live-holder" ], payload.fetch("tasks").map { |row| row.fetch("slug") }
      assert_equal 1, payload.dig("source", "malformed_locks")
    end
  end

  def test_deeply_nested_lock_is_omitted_and_counted
    with_project do |project, hive_state|
      folder = task_folder(hive_state, "1-inbox", "nested-lock-task")
      write_corrupt_lease(
        folder, Hive::RuntimeControlPlane::Codec.dump_json("x" * (Hive::RunningStatus::MAX_LOCK_BYTES + 1))
      )

      payload = status.payload([ project ], now: NOW)

      assert_equal [], payload.fetch("tasks")
      assert_equal 1, payload.dig("source", "malformed_locks")
      assert_equal false, payload.fetch("complete")
      assert_schema_valid(payload)
    end
  end

  def test_deeply_nested_metadata_keeps_live_task_with_invalid_metadata
    with_project do |project, hive_state|
      folder = task_folder(hive_state, "1-inbox", "nested-meta-task")
      write_lock(folder, "pid" => Process.pid, "lock_id" => "nested-meta")
      File.write(File.join(folder, "meta.yml"), "display_name: #{deeply_nested_flow_yaml}\n")

      payload = status.payload([ project ], now: NOW)
      row = payload.fetch("tasks").fetch(0)

      assert_equal "invalid", row.fetch("metadata_status")
      assert_equal true, row.dig("liveness", "running")
      assert_schema_valid(payload)
    end
  end

  def test_fifo_metadata_returns_promptly_without_hiding_live_task
    with_project do |project, hive_state|
      folder = task_folder(hive_state, "1-inbox", "fifo-meta-task")
      write_lock(folder, "pid" => Process.pid, "lock_id" => "fifo-meta")
      File.unlink(File.join(folder, "meta.yml"))
      File.mkfifo(File.join(folder, "meta.yml"))

      row = Timeout.timeout(1) do
        status.payload([ project ], now: NOW).fetch("tasks").fetch(0)
      end

      assert_equal "unreadable", row.fetch("metadata_status")
      assert_equal true, row.dig("liveness", "running")
    end
  end

  def test_oversized_metadata_keeps_live_row_with_explicit_status
    with_project do |project, hive_state|
      folder = task_folder(hive_state, "1-inbox", "large-meta-task")
      write_lock(folder, "pid" => Process.pid, "lock_id" => "large-meta")
      File.write(
        File.join(folder, "meta.yml"),
        "display_name: #{'x' * Hive::RunningStatus::MAX_METADATA_BYTES}\n"
      )

      row = status.payload([ project ], now: NOW).fetch("tasks").fetch(0)

      assert_equal "too_large", row.fetch("metadata_status")
      assert_nil row.fetch("display_name")
      assert_equal true, row.dig("liveness", "running")
    end
  end

  def test_metadata_filesystem_error_keeps_live_row_with_unreadable_status
    with_project do |project, hive_state|
      folder = task_folder(hive_state, "1-inbox", "unreadable-meta-task")
      write_lock(folder, "pid" => Process.pid, "lock_id" => "unreadable-meta")
      failing_status = Class.new(Hive::RunningStatus) do
        private

        def bounded_file_read(path, max_bytes)
          raise Errno::EIO, "metadata became unreadable" if File.basename(path) == "meta.yml"

          super
        end
      end.new(daemon_state: daemon_state)

      row = failing_status.payload([ project ], now: NOW).fetch("tasks").fetch(0)

      assert_equal "unreadable", row.fetch("metadata_status")
      assert_equal true, row.dig("liveness", "running")
    end
  end

  def test_metadata_reader_uses_inode_checked_fallback_without_o_nofollow
    with_project do |project, hive_state|
      folder = task_folder(hive_state, "1-inbox", "portable-lock-reader")
      write_lock(folder, "pid" => Process.pid, "lock_id" => "portable-reader")
      original = File.method(:const_defined?)
      replacement = lambda do |name, *args|
        name == :NOFOLLOW ? false : original.call(name, *args)
      end

      payload = with_replaced_singleton_method(File, :const_defined?, replacement) do
        status.payload([ project ], now: NOW)
      end

      assert_equal true, payload.dig("tasks", 0, "liveness", "running")
    end
  end

  def test_rows_strings_and_final_document_are_hard_bounded
    with_project(name: "p" * 1_000) do |project, hive_state|
      (Hive::RunningStatus::MAX_TASKS + 3).times do |index|
        slug = format("bounded-task-%03d", index)
        folder = task_folder(hive_state, "4-execute", slug)
        write_lock(folder, "pid" => Process.pid, "lock_id" => "lock-#{index}")
        Hive::TaskMeta.write(
          folder, id: index, slug: slug, display_name: "d" * 1_000, workflow: "coding"
        )
      end
      database_reads = 0
      original_read = @database.method(:read)
      @database.define_singleton_method(:read) do |&block|
        database_reads += 1
        original_read.call(&block)
      end

      payload = status.payload([ project ], now: NOW)
      encoded = JSON.generate(payload) + "\n"

      assert_equal Hive::RunningStatus::MAX_TASKS, payload.fetch("count")
      assert_equal Hive::RunningStatus::MAX_TASKS + 3, payload.fetch("observed_count")
      assert_equal true, payload.fetch("observed_count_exact")
      assert_equal 3, payload.fetch("omitted_count")
      assert_equal true, payload.fetch("omitted_count_exact")
      assert_equal true, payload.fetch("truncated")
      assert_equal false, payload.fetch("complete")
      assert_operator payload.dig("tasks", 0, "project").bytesize,
                      :<=, Hive::RunningStatus::MAX_STRING_BYTES
      assert_operator payload.dig("tasks", 0, "display_name").bytesize,
                      :<=, Hive::RunningStatus::MAX_STRING_BYTES
      assert_operator encoded.bytesize, :<=, Hive::RunningStatus::MAX_OUTPUT_BYTES
      assert_equal 1, database_reads, "live lease discovery must be one bounded SQL query"
      assert_schema_valid(payload)
    end
  end

  def test_final_document_bound_drops_rows_that_exceed_the_byte_budget
    document = {
      "tasks" => [ { "padding" => "x" * Hive::RunningStatus::MAX_OUTPUT_BYTES } ],
      "count" => 1,
      "observed_count" => 1,
      "omitted_count" => 0,
      "truncated" => false,
      "complete" => true
    }

    status.send(:fit_output_bound!, document)

    assert_equal [], document.fetch("tasks")
    assert_equal 0, document.fetch("count")
    assert_equal 1, document.fetch("omitted_count")
    assert_equal true, document.fetch("truncated")
    assert_equal false, document.fetch("complete")
  end

  def test_active_lease_budget_marks_counts_inexact
    with_project do |project, hive_state|
      folder = task_folder(hive_state, "1-inbox", "not-inspected")
      write_lock(folder, "pid" => Process.pid)
      capped_status = Class.new(Hive::RunningStatus) do
        private

        def max_leases_scanned = 0
      end.new(daemon_state: daemon_state)

      payload = capped_status.payload([ project ], now: NOW)

      assert_equal [], payload.fetch("tasks")
      assert_equal 0, payload.dig("source", "lease_rows_scanned")
      assert_equal 0, payload.dig("source", "tasks_scanned")
      assert_equal true, payload.dig("source", "scan_truncated")
      assert_equal false, payload.fetch("observed_count_exact")
      assert_equal false, payload.fetch("omitted_count_exact")
      assert_equal true, payload.fetch("truncated")
      assert_equal false, payload.fetch("complete")
    end
  end

  def test_project_budget_stops_registry_scan_and_marks_omission
    with_project do |project, _hive_state|
      capped_status = Class.new(Hive::RunningStatus) do
        private

        def max_projects_scanned = 0
      end.new(daemon_state: daemon_state)

      payload = capped_status.payload([ project ], now: NOW)

      assert_equal 1, payload.dig("source", "projects_omitted")
      assert_equal 0, payload.dig("source", "projects_scanned")
      assert_equal true, payload.dig("source", "scan_truncated")
      assert_equal false, payload.fetch("complete")
    end
  end

  def test_stopped_daemon_hides_stale_process_details
    stopped = Hive::RunningStatus.new(
      daemon_state: { running: false, pid: 123, uptime_sec: 45 }
    ).payload([], now: NOW)

    assert_equal false, stopped.dig("daemon", "running")
    assert_nil stopped.dig("daemon", "pid")
    assert_nil stopped.dig("daemon", "uptime_sec")
    assert_schema_valid(stopped)
  end

  def test_daemon_liveness_rejects_legacy_pid_only_identity
    with_tmp_dir do |hive_home|
      File.write(File.join(hive_home, ".daemon.pid"), Process.pid.to_s)
      report = Hive::Daemon::StatusReport.new(hive_home: hive_home)

      payload = Hive::RunningStatus.new(daemon_report: report).payload([], now: NOW)

      assert_equal false, payload.dig("daemon", "running")
      assert_nil payload.dig("daemon", "pid")
      assert_equal "unknown", payload.dig("runtime", "channel")
      assert_schema_valid(payload)
    end
  end

  def test_daemon_pid_probe_rejects_fifo_and_oversized_files_without_blocking
    with_tmp_dir do |hive_home|
      pid_path = File.join(hive_home, ".daemon.pid")
      File.mkfifo(pid_path)
      report = Hive::Daemon::StatusReport.new(hive_home: hive_home)
      running_status = Hive::RunningStatus.new(
        daemon_report: report,
        runtime_identity: Hive::RuntimeIdentity.new(environment: {
          "HIVE_RUNTIME_CHANNEL" => "dogfood",
          "HIVE_RUNTIME_BUILD_SHA" => "0864de726d9a75f7bc46610a89db851c90b402ee",
          "HIVE_RUNTIME_DEPLOYMENT_ID" => "hive-dogfood-0864de726"
        }).to_h
      )

      fifo_payload = Timeout.timeout(1) { running_status.payload([], now: NOW) }
      assert_equal false, fifo_payload.dig("daemon", "running")
      assert_equal "unknown", fifo_payload.dig("runtime", "channel")

      FileUtils.rm_f(pid_path)
      File.write(pid_path, "1" * (Hive::RunningStatus::MAX_DAEMON_PID_BYTES + 1))
      oversized_payload = running_status.payload([], now: NOW)
      assert_equal false, oversized_payload.dig("daemon", "running")
      assert_equal "unknown", oversized_payload.dig("runtime", "channel")
      assert_schema_valid(oversized_payload)
    end
  end

  def test_daemon_pid_probe_rejects_deeply_nested_yaml
    with_tmp_dir do |hive_home|
      File.write(
        File.join(hive_home, ".daemon.pid"),
        "pid: #{deeply_nested_flow_yaml}\n"
      )
      report = Hive::Daemon::StatusReport.new(hive_home: hive_home)

      payload = Hive::RunningStatus.new(daemon_report: report).payload([], now: NOW)

      assert_equal false, payload.dig("daemon", "running")
      assert_nil payload.dig("daemon", "pid")
      assert_equal "unknown", payload.dig("runtime", "channel")
      assert_schema_valid(payload)
    end
  end

  def test_error_envelope_validates_against_running_status_schema
    payload = Hive::Schemas::ErrorEnvelope.build(
      schema: "hive-running-status",
      error: Hive::InternalError.new("compact status failed"),
      error_kind: Hive::Schemas::StatusErrorKind::INTERNAL
    )

    assert_schema_valid(payload)
  end

  private

  def status
    Hive::RunningStatus.new(daemon_state: daemon_state)
  end

  def daemon_state(runtime: Hive::RuntimeIdentity.new.to_h)
    state = { running: true, pid: 123, uptime_sec: 45 }
    state[:runtime] = runtime if runtime
    state
  end

  def with_project(name: "demo")
    with_tmp_dir do |project_root|
      hive_state = File.join(project_root, ".hive-state")
      FileUtils.mkdir_p(File.join(hive_state, "stages"))
      @database = prepare_runtime_project(
        state_home: project_root, name: name, path: project_root,
        state_root_path: hive_state
      )
      prior_repository = Hive::Lock.task_lease_repository
      Hive::Lock.task_lease_repository = Hive::RuntimeControlPlane::TaskLeaseRepository.new(
        database: @database,
        process_start_time: Hive::Lock.method(:process_start_time),
        process_alive: lambda { |pid, recorded_start_time:|
          Hive::Lock.send(
            :process_identity_alive?, pid, recorded_start_time: recorded_start_time
          )
        }
      )
      @next_task_id = 0
      yield(
        { "name" => name, "path" => project_root, "hive_state_path" => hive_state },
        hive_state
      )
    ensure
      Hive::Lock.task_lease_repository = prior_repository if prior_repository
      @database&.disconnect
      @database = nil
    end
  end

  def task_folder(hive_state, stage, slug)
    File.join(hive_state, "stages", stage, slug).tap { |path| FileUtils.mkdir_p(path) }
  end

  def write_lock(folder, attributes)
    attributes = attributes.dup
    if attributes["pid"] == Process.pid && !attributes.key?("process_start_time")
      attributes["process_start_time"] = live_start_time
    end
    ensure_task_identity(folder)
    repository = Hive::Lock.task_lease_repository
    held = repository.acquire(folder, { "op" => "running-status-test" }, create: false)
    repository.update(folder, attributes, lock_id: held.fetch("lock_id"))
    held
  end

  def write_corrupt_lease(folder, payload_json)
    held = write_lock(folder, "pid" => Process.pid)
    @database.transaction do |db|
      db[:task_leases].where(holder_id: held.fetch("lock_id")).update(
        payload_json: payload_json
      )
    end
  end

  def ensure_task_identity(folder)
    return if Hive::TaskMeta.read(folder)[:id]

    @next_task_id += 1
    Hive::TaskMeta.write(
      folder, id: @next_task_id, slug: File.basename(folder), display_name: nil
    )
  end

  def live_start_time
    Hive::Lock.process_start_time(Process.pid) || raise("process start time unavailable")
  end

  def deeply_nested_flow_yaml
    ("[" * 1_500) + "1" + ("]" * 1_500)
  end

  def assert_schema_valid(payload)
    schema = JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-running-status")))
    )
    assert_empty schema.validate(payload).to_a
  end
end
