require "test_helper"
require "hive/attempts/supervisor"

class AttemptsSupervisorTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)

  def test_claims_before_worker_and_writes_failed_receipt_with_ordered_output
    with_attempt do |store, attempt|
      ready_r, ready_w = IO.pipe
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        worker_argv: [ "/bin/sh", "-c", "printf out; printf err >&2; exit 7" ],
        ready_io: ready_w, heartbeat_sec: 0.01, stale_sec: 1,
        first_heartbeat_timeout_sec: 1
      )

      exit_status = supervisor.run
      ready_w.close unless ready_w.closed?
      readiness = JSON.parse(ready_r.read)
      terminal = store.fetch(attempt.attempt_id)

      assert_equal true, readiness["claimed"]
      assert_equal 7, exit_status
      assert_equal "terminal", terminal.state
      assert_equal "failed", terminal.outcome
      assert_equal 7, terminal.receipt.fetch("exit_status")
      frames = Hive::Attempts::StreamLog.read(File.join(store.root, terminal.receipt.dig("log_reference", "path")))
      assert_equal %w[err out], frames.map(&:bytes).sort
      assert terminal["worker"].fetch("pid").positive?
    ensure
      ready_r&.close unless ready_r&.closed?
    end
  end

  def test_timeout_is_terminal_cancelled_and_kills_worker_group
    with_attempt do |store, attempt|
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        worker_argv: [ "/bin/sh", "-c", "sleep 10" ],
        heartbeat_sec: 0.01, stale_sec: 1, first_heartbeat_timeout_sec: 1,
        timeout_sec: 0.05, kill_grace_sec: 0.01
      )

      assert_equal 124, supervisor.run
      terminal = store.fetch(attempt.attempt_id)
      assert_equal "cancelled", terminal.outcome
      assert_equal 124, terminal.receipt.fetch("exit_status")
    end
  end

  def test_lost_claim_exits_without_starting_worker
    with_attempt do |store, attempt|
      store.mark_lost(attempt, reason: "launch_timeout", now: NOW + 2)
      sentinel = File.join(store.root, "worker-started")
      supervisor = Hive::Attempts::Supervisor.new(
        store: store, attempt_id: attempt.attempt_id,
        worker_argv: [ "/bin/sh", "-c", "touch #{sentinel}" ],
        first_heartbeat_timeout_sec: 1
      )

      assert_equal Hive::ExitCodes::TEMPFAIL, supervisor.run
      refute File.exist?(sentinel)
      assert_equal "lost", store.fetch(attempt.attempt_id).state
    end
  end

  private

  def with_attempt
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      attempt = store.create_launching(
        attempt_id: "attempt-1", request_id: "request-1", predecessor_attempt_id: nil,
        task_id: "42", project: "demo", task_slug: "durable-task",
        intended_stage: "4-execute", task_generation: "generation-1",
        progress_token: "progress-1", provider: "codex", starting_revision: nil,
        retry_charge: 0, inherited_outputs: [], launch_timeout_sec: 30, now: Time.now.utc
      )
      yield store, attempt
    end
  end
end
