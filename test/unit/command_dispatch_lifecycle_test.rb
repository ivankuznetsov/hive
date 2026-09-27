# frozen_string_literal: true

require "test_helper"
require "hive/attempts/command_dispatch"
require "hive/command_dispatch_lifecycle"
require "hive/command_operation"
require "hive/runtime_control_plane/command_schema_installation"

class CommandDispatchLifecycleTest < Minitest::Test
  include HiveTestHelper

  TEST_PACKAGE = {
    version: "0.0.0-test", location: "https://example.invalid/compat.gem", sha256: "a" * 64
  }.freeze

  class AttemptsCaller
    include Hive::Attempts::CommandDispatch

    def initialize(lifecycle)
      @command_dispatch_lifecycle = lifecycle
    end

    def allocate(**attributes)
      allocate_command_successor!(**attributes)
    end

    def dispatch = dispatch_durable

    def fail!(result)
      handle_durable_failure!(result)
    end
  end

  def test_restart_reacquires_one_pin_and_same_cycle_successor_is_stable
    with_lifecycle do |project, database, repository, store, lifecycle, request_id, claim|
      first_pin = lifecycle.protect_request!(request_id)
      restarted = Hive::CommandDispatchLifecycle.new(repository: repository, store: store)
      second_pin = restarted.protect_request!(request_id)

      assert_equal first_pin.pin_id, second_pin.pin_id
      assert_equal 1, database.read { |db| db[:command_receipt_pins].count }

      allocations = 4.times.map do
        Thread.new do
          Hive::CommandDispatchLifecycle.new(repository: repository, store: store)
            .allocate_successor!(
              predecessor_request_id: request_id, intent_id: "intent-1",
              intent_version: 7, delivery_cycle_id: "cycle-1"
            )
        end
      end.map(&:value)
      assert_equal 1, allocations.map { |row| row.fetch("allocation_id") }.uniq.length

      successor = store.reserve(
        project_root: project,
        key: allocations.first.fetch("successor_key_identity"),
        command: "approve", target: "task", request: {}, principal: claim.principal
      )
      successor = store.mark_executing(successor)
      store.fail_non_application(
        successor, result: { "format" => "text", "text" => "not applied\n" },
        status: 1, reason: "not_applied", whole_effect_non_application: true
      )

      repeated = restarted.allocate_successor!(
        predecessor_request_id: request_id, intent_id: "intent-1",
        intent_version: 7, delivery_cycle_id: "cycle-1"
      )
      assert_equal allocations.first, repeated
    end
  end

  def test_successor_reservation_rejects_a_changed_frozen_request
    with_lifecycle do |project, _database, _repository, store, lifecycle, request_id, claim|
      allocation = lifecycle.allocate_successor!(
        predecessor_request_id: request_id, intent_id: "intent-2",
        intent_version: 1, delivery_cycle_id: "cycle-1"
      )

      assert_raises(Hive::CommandConflict) do
        store.reserve(
          project_root: project, key: allocation.fetch("successor_key_identity"),
          command: "approve", target: "different-task", request: {}, principal: claim.principal
        )
      end
      assert_nil database_receipt_for_key(
        store.database, claim.namespace_id, allocation.fetch("successor_key_identity")
      )
    end
  end

  def test_attempts_same_cycle_concurrency_and_failed_successor_redelivery_use_shared_lifecycle
    calls = []
    mutex = Mutex.new
    lifecycle = Object.new
    lifecycle.define_singleton_method(:allocate_successor!) do |**attributes|
      mutex.synchronize { calls << attributes }
      { "allocation_id" => "stable-cycle" }
    end
    caller = AttemptsCaller.new(lifecycle)
    attributes = {
      predecessor_request_id: "request-1", intent_id: "intent-1",
      intent_version: 2, delivery_cycle_id: "cycle-1"
    }
    concurrent = 4.times.map { Thread.new { caller.allocate(**attributes) } }.map(&:value)
    # The shared allocator remains authoritative when the same delivery is
    # observed again after its allocated successor reports failure.
    repeated = caller.allocate(
      **attributes
    )

    assert_equal 1, (concurrent + [ repeated ]).uniq.length
    assert_equal 5, calls.length
    assert calls.all? { |call| call.fetch(:predecessor_request_id) == "request-1" }
  end

  def test_context_validation_fails_closed_for_missing_or_changed_durable_state
    repository = Object.new
    repository.define_singleton_method(:command_context) { |_request_id| nil }
    lifecycle = Hive::CommandDispatchLifecycle.new(repository: repository, store: Object.new)
    assert_raises(Hive::CommandUnresolved) { lifecycle.protect_request!("missing") }

    context = {
      receipt_id: "receipt", effect_id: "effect", principal: "owner",
      principal_source: "test", ordinal: 0, request_fingerprint: "fingerprint",
      transport_request_id: "command-dispatch:v1:#{'a' * 64}",
      retry_horizon_expires_at: "2030-01-01T00:00:00Z"
    }
    store = Object.new
    store.define_singleton_method(:receipt) do |_receipt_id|
      { receipt_id: "receipt", principal: "other", request_fingerprint: "fingerprint" }
    end
    lifecycle = Hive::CommandDispatchLifecycle.new(repository: repository, store: store)
    assert_raises(Hive::CommandConflict) { lifecycle.protect_context!(context) }
    assert_raises(Hive::CommandUnresolved) { lifecycle.send(:normalize_context, {}) }

    store.define_singleton_method(:receipt) do |_receipt_id|
      { receipt_id: "receipt", principal: "owner", request_fingerprint: "fingerprint" }
    end
    database = Object.new
    database.define_singleton_method(:read) do |&block|
      table = Object.new
      table.define_singleton_method(:[]) { |_query| { effect_id: "effect" } }
      connection = Object.new
      connection.define_singleton_method(:[]) { |_name| table }
      block.call(connection)
    end
    store.define_singleton_method(:database) { database }
    lifecycle.define_singleton_method(:normalize_context) do |_context|
      context.transform_keys(&:to_s).merge("source_identity" => context.fetch(:transport_request_id),
                                           "retry_horizon_expires_at" => nil)
    end
    assert_raises(Hive::UsageError) do
      lifecycle.protect_context!(context)
    end
  end

  def test_attempt_dispatch_binds_context_and_reports_buffered_failure
    lifecycle = Object.new
    protected = []
    lifecycle.define_singleton_method(:protect_context!) { |context| protected << context }
    caller = AttemptsCaller.new(lifecycle)
    caller.instance_variable_set(:@target, "task")
    caller.instance_variable_set(:@json, true)
    caller.define_singleton_method(:resolve_task) { :task }
    caller.define_singleton_method(:durable_intended_stage) { |_task| "4-execute" }
    caller.define_singleton_method(:durable_worker_argv) { |_task| %w[hive run task] }
    api = Object.new
    result = Struct.new(
      :exit_status, :output_status, :attempt_id, :status, :outcome,
      keyword_init: true
    ) do
      def stdout_emitted? = true
    end.new(exit_status: 0, output_status: :available, attempt_id: "attempt-1",
            status: :finished, outcome: "failed")
    dispatched = []
    api.define_singleton_method(:dispatch) { |**attributes| dispatched << attributes; result }
    caller.instance_variable_set(:@attempts_api, api)
    context = Hive::CommandOperation::Context.new(
      receipt_id: "receipt", effect_id: "effect", principal: "owner",
      principal_source: "test", ordinal: 2, request_fingerprint: "fingerprint",
      transport_request_id: "command-dispatch:v1:#{'b' * 64}",
      retry_horizon_expires_at: "2030-01-01T00:00:00Z"
    )
    Thread.current[:hive_command_operation_context] = context
    assert_equal result, caller.dispatch
    assert_equal [ context ], protected
    assert_equal context.transport_request_id, dispatched.first.fetch(:request_id)
  ensure
    Thread.current[:hive_command_operation_context] = nil

    caller.instance_variable_set(:@command_dispatch_context, context)
    result.exit_status = 9
    error = assert_raises(Hive::AttemptExecutionError) { caller.fail!(result) }
    assert_match(/failed after buffered JSON output/, error.message)
  end

  def test_attempt_dispatch_requires_a_retry_horizon_and_uses_default_state_home
    caller = AttemptsCaller.new(nil)
    caller.instance_variable_set(:@target, "task")
    caller.define_singleton_method(:resolve_task) { :task }
    caller.define_singleton_method(:durable_intended_stage) { |_task| "4-execute" }
    caller.define_singleton_method(:durable_worker_argv) { |_task| %w[hive run task] }
    context = Hive::CommandOperation::Context.new(
      receipt_id: "receipt", effect_id: "effect", principal: "owner",
      principal_source: "test", ordinal: 0, request_fingerprint: "fingerprint",
      transport_request_id: "command-dispatch:v1:#{'c' * 64}", retry_horizon_expires_at: nil
    )
    Thread.current[:hive_command_operation_context] = context
    assert_raises(Hive::UsageError) { caller.dispatch }
  ensure
    Thread.current[:hive_command_operation_context] = nil
    caller.instance_variable_set(:@command_dispatch_lifecycle, nil)
    lifecycle = caller.send(:command_dispatch_lifecycle)
    assert_equal Hive::Paths.state_home, lifecycle.instance_variable_get(:@state_home)
  end

  private

  def with_lifecycle
    Dir.mktmpdir do |dir|
      project = File.join(dir, "project")
      FileUtils.mkdir_p(File.join(project, ".hive-state"))
      File.write(
        File.join(project, ".hive-state", "config.yml"),
        { "command_receipts" => { "keyed_intake_enabled" => true } }.to_yaml
      )
      system("git", "init", "--quiet", project, exception: true)
      state = File.join(dir, "state")
      FileUtils.mkdir_p(state, mode: 0o700)
      database = Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(state)
      ).migrate!
      Hive::RuntimeControlPlane::CommandSchemaInstallation.install!(
        database: database, package_coordinates: TEST_PACKAGE
      )
      database.transaction do |db|
        installation = db[:installations].first.fetch(:installation_id)
        now = Time.now.utc.iso8601(6)
        db[:projects].insert(
          project_id: "project-demo", installation_id: installation,
          registration_id: "registration-demo", name: "demo",
          observed_path: project, state_root_path: File.join(project, ".hive-state"),
          active: 1, registered_at: now, last_observed_at: now
        )
      end
      store = Hive::CommandReceiptStore.new(database: database)
      claim = store.reserve(
        project_root: project, key: "predecessor", command: "approve",
        target: "task", request: {}, principal: "owner"
      )
      claim = store.mark_executing(claim)
      effect = store.prepare_effect(
        claim, ordinal: 0, kind: "approve:default", identity: { "target" => "task" }
      )
      store.update_effect(
        claim, effect_id: effect.fetch(:effect_id), from: "prepared", to: "not_applied",
        evidence: { "whole_effect_non_application" => true }
      )
      claim = store.fail_non_application(
        claim, result: { "format" => "text", "text" => "not applied\n" },
        status: 1, reason: "not_applied", whole_effect_non_application: true
      )
      repository = Hive::RuntimeControlPlane::DispatchRepository.new(database: database)
      request_id = "command-dispatch:v1:#{'b' * 64}"
      context = Hive::CommandOperation::Context.new(
        receipt_id: claim.receipt_id, effect_id: effect.fetch(:effect_id), principal: claim.principal,
        principal_source: "test", ordinal: 0,
        request_fingerprint: claim.request_fingerprint,
        transport_request_id: request_id,
        retry_horizon_expires_at: (Time.now.utc + 3600).iso8601(6)
      )
      repository.write_request!(
        project: "demo", slug: "demo-task", argv: %w[hive run demo-task],
        request_id: request_id, command_context: context
      )
      lifecycle = Hive::CommandDispatchLifecycle.new(repository: repository, store: store)

      yield project, database, repository, store, lifecycle, request_id, claim
    ensure
      database&.disconnect
    end
  end

  def database_receipt_for_key(database, namespace_id, key)
    database.read do |db|
      db[:command_receipts][
        namespace_id: namespace_id, key_digest: Digest::SHA256.hexdigest(key)
      ]
    end
  end
end
