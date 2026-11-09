require "test_helper"
require "hive/recovery/manual_retry"

class ManualRetryTest < Minitest::Test
  include HiveTestHelper

  Receipt = Hive::Daemon::RecoveryCoordinator::Receipt
  Request = Data.define(:request_id, :project, :slug)
  Record = Data.define(:attempt_id, :state) do
    def final? = false
  end

  def setup
    @row = { "project" => "demo", "slug" => "task" }
    @receipt = Receipt.from_h({ "status" => "queued", "phase" => "cleared", "request_id" => "request-1" })
    @request = Request.new(request_id: "request-1", project: "demo", slug: "task")
    @coordinator = Object.new
    @coordinator.define_singleton_method(:prepare_manual) { |**| @prepared }
    @coordinator.define_singleton_method(:receipt_for_request) { |_| @prepared }
    @coordinator.define_singleton_method(:defer_dispatch_failure) { |*, **| }
    @coordinator.instance_variable_set(:@prepared, @receipt)
    @repository = Object.new
    request = @request
    @repository.define_singleton_method(:fetch) { |_| request }
    @attempts = Object.new # No dispatch/attach methods: rejection must never call them.
  end

  def test_rejected_observations_never_dispatch_or_attach
    %w[stale_observation retry_safety_blocked dependency_wait existing_live recovery_binding_conflict].each do |reason|
      prepared = Receipt.from_h({ "status" => "blocked", "owner" => "operator", "reason" => reason })
      @coordinator.instance_variable_set(:@prepared, prepared)
      receipt = runner.call(row: @row, observation_token: "a" * 64)
      assert_equal "blocked", receipt.status
      assert_equal reason, receipt.reason
      expected = reason == "existing_live" ? "hive task task --project demo --json" : "hive status --operational --json"
      assert_includes receipt.remediation, expected
    end
  end

  def test_dispatched_request_requires_a_matching_observable_attempt_before_attachment
    @coordinator.instance_variable_set(:@prepared, @receipt.with(status: "running", phase: "dispatched", attempt_id: "attempt-1"))
    @attempts.define_singleton_method(:fetch) { |_| nil }
    missing = runner.call(row: @row, observation_token: "a" * 64)
    assert_equal [ "unavailable", "attempt_observation_unavailable" ], [ missing.status, missing.reason ]
    @attempts.define_singleton_method(:fetch) { |_| Record.new(attempt_id: "attempt-1", state: "running") }
    @coordinator.define_singleton_method(:manual_attempt_matches?) { |*| false }
    conflicting = runner.call(row: @row, observation_token: "a" * 64)
    assert_equal [ "unavailable", "attempt_identity_conflict" ], [ conflicting.status, conflicting.reason ]
  end

  def test_launch_error_remains_typed_when_best_effort_deferral_also_fails
    @attempts.define_singleton_method(:dispatch_request) { |*, **| raise Hive::Error, "original launch failure" }
    @coordinator.define_singleton_method(:defer_dispatch_failure) { |*, **| raise IOError, "deferral also failed" }
    receipt = runner.call(row: @row, observation_token: "a" * 64)
    assert_equal [ "unavailable", "hive", "launch_unavailable" ], [ receipt.status, receipt.owner, receipt.reason ]
    assert_includes receipt.remediation, "original launch failure"
    assert_includes receipt.remediation, "hive status --operational --json"
  end

  def test_admission_requires_a_matching_attempt_before_binding_attachment_or_terminalization
    %i[accepted existing_live terminal_replay].each do |status|
      record = Record.new(attempt_id: "foreign-attempt", state: "running")
      result = Hive::Attempts::DispatchResult.new(status: status, attempt: record,
        receipt: nil, attach_descriptor: nil, reason: nil)
      @attempts.define_singleton_method(:dispatch_request) { |*, **| result }
      checked = []
      @coordinator.define_singleton_method(:manual_attempt_matches?) do |request, attempt|
        checked << [ request, attempt ]
        false
      end

      receipt = runner.call(row: @row, observation_token: "a" * 64)

      assert_equal [ [ @request, record ] ], checked
      assert_equal [ "unavailable", "attempt_identity_conflict" ], [ receipt.status, receipt.reason ]
      assert_nil receipt.attempt_id
      assert_includes receipt.remediation, "hive status --operational --json"
    end
  end

  def test_missing_request_after_attachment_returns_unavailable_evidence
    @coordinator.instance_variable_set(:@prepared, @receipt.with(status: "running", phase: "dispatched", attempt_id: "attempt-1"))
    @coordinator.define_singleton_method(:manual_attempt_matches?) { |*| true }
    @attempts.define_singleton_method(:fetch) { |_| Record.new(attempt_id: "attempt-1", state: "running") }
    repository = @repository
    @attempts.define_singleton_method(:attach) do |*, **|
      repository.define_singleton_method(:fetch) { |_| nil }
    end
    receipt = runner.call(row: @row, observation_token: "a" * 64)
    assert_equal [ "unavailable", "hive", "recovery_observation_unavailable" ], [ receipt.status, receipt.owner, receipt.reason ]
    assert_equal "request-1", receipt.request_id
  end

  def test_request_disappearing_before_dispatch_is_unavailable_without_launch
    @repository.define_singleton_method(:fetch) { |_| nil }
    receipt = runner.call(row: @row, observation_token: "a" * 64)
    assert_equal [ "unavailable", "recovery_observation_unavailable" ], [ receipt.status, receipt.reason ]
  end

  def test_manual_dispatch_preserves_noninteractive_guards_and_restores_transport_context
    seen = []
    @attempts.define_singleton_method(:dispatch_request) do |request, **options|
      seen << [ request.request_id, options, Thread.current[:hive_command_operation_context] ]
      raise Hive::Error, "stop before launch"
    end
    previous = Thread.current[:hive_command_operation_context]
    context = Object.new
    Thread.current[:hive_command_operation_context] = context
    runner.call(row: @row, observation_token: "a" * 64)
    assert_equal "request-1", seen.first[0]
    assert_equal false, seen.first[1].fetch(:interactive)
    assert_nil seen.first[2]
    assert_same context, Thread.current[:hive_command_operation_context]
  ensure
    Thread.current[:hive_command_operation_context] = previous
  end

  private

  def runner
    Hive::Recovery::ManualRetry.new(coordinator: @coordinator, repository: @repository, attempts: @attempts)
  end
end
