require "test_helper"
require "digest"
require "fileutils"
require "tmpdir"
require "hive/daemon/recovery_coordinator"
require "hive/daemon/dispatch_request_queue"
require "hive/lock"
require "hive/markers"

class HiveDaemonRecoveryCoordinatorTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 25, 12, 0, 0)
  Q = Hive::Daemon::DispatchRequestQueue

  FakeTask = Data.define(:id, :slug, :folder, :state_file, :stage_index, :stage_name)
  FakeRow = Data.define(
    :project, :slug, :folder, :state_file, :stage, :workflow, :marker,
    :marker_attrs, :state_file_mtime, :live_task_lock, :attempt_id,
    :task_generation, :suggested_command
  )
  FakeGeneration = Data.define(:progress_token, :task_generation)

  def test_shared_hourly_cooldown_ignores_later_provider_reset_hint
    with_fixture(marker_attrs: {
      "reason" => "limits_reached",
      "marker_id" => "marker-1",
      "retry_after" => (NOW + 3 * 3600).iso8601
    }, mtime: NOW - 3600) do |coordinator, row, state_home|
      write_terminal_recovery_history(
        row: row, state_home: state_home, retry_count: 25
      )
      receipt = coordinator.request(
        row: row, requestor: "healer", request_id: "auto-26",
        now: NOW
      )

      assert_equal "queued", receipt.status
      assert_equal 26, receipt.retry_count
      assert_equal NOW.iso8601(6), receipt.next_eligible_at
      request = Q.pending(state_home: state_home).fetch(0)
      assert_equal "admitted", request.recovery.fetch("phase")
      assert_equal (NOW + 3 * 3600).iso8601,
                   request.recovery.dig("provider_hint", "retry_after")
      assert_equal true, request.recovery.dig("provider_hint", "display_only")
    end
  end

  def test_request_before_cooldown_returns_cooldown_without_writing
    with_fixture(mtime: NOW - 3599) do |coordinator, row, state_home|
      receipt = coordinator.request(
        row: row, requestor: "web", request_id: "too-early", now: NOW
      )

      assert_equal "cooldown", receipt.status
      assert_equal (NOW + 1).iso8601(6), receipt.next_eligible_at
      assert_empty Q.pending(state_home: state_home)
    end
  end

  def test_racing_callers_converge_on_one_caller_stable_request
    with_fixture do |coordinator, row, state_home|
      web = coordinator.request(
        row: row, requestor: "web", request_id: "web-action", now: NOW
      )
      bot = coordinator.request(
        row: row, requestor: "bot", request_id: "bot-action", now: NOW
      )
      healer = coordinator.request(
        row: row, requestor: "healer", request_id: "auto-action", now: NOW
      )

      assert_equal %w[queued queued queued], [ web.status, bot.status, healer.status ]
      assert_equal [ "web-action" ], [ web.request_id, bot.request_id, healer.request_id ].uniq
      assert_equal [ 1 ], [ web.retry_count, bot.retry_count, healer.retry_count ].uniq
      assert_equal 1, Q.pending(state_home: state_home).size
    end
  end

  def test_resume_clears_exact_marker_and_persists_post_clear_generation
    with_fixture do |coordinator, row, state_home|
      queued = coordinator.request(
        row: row, requestor: "web", request_id: "recover-1", now: NOW
      )
      request = Q.pending(state_home: state_home).fetch(0)
      observed_generation = request.recovery.fetch("observed_marker_generation")

      resumed = coordinator.resume(request: request, row: row)

      assert_equal "queued", resumed.status
      assert_equal "cleared", resumed.phase
      assert Hive::Markers.current(row.state_file).none?
      updated = Q.pending(state_home: state_home).fetch(0)
      assert_equal "cleared", updated.recovery.fetch("phase")
      assert_equal updated.recovery.fetch("dispatch_generation"), updated.task_generation
      refute_equal observed_generation, updated.task_generation
      assert_equal queued.request_id, resumed.request_id
    end
  end

  def test_restart_after_marker_clear_recovers_from_expected_post_clear_fingerprint
    with_fixture do |coordinator, row, state_home|
      coordinator.request(
        row: row, requestor: "healer", request_id: "recover-crash", now: NOW
      )
      request = Q.pending(state_home: state_home).fetch(0)
      Hive::Markers.clear_current(
        row.state_file,
        expected_name: :error,
        match_attrs: { "marker_id" => "marker-1", "reason" => "timeout" },
        purge_history: true
      )

      resumed = coordinator.resume(request: request, row: row)

      assert_equal "queued", resumed.status
      assert_equal "cleared", resumed.phase
      assert_equal "cleared",
                   Q.pending(state_home: state_home).fetch(0).recovery.fetch("phase")
    end
  end

  def test_resume_rechecks_safety_under_lock_before_clearing
    inspections = 0
    safety = lambda do |_row|
      inspections += 1
      inspections <= 2 ? [ true, "safe at admission" ] :
        [ false, "worktree ownership changed after admission" ]
    end

    with_fixture(safety: safety) do |coordinator, row, state_home|
      coordinator.request(
        row: row, requestor: "web", request_id: "recover-resume-safety", now: NOW
      )
      request = Q.pending(state_home: state_home).fetch(0)

      resumed = coordinator.resume(request: request, row: row)

      assert_equal 3, inspections
      assert_equal "blocked", resumed.status
      assert_equal "safety_blocked", resumed.reason
      assert_equal "operator", resumed.owner
      assert_includes resumed.remediation, "worktree ownership changed"
      assert_equal "marker-1", Hive::Markers.current(row.state_file).attrs.fetch("marker_id")
      persisted = Q.fetch(request.request_id, state_home: state_home).recovery
      assert_equal "admitted", persisted.fetch("phase")
      assert_equal "operator", persisted.fetch("owner")
      assert_includes persisted.fetch("blocked_remediation"), "worktree ownership changed"
    end
  end

  def test_resume_revalidates_task_id_stage_and_canonical_folder
    mutations = {
      task_id: ->(task, _dir) { task.with(id: 818) },
      stage: ->(task, _dir) { task.with(stage_index: 5, stage_name: "open-pr") },
      folder: lambda do |task, dir|
        folder = File.join(dir, "moved-task")
        FileUtils.mkdir_p(folder)
        state_file = File.join(folder, "task.md")
        FileUtils.cp(task.state_file, state_file)
        task.with(folder: folder, state_file: state_file)
      end
    }

    mutations.each do |dimension, mutate|
      resolutions = 0
      builder = lambda do |task, dir|
        changed = mutate.call(task, dir)
        lambda do |**_kwargs|
          resolutions += 1
          resolutions <= 2 ? task : changed
        end
      end

      with_fixture(task_resolver_builder: builder) do |coordinator, row, state_home|
        coordinator.request(
          row: row, requestor: "bot",
          request_id: "recover-resume-#{dimension}", now: NOW
        )
        request = Q.pending(state_home: state_home).fetch(0)

        resumed = coordinator.resume(request: request, row: row)

        assert_equal "blocked", resumed.status, dimension
        assert_equal "task_identity_conflict", resumed.reason, dimension
        assert_equal "operator", resumed.owner, dimension
        assert_equal "admitted",
                     Q.fetch(request.request_id, state_home: state_home)
                       .recovery.fetch("phase"),
                     dimension
        assert_equal "marker-1",
                     Hive::Markers.current(row.state_file).attrs.fetch("marker_id"),
                     dimension
        blocked_path = Q.fetch(request.request_id, state_home: state_home).path
        blocked_inode = File.stat(blocked_path).ino

        replayed = coordinator.resume(request: request, row: row)

        assert_equal "blocked", replayed.status, dimension
        assert_equal blocked_inode, File.stat(blocked_path).ino,
                     "an unchanged block must not rewrite the queue file"
      end
    end
  end

  def test_post_clear_restart_rechecks_secret_reason_from_persisted_marker
    attrs = { "reason" => "secret_in_pr_body", "marker_id" => "marker-1" }
    with_fixture(
      marker_attrs: attrs,
      safety: Hive::Daemon::AutoRetrySafety.method(:safe_to_retry?)
    ) do |coordinator, row, state_home|
      coordinator.request(
        row: row, requestor: "healer", request_id: "recover-secret", now: NOW
      )
      request = Q.pending(state_home: state_home).fetch(0)
      assert Hive::Markers.clear_current(
        row.state_file, expected_name: :error, match_attrs: attrs,
        purge_history: true
      )
      File.open(row.state_file, "a") do |file|
        file.write("\napi_key=abcdefghijklmnopqrstuvwxyz123456\n")
      end

      resumed = coordinator.resume(request: request, row: row)

      assert_equal "blocked", resumed.status
      assert_equal "safety_blocked", resumed.reason
      assert_includes resumed.remediation, "credential pattern remains"
      assert_equal "admitted",
                   Q.fetch(request.request_id, state_home: state_home)
                     .recovery.fetch("phase")
    end
  end

  def test_post_clear_restart_rechecks_persisted_tamper_attributes
    attrs = {
      "reason" => "execute_tampered",
      "restored" => "false",
      "marker_id" => "marker-1"
    }
    with_fixture(marker_attrs: attrs) do |coordinator, row, state_home|
      coordinator.request(
        row: row, requestor: "healer", request_id: "recover-tamper", now: NOW
      )
      request = Q.pending(state_home: state_home).fetch(0)
      assert Hive::Markers.clear_current(
        row.state_file, expected_name: :error, match_attrs: attrs,
        purge_history: true
      )
      coordinator.instance_variable_set(
        :@safety,
        Hive::Daemon::AutoRetrySafety.method(:safe_to_retry?)
      )

      resumed = coordinator.resume(request: request, row: row)

      assert_equal "blocked", resumed.status
      assert_equal "safety_blocked", resumed.reason
      assert_includes resumed.remediation, "tampered run were not restored"
      assert_equal "admitted",
                   Q.fetch(request.request_id, state_home: state_home)
                     .recovery.fetch("phase")
    end
  end

  def test_restart_with_unexpected_markerless_progress_blocks_without_fake_phase
    with_fixture do |coordinator, row, state_home|
      coordinator.request(
        row: row, requestor: "healer", request_id: "recover-conflict", now: NOW
      )
      request = Q.pending(state_home: state_home).fetch(0)
      Hive::Markers.clear_current(
        row.state_file,
        expected_name: :error,
        match_attrs: { "marker_id" => "marker-1", "reason" => "timeout" },
        purge_history: true
      )
      File.write(row.state_file, "# operator changed this after clear\n")

      resumed = coordinator.resume(request: request, row: row)

      assert_equal "blocked", resumed.status
      assert_equal "generation_conflict", resumed.reason
      recovery = Q.pending(state_home: state_home).fetch(0).recovery
      assert_equal "admitted", recovery.fetch("phase")
      assert_equal "generation_conflict", recovery.fetch("blocked_reason")
    end
  end

  def test_newer_marker_generation_is_never_cleared
    with_fixture do |coordinator, row, state_home|
      coordinator.request(
        row: row, requestor: "web", request_id: "recover-stale", now: NOW
      )
      request = Q.pending(state_home: state_home).fetch(0)
      Hive::Markers.set(row.state_file, :error, reason: "timeout", marker_id: "marker-2")

      resumed = coordinator.resume(request: request, row: row)

      assert_equal "blocked", resumed.status
      assert_equal "generation_conflict", resumed.reason
      assert_equal "marker-2", Hive::Markers.current(row.state_file).attrs.fetch("marker_id")
    end
  end

  def test_admission_rejects_a_newer_recoverable_marker_generation
    with_fixture do |coordinator, row, state_home|
      Hive::Markers.set(
        row.state_file, :error, reason: "timeout", marker_id: "marker-2"
      )

      receipt = coordinator.request(
        row: row, requestor: "web",
        request_id: "recover-replaced-before-admission", now: NOW
      )

      assert_equal "blocked", receipt.status
      assert_equal "generation_conflict", receipt.reason
      assert_empty Q.pending(state_home: state_home)
    end
  end

  def test_request_reports_resolution_failures_as_recovery_unavailable
    builder = lambda do |_task, _dir|
      ->(**_kwargs) { raise Hive::Error, "resolver offline" }
    end
    with_fixture(task_resolver_builder: builder) do |coordinator, row, state_home|
      receipt = coordinator.request(
        row: row, requestor: "web", request_id: "resolver-failure", now: NOW
      )

      assert_equal "unavailable", receipt.status
      assert_equal "recovery_unavailable", receipt.reason
      assert_includes receipt.remediation, "resolver offline"
      assert_empty Q.pending(state_home: state_home)
    end
  end

  def test_live_task_owner_returns_running_and_safety_failure_returns_blocked
    with_fixture do |coordinator, row, state_home|
      lock = Hive::Lock.acquire_task_lock(row.folder, "attempt_id" => "attempt-live")
      begin
        running = coordinator.request(
          row: row, requestor: "bot", request_id: "recover-live", now: NOW
        )
        assert_equal "running", running.status
        assert_equal "attempt-live", running.attempt_id
        assert_empty Q.pending(state_home: state_home)
      ensure
        Hive::Lock.release_task_lock(row.folder, lock_id: lock.fetch("lock_id"))
      end
    end

    with_fixture(safety: ->(_row) { [ false, "worktree ownership mismatch" ] }) do |coordinator, row, state_home|
      blocked = coordinator.request(
        row: row, requestor: "web", request_id: "recover-unsafe", now: NOW
      )
      assert_equal "blocked", blocked.status
      assert_equal "safety_blocked", blocked.reason
      assert_includes blocked.remediation, "worktree ownership mismatch"
      assert_empty Q.pending(state_home: state_home)
    end
  end

  def test_safety_is_rechecked_under_the_task_lock_before_admission
    inspections = 0
    safety = lambda do |_row|
      inspections += 1
      inspections == 1 ? [ true, "initially safe" ] : [ false, "worktree changed before lock" ]
    end

    with_fixture(safety: safety) do |coordinator, row, state_home|
      receipt = coordinator.request(
        row: row, requestor: "web", request_id: "recover-safety-race", now: NOW
      )

      assert_equal 2, inspections
      assert_equal "blocked", receipt.status
      assert_equal "safety_blocked", receipt.reason
      assert_includes receipt.remediation, "worktree changed before lock"
      assert_empty Q.pending(state_home: state_home)
      assert_equal "marker-1", Hive::Markers.current(row.state_file).attrs.fetch("marker_id")
    end
  end

  def test_canonical_task_is_reresolved_under_lock_and_folder_swap_blocks
    resolutions = 0
    builder = lambda do |task, dir|
      swapped_folder = File.join(dir, "swapped-task")
      FileUtils.mkdir_p(swapped_folder)
      swapped_state = File.join(swapped_folder, "task.md")
      FileUtils.cp(task.state_file, swapped_state)
      swapped = task.with(folder: swapped_folder, state_file: swapped_state)
      lambda do |**_kwargs|
        resolutions += 1
        resolutions == 1 ? task : swapped
      end
    end

    with_fixture(task_resolver_builder: builder) do |coordinator, row, state_home|
      receipt = coordinator.request(
        row: row, requestor: "bot", request_id: "recover-folder-swap", now: NOW
      )

      assert_equal 2, resolutions
      assert_equal "blocked", receipt.status
      assert_equal "task_identity_conflict", receipt.reason
      assert_empty Q.pending(state_home: state_home)
      assert_equal "marker-1", Hive::Markers.current(row.state_file).attrs.fetch("marker_id")
    end
  end

  def test_observation_token_is_rechecked_against_locked_state_file_mtime
    with_fixture do |coordinator, row, state_home|
      token = Hive::Daemon::RecoveryCoordinator.observation_token(row)
      changed_at = row.state_file_mtime + 1
      File.utime(changed_at, changed_at, row.state_file)

      receipt = coordinator.request(
        row: row,
        requestor: "action",
        request_id: "recover-stale-token",
        observation_token: token,
        now: NOW
      )

      assert_equal "blocked", receipt.status
      assert_equal "stale_observation", receipt.reason
      assert_empty Q.pending(state_home: state_home)
      assert_equal "marker-1", Hive::Markers.current(row.state_file).attrs.fetch("marker_id")
    end
  end

  def test_resolved_safety_block_is_cleared_before_dispatch
    inspections = 0
    safety = lambda do |_row|
      inspections += 1
      inspections == 3 ? [ false, "temporary ownership mismatch" ] : [ true, "safe" ]
    end

    with_fixture(safety: safety) do |coordinator, row, state_home|
      coordinator.request(
        row: row, requestor: "healer", request_id: "recover-resolved-block", now: NOW
      )
      request = Q.pending(state_home: state_home).fetch(0)
      blocked = coordinator.resume(request: request, row: row, now: NOW)
      assert_equal "blocked", blocked.status

      resumed = coordinator.resume(request: request, row: row, now: NOW + 1)

      assert_equal "queued", resumed.status
      assert_equal "cleared", resumed.phase
      persisted = Q.fetch(request.request_id, state_home: state_home).recovery
      assert_nil persisted.fetch("blocked_reason")
      assert_nil persisted.fetch("blocked_remediation")
      assert_equal "scheduler", persisted.fetch("owner")
    end
  end

  def test_resume_reports_a_live_lock_owner_and_resolution_failure
    with_fixture do |coordinator, row, state_home|
      coordinator.request(
        row: row, requestor: "healer", request_id: "recover-resume-errors",
        now: NOW
      )
      request = Q.fetch("recover-resume-errors", state_home: state_home)
      error = Hive::ConcurrentRunError.new(
        "busy", holder: { "attempt_id" => "attempt-live" }
      )

      running = with_replaced_singleton_method(
        Hive::Lock, :with_task_lock,
        ->(*_args, &_block) { raise error }
      ) do
        coordinator.resume(request: request, row: row, now: NOW)
      end

      assert_equal "running", running.status
      assert_equal "attempt-live", running.attempt_id
      assert_equal "existing_live", running.reason

      coordinator.instance_variable_set(
        :@task_resolver,
        ->(**_kwargs) { raise Hive::Error, "task disappeared" }
      )
      unavailable = coordinator.resume(request: request, row: row, now: NOW)

      assert_equal "unavailable", unavailable.status
      assert_includes unavailable.reason, "task disappeared"
    end
  end

  def test_dispatched_replay_is_idempotent_and_invalid_source_fails_closed
    with_fixture do |coordinator, row, state_home|
      coordinator.request(
        row: row, requestor: "healer", request_id: "recover-dispatch",
        now: NOW
      )
      admitted = Q.fetch("recover-dispatch", state_home: state_home)

      invalid = coordinator.mark_dispatched(
        admitted, attempt_id: "attempt-too-early", now: NOW
      )
      assert_equal "unavailable", invalid.status
      assert_equal "transition_conflict", invalid.reason

      coordinator.resume(request: admitted, row: row, now: NOW)
      cleared = Q.fetch("recover-dispatch", state_home: state_home)
      first = coordinator.mark_dispatched(
        cleared, attempt_id: "attempt-1", now: NOW
      )
      replay = coordinator.mark_dispatched(
        cleared, attempt_id: "attempt-1", now: NOW + 1
      )

      assert_equal "running", first.status
      assert_equal "running", replay.status
      assert_equal "attempt-1", replay.attempt_id
    end
  end

  def test_receipt_helpers_fail_closed_for_unknown_or_missing_requests
    request = Q::Request.new(
      request_id: "unknown-phase",
      recovery: {
        "phase" => "mystery",
        "failure_origin" => "timeout",
        "next_eligible_at" => NOW.iso8601(6),
        "owner" => "scheduler"
      }
    )
    coordinator = Hive::Daemon::RecoveryCoordinator.new(
      state_home: "/tmp/hive-recovery-receipts"
    )

    assert_equal "unavailable", coordinator.receipt_for_request(request).status
    assert_nil coordinator.receipt_for_id("missing")
  end

  def test_defensive_recovery_helpers_keep_the_closed_contract
    coordinator = Hive::Daemon::RecoveryCoordinator.new(
      state_home: "/tmp/hive-recovery-helpers"
    )
    indexable = Class.new do
      def [](key)
        "value-for-#{key}"
      end
    end.new

    assert_equal(
      Hive::Daemon::RecoveryCoordinator.observation_token(
        "state_file_mtime" => "not-a-time"
      ),
      Hive::Daemon::RecoveryCoordinator.observation_token(
        "state_file_mtime" => "still-not-a-time"
      )
    )
    assert_equal "value-for-slug", coordinator.send(:value, indexable, :slug)
    assert_nil coordinator.send(:value, Object.new, :slug)
    assert_raises(ArgumentError) do
      coordinator.send(
        :clear_recoverable_marker, "/tmp/task.md",
        expected_name: "complete", match_attrs: {}
      )
    end
    assert coordinator.send(
      :recovery_due?, { "next_eligible_at" => "not-a-time" }, now: NOW
    )
    assert_equal(
      "transition_conflict",
      coordinator.send(
        :unavailable_request, request_for_helpers, "transition_conflict"
      ).reason
    )
    assert_includes(
      coordinator.send(:remediation_for, "transition_conflict"),
      "another recovery owner"
    )
    assert_includes(
      coordinator.send(:remediation_for, "unexpected"),
      "inspect the recovery request"
    )

    malformed_command = FakeRow.new(
      project: "hive", slug: "demo-task", folder: "/tmp/demo-task",
      state_file: "/tmp/demo-task/task.md", stage: "4-execute",
      workflow: "coding", marker: "error", marker_attrs: {},
      state_file_mtime: NOW, live_task_lock: false, attempt_id: nil,
      task_generation: nil, suggested_command: "'unterminated"
    )
    error = assert_raises(Hive::Error) do
      coordinator.send(:retry_argv, malformed_command)
    end
    assert_includes error.message, "invalid retry command"
  end

  def test_assessment_and_resolved_block_updates_fail_closed
    coordinator = Hive::Daemon::RecoveryCoordinator.new(
      state_home: "/tmp/hive-recovery-assessment",
      safety: ->(_row) { raise IOError, "inspection failed" }
    )
    assessment = coordinator.assessment(
      { "state_file_mtime" => NOW - 3600 }, now: NOW
    )
    assert_equal false, assessment.fetch(:due)
    assert_equal false, assessment.fetch(:safe)
    assert_includes assessment.fetch(:safety_reason), "inspection failed"

    request = request_for_helpers(
      recovery: {
        "phase" => "cleared",
        "failure_origin" => "timeout",
        "next_eligible_at" => NOW.iso8601(6),
        "owner" => "operator",
        "blocked_reason" => "safety_blocked",
        "blocked_remediation" => "worktree dirty"
      }
    )
    refreshed = request.dup
    refreshed.recovery = request.recovery.merge(
      "owner" => "scheduler",
      "blocked_reason" => nil,
      "blocked_remediation" => nil
    )
    queue = Object.new
    queue.define_singleton_method(:update_recovery!) { |*_args, **_kwargs| true }
    queue.define_singleton_method(:fetch) { |*_args, **_kwargs| refreshed }
    successful = Hive::Daemon::RecoveryCoordinator.new(
      state_home: "/tmp/hive-recovery-block", request_queue: queue
    )

    assert_same(
      refreshed,
      successful.send(:clear_resolved_block, request, request_locked: true)
    )

    queue.define_singleton_method(:update_recovery!) { |*_args, **_kwargs| false }
    queue.define_singleton_method(:fetch) { |*_args, **_kwargs| nil }
    assert_same(
      request,
      successful.send(:clear_resolved_block, request, request_locked: true)
    )
  end

  def test_post_clear_dispatch_failure_uses_durable_hourly_pacing
    with_fixture do |coordinator, row, state_home|
      coordinator.request(
        row: row, requestor: "healer", request_id: "recover-spawn-failure", now: NOW
      )
      request = Q.pending(state_home: state_home).fetch(0)
      coordinator.resume(request: request, row: row, now: NOW)
      cleared = Q.fetch(request.request_id, state_home: state_home)

      deferred = coordinator.defer_dispatch_failure(cleared, now: NOW + 5)
      early = coordinator.resume(request: cleared, row: row, now: NOW + 6)
      due = coordinator.resume(request: cleared, row: row, now: NOW + 3_605)

      assert_equal "cooldown", deferred.status
      assert_equal (NOW + 3_605).iso8601(6), deferred.next_eligible_at
      assert_equal "cooldown", early.status
      assert_equal "queued", due.status
      assert_equal "cleared", due.phase
    end
  end

  def test_idless_task_is_not_persisted_as_an_unrecoverable_request
    with_fixture(task_id: nil) do |coordinator, row, state_home|
      receipt = coordinator.request(
        row: row, requestor: "healer", request_id: "recover-idless", now: NOW
      )

      assert_equal "blocked", receipt.status
      assert_equal "missing_task_id", receipt.reason
      assert_equal "hive", receipt.owner
      assert_empty Q.pending(state_home: state_home)
      assert_equal :error, Hive::Markers.current(row.state_file).name
    end
  end

  def test_idless_recovery_marker_requires_one_off_migration
    attrs = { "reason" => "timeout" }
    with_fixture(marker_attrs: attrs) do |coordinator, row, state_home|
      receipt = coordinator.request(
        row: row, requestor: "healer", request_id: "old-marker", now: NOW
      )

      assert_equal "blocked", receipt.status
      assert_equal "recovery_migration_required", receipt.reason
      assert_equal "operator", receipt.owner
      assert_includes receipt.remediation, "hive migrate"
      assert_empty Q.pending(state_home: state_home)
    end
  end

  private

  def request_for_helpers(recovery: nil)
    Q::Request.new(
      request_id: "helper-request",
      project: "hive",
      slug: "demo-task",
      recovery: recovery || {
        "phase" => "cleared",
        "failure_origin" => "timeout",
        "next_eligible_at" => NOW.iso8601(6),
        "owner" => "scheduler"
      }
    )
  end

  def write_terminal_recovery_history(row:, state_home:, retry_count:)
    Q.write_request!(
      project: row.project,
      slug: row.slug,
      argv: [ "hive", "run", row.slug, "--stage", row.stage,
              "--project", row.project, "--json" ],
      requestor: "healer",
      trigger: "recovery",
      request_id: "previous-terminal",
      task_generation: "c" * 64,
      task_id: 817,
      expected_stage: row.stage,
      expected_marker_name: "error",
      expected_marker_id: "previous-marker",
      recovery: {
        "phase" => "terminal",
        "observed_marker_generation" => "d" * 64,
        "expected_marker_attrs" => {
          "marker_id" => "previous-marker", "reason" => "timeout"
        },
        "canonical_task_folder" => row.folder,
        "expected_post_clear_progress_fingerprint" => "e" * 64,
        "dispatch_generation" => "c" * 64,
        "failure_origin" => "timeout",
        "next_eligible_at" => NOW.iso8601(6),
        "owner" => "none",
        "blocked_reason" => nil,
        "blocked_remediation" => nil,
        "retry_count" => retry_count,
        "attempt_id" => "attempt-previous",
        "terminal_outcome" => "failed",
        "terminal_at" => (NOW - 60).iso8601(6)
      },
      state_home: state_home,
      now: NOW - 60
    )
  end

  def with_fixture(marker_attrs: nil, mtime: NOW - 3600, safety: nil,
                   task_resolver_builder: nil, task_id: 817)
    Dir.mktmpdir("hive-recovery-coordinator") do |dir|
      folder = File.join(dir, "task")
      FileUtils.mkdir_p(folder)
      state_file = File.join(folder, "task.md")
      attrs = marker_attrs || { "reason" => "timeout", "marker_id" => "marker-1" }
      File.write(state_file, "# Task\n\n#{Hive::Markers.build_marker("ERROR", attrs)}\n")
      File.utime(mtime, mtime, state_file)
      task = FakeTask.new(
        id: task_id, slug: "demo-task", folder: folder, state_file: state_file,
        stage_index: 4, stage_name: "execute"
      )
      row = FakeRow.new(
        project: "hive", slug: task.slug, folder: folder, state_file: state_file,
        stage: "4-execute", workflow: "coding", marker: "error",
        marker_attrs: attrs, state_file_mtime: mtime, live_task_lock: false,
        attempt_id: nil, task_generation: nil,
        suggested_command: "hive run demo-task --stage 4-execute --project hive --json"
      )
      task_resolver = if task_resolver_builder
        task_resolver_builder.call(task, dir)
      else
        ->(**_kwargs) { task }
      end
      coordinator = Hive::Daemon::RecoveryCoordinator.new(
        state_home: dir,
        task_resolver: task_resolver,
        safety: safety || ->(_row) { [ true, "safe" ] },
        generation_resolver: lambda do |resolved_task, project:, intended_stage:, state_file_content:|
          progress = Digest::SHA256.hexdigest(
            [ resolved_task.state_file, state_file_content ].join("\0")
          )
          FakeGeneration.new(
            progress_token: progress,
            task_generation: Digest::SHA256.hexdigest(
              [ project, intended_stage, progress ].join("\0")
            )
          )
        end
      )
      yield coordinator, row, dir
    end
  end
end
