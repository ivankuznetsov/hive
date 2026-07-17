require "test_helper"
require "hive/daemon/retry_coordinator"
require "hive/attempts/store"

class RetryCoordinatorTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 17, 10, 0, 0)
  SCHEDULE = [ 60, 60, 60, 300, 600, 3600 ].freeze

  def test_error_agnostic_ladder_repeats_the_last_delay_forever
    with_coordinator do |coordinator, store, _dir, set_now|
      predecessor = failed_attempt(store, id: "attempt-1")
      records = []
      7.times do |index|
        code = index < 5 ? "agent_died" : "codex_auth"
        records << coordinator.report_failure(
          **failure_args(predecessor, terminal_event_id: "terminal-#{index + 1}", code: code)
        )
        set_now.call(NOW + ((index + 1) * 10_000))
        predecessor = failed_attempt(store, id: "attempt-#{index + 2}")
      end

      assert_equal [ 1, 2, 3, 4, 5, 6, 7 ], records.map(&:retry_count)
      delays = records.map do |record|
        Time.iso8601(record.to_h.fetch("retry_after")) - Time.iso8601(record.to_h.fetch("last_failure_at"))
      end
      assert_equal [ 60, 60, 60, 300, 600, 3600, 3600 ], delays
      assert_equal "codex_auth", records.last.failure_code
      refute_equal 1, records.fetch(5).retry_count
    end
  end

  def test_duplicate_terminal_delivery_is_idempotent_across_reconstruction
    with_coordinator do |coordinator, store, dir, _set_now|
      attempt = failed_attempt(store, id: "attempt-1")
      first = coordinator.report_failure(**failure_args(attempt, terminal_event_id: "terminal-1"))

      rebuilt = build_coordinator(dir: dir, store: store, clock: -> { NOW + 30 })
      duplicate = rebuilt.report_failure(**failure_args(attempt, terminal_event_id: "terminal-1"))

      assert_equal first.to_h, duplicate.to_h
      events = Hive::TaskProjection.read_journal(File.join(dir, "events.jsonl"))
      assert_equal 1, events.count { |event| event["event_type"] == "retry_failure_scheduled" }
    end
  end

  def test_deadline_evaluation_is_persisted_and_authorization_is_fenced
    with_coordinator do |coordinator, store, _dir, set_now|
      attempt = failed_attempt(store, id: "attempt-1")
      cooling = coordinator.report_failure(**failure_args(attempt, terminal_event_id: "terminal-1"))

      assert_nil coordinator.evaluate_due
      set_now.call(Time.iso8601(cooling.to_h.fetch("retry_after")))
      ready = coordinator.evaluate_due
      assert_equal "ready", ready.state

      authorization = coordinator.authorize(expected_generation: 3)
      assert_instance_of Hive::Daemon::RetryCoordinator::DispatchAuthorization, authorization
      assert_equal "attempt-1", authorization.predecessor_attempt_id
      assert_raises(Hive::Daemon::StaleRetryGeneration) do
        coordinator.authorize(expected_generation: 2)
      end

      successor = store.create_launching(
        attempt_id: "attempt-2", request_id: "request-2",
        predecessor_attempt_id: attempt.attempt_id,
        task_id: "42", project: "demo", task_slug: "durable-task", intended_stage: "4-execute",
        task_generation: "ownership-1", ownership_generation: "ownership-1", task_input_epoch: 3,
        progress_token: "progress", provider: "codex", starting_revision: "a" * 40,
        retry_charge: 0, inherited_outputs: [], launch_timeout_sec: 30, now: NOW
      )
      running = coordinator.record_claim(authorization: authorization, attempt_id: successor.attempt_id)
      assert_equal "running", running.state
      assert_equal successor.attempt_id, running.current_attempt_id
    end
  end

  def test_same_stage_success_retains_count_but_stage_transition_and_repair_reset_it
    with_coordinator do |coordinator, store, _dir, _set_now|
      attempt = failed_attempt(store, id: "attempt-1")
      failed = coordinator.report_failure(**failure_args(attempt, terminal_event_id: "terminal-1"))
      succeeded = coordinator.record_success(attempt_id: attempt.attempt_id, stage_transition: false)
      assert_equal "succeeded", succeeded.state
      assert_equal failed.retry_count, succeeded.retry_count

      repaired = coordinator.repair(
        expected_generation: 3, actor: "operator@example.com", reason: "credentials repaired"
      )
      assert_equal "ready", repaired.state
      assert_equal 0, repaired.retry_count

      coordinator.record_stage_transition(attempt_id: attempt.attempt_id, to_stage: "5-open-pr")
      assert_nil coordinator.current
    end
  end

  def test_abandon_and_rearm_require_audited_current_generation_actions
    with_coordinator do |coordinator, store, _dir, _set_now|
      attempt = failed_attempt(store, id: "attempt-1")
      coordinator.report_failure(**failure_args(attempt, terminal_event_id: "terminal-1"))

      assert_raises(Hive::Daemon::InvalidOperatorAction) do
        coordinator.abandon(expected_generation: 3, actor: "", reason: "park")
      end
      assert_raises(Hive::Daemon::StaleRetryGeneration) do
        coordinator.abandon(expected_generation: 4, actor: "ops", reason: "park")
      end

      abandoned = coordinator.abandon(expected_generation: 3, actor: "ops", reason: "park")
      assert_equal "abandoned", abandoned.state
      rearmed = coordinator.rearm(expected_generation: 3, actor: "ops", reason: "repair complete")
      assert_equal "ready", rearmed.state
      assert_equal 0, rearmed.retry_count
    end
  end

  private

  def with_coordinator
    with_tmp_dir do |dir|
      store = Hive::Attempts::Store.new(root: File.join(dir, "attempts"))
      current_time = NOW
      clock = -> { current_time }
      coordinator = build_coordinator(dir: dir, store: store, clock: clock)
      yield coordinator, store, dir, ->(value) { current_time = value }
    end
  end

  def build_coordinator(dir:, store:, clock:)
    Hive::Daemon::RetryCoordinator.new(
      task_folder: dir,
      attempt_store: store,
      schedule: SCHEDULE,
      clock: clock,
      id_generator: -> { SecureRandom.uuid }
    )
  end

  def failed_attempt(store, id:)
    launching = store.create_launching(
      attempt_id: id, request_id: "request-#{id}", predecessor_attempt_id: nil,
      task_id: "42", project: "demo", task_slug: "durable-task", intended_stage: "4-execute",
      task_generation: "ownership-1", ownership_generation: "ownership-1", task_input_epoch: 3,
      progress_token: "progress", provider: "codex", starting_revision: "a" * 40,
      retry_charge: 0, inherited_outputs: [], launch_timeout_sec: 30, now: NOW
    )
    claimed = store.claim(
      launching,
      owner: {
        "pid" => Process.pid, "start_fingerprint" => "pid-start",
        "session_id" => Process.getsid(0), "process_group_id" => Process.getpgrp
      },
      first_heartbeat_timeout_sec: 30,
      now: NOW + 1
    )
    running = store.first_heartbeat(claimed, stale_sec: 30, now: NOW + 2)
    store.terminalize(
      running, outcome: "failed", exit_status: 1,
      final_checkpoint: { "revision" => "a" * 40, "progress_token" => "progress" },
      output_references: [],
      log_reference: { "path" => "logs/#{id}.frames", "size" => 0, "sha256" => "0" * 64 },
      now: NOW + 3
    )
  end

  def failure_args(attempt, terminal_event_id:, code: "agent_died")
    {
      project: "demo", task: { "id" => "42", "slug" => "durable-task" }, workflow: "coding",
      stage: "4-execute", generation: 3, ownership_generation: "ownership-1",
      attempt_id: attempt.attempt_id, terminal_event_id: terminal_event_id,
      failure_class: code, code: code,
      evidence: [ { "kind" => "message", "value" => "worker exited" } ],
      guidance: "Inspect the worker log."
    }
  end
end
