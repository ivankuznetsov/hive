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
