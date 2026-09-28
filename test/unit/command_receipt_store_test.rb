# frozen_string_literal: true

require "test_helper"
require "hive/command_receipt_store"
require "hive/runtime_control_plane/command_schema_installation"

class CommandReceiptStoreTest < Minitest::Test
  include HiveTestHelper

  TEST_PACKAGE = {
    version: "0.0.0-test", location: "https://example.invalid/compat.gem", sha256: "c" * 64
  }.freeze

  def test_identical_retry_replays_original_result_after_restart
    with_store do |project, database, store|
      claim = store.reserve(
        project_root: project, key: "stable", command: "approve", target: "task",
        request: { from: "3-plan" }, principal: "installation:test:uid:1000"
      )
      assert_equal :new, claim.disposition
      claim = store.mark_executing(claim)
      store.succeed(claim, result: { "ok" => true, "task_folder" => "/old/task" }, status: 0)

      restarted = Hive::CommandReceiptStore.new(database: database)
      replay = restarted.reserve(
        project_root: project, key: "stable", command: "approve", target: "task",
        request: { from: "3-plan" }, principal: "installation:test:uid:1000"
      )

      assert_equal :replay, replay.disposition
      assert_equal({ "ok" => true, "task_folder" => "/old/task" }, replay.result)
      assert_equal claim.receipt_id, replay.receipt_id
    end
  end

  def test_changed_request_or_principal_conflicts_without_disclosure
    with_store do |project, _database, store|
      store.reserve(
        project_root: project, key: "stable", command: "approve", target: "task",
        request: { from: "3-plan" }, principal: "owner"
      )

      [
        { request: { from: "4-execute" }, principal: "owner" },
        { request: { from: "3-plan" }, principal: "other" }
      ].each do |changed|
        error = assert_raises(Hive::CommandConflict) do
          store.reserve(
            project_root: project, key: "stable", command: "approve", target: "task",
            **changed
          )
        end
        refute_includes error.message, "owner"
        refute_includes error.message, "approve"
      end
    end
  end

  def test_lookup_is_scoped_to_the_resolved_project_namespace
    with_store do |project, database, store|
      first = store.reserve(
        project_root: project, key: "shared", command: "approve", target: "task",
        request: { from: "3-plan" }, principal: "owner"
      )
      store.succeed(first, result: { "ok" => true, "project" => "first" }, status: 0)

      other = File.join(File.dirname(project), "other-project")
      FileUtils.mkdir_p(other)
      system("git", "init", "--quiet", other, exception: true)
      write_receipt_config(other)

      assert_nil store.lookup_existing(
        project_root: other, key: "shared", command: "approve", target: "task",
        request: { from: "3-plan" }, principal: "owner"
      )
      second = store.reserve(
        project_root: other, key: "shared", command: "approve", target: "task",
        request: { from: "3-plan" }, principal: "owner"
      )
      refute_equal first.namespace_id, second.namespace_id
      refute_equal first.receipt_id, second.receipt_id
      assert_equal 2, database.read { |connection| connection[:command_receipts].count }
    end
  end

  def test_active_and_unresolved_duplicates_return_typed_outcomes
    with_store do |project, _database, store|
      claim = store.reserve(
        project_root: project, key: "stable", command: "act", target: "task",
        request: { observation: "a" * 64 }, principal: "owner"
      )
      assert_raises(Hive::CommandInProgress) do
        store.reserve(
          project_root: project, key: "stable", command: "act", target: "task",
          request: { observation: "a" * 64 }, principal: "owner"
        )
      end

      store.mark_unresolved(claim, reason: "lost_acknowledgement")
      error = assert_raises(Hive::CommandUnresolved) do
        store.reserve(
          project_root: project, key: "stable", command: "act", target: "task",
          request: { observation: "a" * 64 }, principal: "owner"
        )
      end
      assert_equal "command_unresolved_pending", error.reason
    end
  end

  def test_disabled_namespace_refuses_new_admission_but_allows_terminal_replay
    with_store do |project, _database, store|
      claim = store.reserve(
        project_root: project, key: "stable", command: "approve", target: "task",
        request: { from: "3-plan" }, principal: "owner"
      )
      stored = store.succeed(claim, result: { "ok" => true }, status: 0)
      pin_horizon = (Time.now.utc + 3600).iso8601
      pin = store.acquire_pin(
        receipt_id: stored.receipt_id, principal: "owner", intent_id: "existing-intent",
        intent_generation: 1, retry_horizon_expires_at: pin_horizon, project_root: project
      )
      retryable = store.reserve(
        project_root: project, key: "retryable", command: "approve", target: "retryable",
        request: {}, principal: "owner"
      )
      retryable = store.mark_executing(retryable)
      retryable = store.fail_non_application(
        retryable, result: { "format" => "text", "text" => "rejected\n" },
        status: 1, reason: "rejected", whole_effect_non_application: true
      )
      write_receipt_config(project, keyed_intake_enabled: false)

      replay = store.reserve(
        project_root: project, key: "stable", command: "approve", target: "task",
        request: { from: "3-plan" }, principal: "owner"
      )
      assert_equal stored.result, replay.result
      error = assert_raises(Hive::ConfigError) do
        store.reserve(
          project_root: project, key: "new", command: "approve", target: "task",
          request: { from: "3-plan" }, principal: "owner"
        )
      end
      assert_includes error.message, "keyed_intake_enabled"
      assert_equal 0, store.database.read { |connection|
        connection[:command_namespaces][namespace_id: stored.namespace_id]
          .fetch(:keyed_intake_enabled)
      }

      repeated_pin = store.acquire_pin(
        receipt_id: stored.receipt_id, principal: "owner", intent_id: "existing-intent",
        intent_generation: 1, retry_horizon_expires_at: pin_horizon
      )
      assert_equal pin.pin_id, repeated_pin.pin_id
      assert_raises(Hive::CommandIntakeDisabled) do
        store.acquire_pin(
          receipt_id: stored.receipt_id, principal: "owner", intent_id: "new-intent",
          intent_generation: 1, retry_horizon_expires_at: pin_horizon, project_root: project
        )
      end
      assert_raises(Hive::CommandIntakeDisabled) do
        store.allocate_successor(
          namespace_id: retryable.namespace_id, principal: retryable.principal,
          intent_id: "intent", intent_version: 1,
          predecessor_receipt_id: retryable.receipt_id, delivery_cycle_id: "cycle",
          request_fingerprint: retryable.request_fingerprint, project_root: project
        )
      end
    end
  end

  def test_pin_and_successor_races_with_prune_return_typed_outcomes
    with_store do |project, database, store|
      receipt = store.reserve(
        project_root: project, key: "pin-race", command: "approve",
        target: "task", request: {}, principal: "owner"
      )
      receipt = store.succeed(receipt, result: { "ok" => true }, status: 0)
      original = database.method(:transaction)
      raced = false
      database.define_singleton_method(:transaction) do |**options, &block|
        unless raced
          raced = true
          original.call do |db|
            db[:command_receipts].where(receipt_id: receipt.receipt_id).delete
          end
        end
        original.call(**options, &block)
      end
      error = assert_raises(Hive::CommandUnresolved) do
        store.acquire_pin(
          receipt_id: receipt.receipt_id, principal: "owner", intent_id: "intent",
          intent_generation: 1, retry_horizon_expires_at: (Time.now.utc + 3600).iso8601,
          project_root: project
        )
      end
      assert_equal "command_pin_horizon_elapsed", error.reason
    end

    with_store do |project, database, store|
      predecessor = store.reserve(
        project_root: project, key: "successor-race", command: "approve",
        target: "task", request: {}, principal: "owner"
      )
      predecessor = store.mark_executing(predecessor)
      predecessor = store.fail_non_application(
        predecessor, result: { "format" => "text", "text" => "failed\n" },
        status: 1, reason: "failed", whole_effect_non_application: true
      )
      original = database.method(:transaction)
      raced = false
      database.define_singleton_method(:transaction) do |**options, &block|
        unless raced
          raced = true
          original.call do |db|
            db[:command_receipts].where(receipt_id: predecessor.receipt_id).delete
          end
        end
        original.call(**options, &block)
      end
      assert_raises(Hive::CommandUnresolved) do
        store.allocate_successor(
          namespace_id: predecessor.namespace_id, principal: "owner",
          intent_id: "intent", intent_version: 1,
          predecessor_receipt_id: predecessor.receipt_id, delivery_cycle_id: "cycle",
          request_fingerprint: predecessor.request_fingerprint, project_root: project
        )
      end
    end
  end

  def test_live_namespace_nonterminal_limit_applies_on_the_next_admission
    with_store do |project, _database, store|
      write_receipt_config(project, nonterminal_limit: 1)
      store.reserve(
        project_root: project, key: "one", command: "approve", target: "task",
        request: { from: "3-plan" }, principal: "owner"
      )
      error = assert_raises(Hive::CommandCapacityError) do
        store.reserve(
          project_root: project, key: "two", command: "approve", target: "task",
          request: { from: "3-plan" }, principal: "owner"
        )
      end
      assert_equal "command_nonterminal_limit", error.reason
      assert_includes error.message, "settle-without-result"

      write_receipt_config(project, nonterminal_limit: 2)
      claim = store.reserve(
        project_root: project, key: "two", command: "approve", target: "task",
        request: { from: "3-plan" }, principal: "owner"
      )
      assert_equal :new, claim.disposition
    end
  end

  def test_full_concurrency_reclaims_only_a_proven_dead_owner_and_audits_it
    with_store do |project, database, _store|
      write_receipt_config(project, concurrency_limit: 1)
      authority = Hive::CommandMaintenanceAuthority.new(
        principal: "installation-owner", principal_source: "local_cli",
        installation_owner: true
      )
      store = Hive::CommandReceiptStore.new(
        database: database,
        alive: ->(*) { true }, ownership: ->(*) { :reused },
        host: "test-host"
      )
      abandoned = store.reserve(
        project_root: project, key: "abandoned", command: "approve", target: "task",
        request: { from: "3-plan" }, principal: "other-principal"
      )
      abandoned = store.mark_executing(
        abandoned, owner_host: "test-host", owner_pid: 41_001,
        owner_process_start: "old-start"
      )
      incoming = store.reserve(
        project_root: project, key: "incoming", command: "approve", target: "task-2",
        request: { from: "3-plan" }, principal: "installation-owner"
      )

      admitted = with_replaced_singleton_method(
        Hive::CommandMaintenanceAuthority, :local, ->(**) { authority }
      ) do
        store.mark_executing(
          incoming, owner_host: "test-host", owner_pid: 41_002,
          owner_process_start: "new-start"
        )
      end

      assert_equal "executing", admitted.state
      assert_equal "unresolved", store.receipt(abandoned.receipt_id).fetch(:state)
      capacity = database.read { |db| db[:command_capacity].first }
      assert_equal 2, capacity.fetch(:nonterminal_count)
      assert_equal 1, capacity.fetch(:executing_count)
      audit = database.read { |db| db[:command_maintenance_audit].first }
      assert_equal "automatic_admission_orphan_reclassification", audit.fetch(:action)
      assert_equal "other-principal", audit.fetch(:affected_principal)
    end
  end

  def test_concurrent_insert_retries_and_stale_successor_predecessor_is_rejected
    with_store do |project, database, _store|
      Hive::ProjectIdentity.resolve(project_root: project, database: database, create: true)
      transaction = database.method(:transaction)
      attempts = 0
      database.define_singleton_method(:transaction) do |**kwargs, &block|
        attempts += 1
        raise Sequel::UniqueConstraintViolation, "simulated race" if attempts == 1

        transaction.call(**kwargs, &block)
      end
      store = Hive::CommandReceiptStore.new(database: database)
      claim = store.reserve(
        project_root: project, key: "raced", command: "approve", target: "task",
        request: {}, principal: "owner"
      )
      assert_equal :new, claim.disposition
      assert_equal 2, attempts

      first = store.mark_executing(claim)
      first = store.fail_non_application(
        first, result: { "ok" => false }, status: 1, reason: "not_applied",
        whole_effect_non_application: true
      )
      store.allocate_successor(
        namespace_id: first.namespace_id, principal: first.principal,
        intent_id: "intent", intent_version: 1, predecessor_receipt_id: first.receipt_id,
        delivery_cycle_id: "cycle-1", request_fingerprint: "first", project_root: project
      )
      second = store.reserve(
        project_root: project, key: "second", command: "approve", target: "task",
        request: {}, principal: "owner"
      )
      second = store.mark_executing(second)
      second = store.fail_non_application(
        second, result: { "ok" => false }, status: 1, reason: "not_applied",
        whole_effect_non_application: true
      )
      error = assert_raises(Hive::CommandConflict) do
        store.allocate_successor(
          namespace_id: second.namespace_id, principal: second.principal,
          intent_id: "intent", intent_version: 1, predecessor_receipt_id: second.receipt_id,
          delivery_cycle_id: "cycle-2", request_fingerprint: "second", project_root: project
        )
      end
      assert_equal "successor predecessor is stale", error.message
    end
  end

  def test_automatic_reclamation_ignores_unauthorized_and_unavailable_candidates
    with_store do |project, database, store|
      claim = store.reserve(
        project_root: project, key: "executing", command: "approve", target: "task",
        request: {}, principal: "owner"
      )
      claim = store.mark_executing(
        claim, owner_host: "test-host", owner_pid: 41_001, owner_process_start: "start"
      )
      denying = Object.new
      denying.define_singleton_method(:authorize!) { |_| raise Hive::CommandConflict, "denied" }
      guarded = Hive::CommandReceiptStore.new(
        database: database, maintenance_authority: denying, host: "test-host"
      )
      assert_equal 0, guarded.send(:reclaim_dead_executing_owners, claim, scope: "namespace")

      unprivileged = Hive::CommandReceiptStore.new(database: database, host: "test-host")
      assert_equal 0,
                   unprivileged.send(:reclaim_dead_executing_owners, claim, scope: "namespace")
      assert_equal 0, database.read { |db| db[:command_maintenance_audit].count }
    end

    unavailable = Object.new
    unavailable.define_singleton_method(:read) { raise Hive::ConfigError, "unavailable" }
    unavailable.define_singleton_method(:transaction) { |**| raise Hive::ConfigError, "unavailable" }
    authority = Object.new
    store = Hive::CommandReceiptStore.new(
      database: unavailable, maintenance_authority: authority
    )
    claim = Struct.new(:principal, :namespace_id).new("owner", "namespace")
    assert_equal 0, store.send(:reclaim_dead_executing_owners, claim, scope: "namespace")
  end

  def test_late_owner_cannot_finalize_with_a_stale_generation
    with_store do |project, _database, store|
      prepared = store.reserve(
        project_root: project, key: "late-owner", command: "approve", target: "task",
        request: {}, principal: "owner"
      )
      executing = store.mark_executing(prepared)
      effect = store.prepare_effect(
        executing, ordinal: 0, kind: "approve:default", identity: { "target" => "task" }
      )

      store.database.transaction do |connection|
        connection[:command_receipts].where(receipt_id: executing.receipt_id).update(
          generation: executing.generation + 1
        )
      end
      assert_raises(Hive::CommandConflict) do
        store.record_effect_submission(
          receipt_id: executing.receipt_id, effect_id: effect.fetch(:effect_id),
          principal: executing.principal, request_fingerprint: executing.request_fingerprint,
          generation: executing.generation, kind: "task_activity", identity: { "id" => "late" }
        )
      end
      evidence = store.database.read do |connection|
        connection[:command_effects][effect_id: effect.fetch(:effect_id)].fetch(:evidence_json)
      end
      assert_nil evidence

      assert_raises(Hive::CommandConflict) do
        store.succeed(prepared, result: { "ok" => true }, status: 0)
      end
      assert_equal "executing", store.receipt(executing.receipt_id).fetch(:state)
    end
  end

  def test_orderly_pre_effect_cancellation_transitions_to_aborted
    with_store do |project, database, store|
      claim = store.reserve(
        project_root: project, key: "cancelled", command: "approve", target: "task",
        request: {}, principal: "owner", execute: true
      )

      aborted = store.abort_before_effect(claim, reason: "operator_cancelled")

      assert_equal "aborted", aborted.state
      row = store.receipt(claim.receipt_id)
      assert_equal "operator_cancelled", row.fetch(:typed_reason)
      assert_equal 0, database.read { |connection|
        connection[:command_capacity][namespace_id: claim.namespace_id].fetch(:executing_count)
      }
    end
  end

  def test_reclamation_cursor_progresses_past_four_live_owners_across_store_instances
    with_store do |project, database, _store|
      write_receipt_config(project, concurrency_limit: 5)
      authority = Hive::CommandMaintenanceAuthority.new(
        principal: "installation-owner", principal_source: "test", installation_owner: true
      )
      base = Time.utc(2026, 9, 27)
      claims = 5.times.map do |index|
        store = Hive::CommandReceiptStore.new(
          database: database, maintenance_authority: authority, host: "test-host",
          alive: ->(*) { true },
          ownership: ->(_payload, pid) { pid == 41_005 ? :reused : :verified }
        )
        claim = store.reserve(
          project_root: project, key: "owner-#{index}", command: "approve", target: "task-#{index}",
          request: {}, principal: "owner-#{index}"
        )
        executing = store.mark_executing(
          claim, owner_host: "test-host", owner_pid: 41_001 + index,
          owner_process_start: "start-#{index}"
        )
        database.transaction do |connection|
          connection[:command_receipts].where(receipt_id: executing.receipt_id).update(
            updated_at: Hive::RuntimeControlPlane::Codec.dump_time(base + index)
          )
        end
        executing
      end
      incoming = Hive::CommandReceiptStore.new(database: database).reserve(
        project_root: project, key: "incoming", command: "approve", target: "incoming",
        request: {}, principal: "installation-owner"
      )

      first = Hive::CommandReceiptStore.new(
        database: database, maintenance_authority: authority, host: "test-host",
        alive: ->(*) { true },
        ownership: ->(_payload, pid) { pid == 41_005 ? :reused : :verified }
      )
      assert_raises(Hive::CommandCapacityError) do
        first.mark_executing(incoming, owner_host: "test-host", owner_pid: 42_000,
                             owner_process_start: "incoming")
      end
      second = Hive::CommandReceiptStore.new(
        database: database, maintenance_authority: authority, host: "test-host",
        alive: ->(*) { true },
        ownership: ->(_payload, pid) { pid == 41_005 ? :reused : :verified }
      )
      admitted = second.mark_executing(
        incoming, owner_host: "test-host", owner_pid: 42_000,
        owner_process_start: "incoming"
      )

      assert_equal "executing", admitted.state
      assert_equal "unresolved", second.receipt(claims.last.receipt_id).fetch(:state)
    end
  end

  def test_missing_pruned_receipt_pin_reports_elapsed_horizon
    with_store do |project, _database, store|
      error = assert_raises(Hive::CommandUnresolved) do
        store.acquire_pin(
          receipt_id: "pruned", principal: "owner", intent_id: "intent",
          intent_generation: 1, retry_horizon_expires_at: (Time.now.utc + 3600).iso8601,
          project_root: project
        )
      end
      assert_equal "command_pin_horizon_elapsed", error.reason
      assert_includes error.message, "new acquisition identity"
    end
  end

  def test_pin_fails_closed_when_the_receipt_disappears_during_admission
    with_store do |project, database, store|
      claim = store.reserve(
        project_root: project, key: "pin-race", command: "approve", target: "task",
        request: {}, principal: "owner"
      )
      transaction = database.method(:transaction)
      database.define_singleton_method(:transaction) do |**kwargs, &block|
        transaction.call(**kwargs) do |connection|
          connection[:command_receipts].where(receipt_id: claim.receipt_id).delete
          block.call(connection)
        end
      end

      error = assert_raises(Hive::CommandUnresolved) do
        store.acquire_pin(
          receipt_id: claim.receipt_id, principal: "owner", intent_id: "intent",
          intent_generation: 1,
          retry_horizon_expires_at: (Time.now.utc + 3600).iso8601,
          project_root: project
        )
      end
      assert_equal "command_pin_horizon_elapsed", error.reason
    end
  end

  def test_bounded_lookup_detects_conflicts_ambiguity_and_absence
    with_store do |project, _database, store|
      first = store.reserve(
        project_root: project, key: "shared", command: "approve", target: "task",
        request: {}, principal: "owner"
      )
      store.succeed(first, result: { "ok" => true }, status: 0)
      stale = File.join(File.dirname(project), "stale-registration")
      FileUtils.mkdir_p(stale)
      system("git", "init", "--quiet", stale, exception: true)
      replay = store.lookup_existing_in_projects(
        project_roots: [ stale, project ], key: "shared", command: "approve",
        target: "task", request: {}, principal: "owner"
      )
      assert_equal :replay, replay.disposition
      assert_raises(Hive::CommandConflict) do
        store.lookup_existing_in_projects(
          project_roots: [ project ], key: "shared", command: "approve",
          target: "changed", request: {}, principal: "owner"
        )
      end

      missing = File.join(File.dirname(project), "missing")
      FileUtils.mkdir_p(missing)
      system("git", "init", "--quiet", missing, exception: true)
      write_receipt_config(missing)
      assert_nil store.lookup_existing_in_projects(
        project_roots: [ missing ], key: "absent", command: "approve",
        target: "task", request: {}, principal: "owner"
      )

      second = store.reserve(
        project_root: missing, key: "shared", command: "approve", target: "task",
        request: {}, principal: "owner"
      )
      store.succeed(second, result: { "ok" => true }, status: 0)
      assert_raises(Hive::CommandConflict) do
        store.lookup_existing_in_projects(
          project_roots: [ project, missing ], key: "shared", command: "approve",
          target: "task", request: {}, principal: "owner"
        )
      end
    end
  end

  def test_cross_project_lookup_propagates_identity_custody_failures
    with_store do |project, _database, store|
      Hive::ProjectIdentity.resolve(project_root: project, database: store.database, create: true)
      File.chmod(0o644, Hive::ProjectIdentity.marker_path(project))

      assert_raises(Hive::ConfigError) do
        store.lookup_existing_in_projects(
          project_roots: [ project ], key: "shared", command: "approve",
          target: "task", request: {}, principal: "owner"
        )
      end
    end
  end

  def test_reservation_retries_capacity_once_and_fails_repeated_insert_races
    with_store do |project, _database, store|
      assert_raises(Hive::ConfigError) do
        store.reserve(
          project_root: project, key: "maintenance", command: "receipt", mode: "prune",
          target: "demo", request: {}, principal: "owner", maintenance: true
        )
      end
    end

    with_store do |project, database, store|
      Hive::ProjectIdentity.resolve(project_root: project, database: database, create: true)
      transaction = database.method(:transaction)
      attempts = 0
      database.define_singleton_method(:transaction) do |**kwargs, &block|
        attempts += 1
        if attempts == 1
          raise Hive::CommandCapacityError.new(
            "full", reason: :command_concurrency_limit, scope: :namespace
          )
        end
        transaction.call(**kwargs, &block)
      end
      store.define_singleton_method(:reclaim_dead_executing_owners) { |*_, **| 1 }
      claim = store.reserve(
        project_root: project, key: "capacity-retry", command: "approve", target: "task",
        request: {}, principal: "owner", execute: true, owner_process_start: "start"
      )
      assert_equal :new, claim.disposition
      assert_equal 2, attempts
    end

    with_store do |project, database, store|
      Hive::ProjectIdentity.resolve(project_root: project, database: database, create: true)
      database.define_singleton_method(:transaction) do |**_kwargs, &_block|
        raise Sequel::UniqueConstraintViolation, "race"
      end
      assert_raises(Hive::CommandConflict) do
        store.reserve(
          project_root: project, key: "repeated-race", command: "approve", target: "task",
          request: {}, principal: "owner"
        )
      end
    end
  end

  def test_store_rejects_unproven_failures_invalid_observations_and_oversized_results
    with_store do |project, _database, store|
      claim = store.reserve(
        project_root: project, key: "guards", command: "approve", target: "task",
        request: {}, principal: "owner"
      )
      assert_raises(Hive::CommandUnresolved) do
        store.fail_non_application(
          claim, result: {}, status: 1, reason: "unknown",
          whole_effect_non_application: false
        )
      end
      executing = store.mark_executing(claim)
      effect = store.prepare_effect(executing, ordinal: 0, kind: "approve:default")
      assert_raises(Hive::CommandUnresolved) do
        store.complete_effect(
          executing, effect_id: effect.fetch(:effect_id),
          result: { "value" => "x" * (Hive::CommandReceiptStore::MAX_RESULT_BYTES + 1) },
          status: 0
        )
      end
      assert_raises(Hive::UsageError) do
        store.record_effect_observation(
          receipt_id: executing.receipt_id, effect_id: effect.fetch(:effect_id),
          principal: executing.principal,
          request_fingerprint: executing.request_fingerprint,
          generation: executing.generation,
          source: "", correlation_id: "", evidence: {}
        )
      end
      refute store.close_pin(
        receipt_id: executing.receipt_id, principal: executing.principal,
        intent_id: "missing", intent_generation: 0
      )
      pin = store.acquire_pin(
        receipt_id: executing.receipt_id, principal: executing.principal,
        intent_id: "active", intent_generation: 1,
        retry_horizon_expires_at: (Time.now.utc + 3600).iso8601,
        owner_process_start: "start", project_root: project
      )
      assert store.close_pin(
        receipt_id: executing.receipt_id, principal: executing.principal,
        intent_id: "active", intent_generation: 1
      )
      refute store.close_pin(
        receipt_id: executing.receipt_id, principal: executing.principal,
        intent_id: "missing", intent_generation: "invalid"
      )
    end
  end

  def test_corrupt_recovery_evidence_and_finalize_races_fail_closed
    database = Object.new
    store = Hive::CommandReceiptStore.new(database: database)
    row = {
      receipt_id: "receipt", namespace_id: "namespace", generation: 1,
      state: "executing", principal: "owner", request_fingerprint: "fingerprint",
      owner_host: Socket.gethostname, owner_pid: Process.pid,
      owner_process_start: Hive::Lock.process_start_time(Process.pid)
    }
    effect = { state: "unknown", evidence_json: "{" }
    database.define_singleton_method(:read) do |&block|
      table = Object.new
      table.define_singleton_method(:[]) { |_query| effect }
      connection = Object.new
      connection.define_singleton_method(:[]) { |_name| table }
      block.call(connection)
    end
    unresolved = row.merge(state: "unresolved")
    refute store.send(:reconcilable_effect?, unresolved)
    assert_nil store.send(:authoritative_result, effect.merge(state: "applied"))

    store.define_singleton_method(:authoritative_result_for_receipt) do |_row|
      [ { "format" => "text", "text" => "ok\n" }, 0 ]
    end
    store.define_singleton_method(:finalize!) do |*_, **|
      raise Hive::CommandConflict, "race"
    end
    store.define_singleton_method(:receipt) { |_receipt_id| unresolved }
    assert_raises(Hive::CommandUnresolved) do
      store.send(
        :classify_existing!, row, principal: "owner",
        request_fingerprint: "fingerprint", project_root: "/project"
      )
    end

    store.define_singleton_method(:process_start) { |_pid| raise IOError, "unavailable" }
    refute store.send(:current_process_owner?, row)
  end

  # An executing receipt owned by another process may be replayed from its
  # authoritative effect only when that owner is proven dead; a live or
  # unprovable owner keeps the command in progress.
  def test_foreign_executing_owner_replays_only_with_proof_of_death
    store = Hive::CommandReceiptStore.new(database: Object.new)
    row = {
      receipt_id: "receipt", namespace_id: "namespace", generation: 1,
      state: "executing", principal: "owner", request_fingerprint: "fingerprint",
      owner_host: "other-host", owner_pid: 1, owner_process_start: "start"
    }
    store.define_singleton_method(:authoritative_result_for_receipt) do |_row|
      [ { "format" => "text", "text" => "ok\n" }, 0 ]
    end
    store.define_singleton_method(:public_receipt) { |receipt| { "receipt_id" => receipt.fetch(:receipt_id) } }
    store.define_singleton_method(:claim_from) { |*_args, **_kwargs| :claim }
    store.define_singleton_method(:finalize!) { |claim, **kwargs| [ claim, kwargs.fetch(:state) ] }
    classify = lambda do
      store.send(:classify_existing!, row, principal: "owner",
                 request_fingerprint: "fingerprint", project_root: "/project")
    end

    with_replaced_singleton_method(Hive::CommandOwnerProof, :dead, ->(*_args, **_kwargs) { nil }) do
      assert_raises(Hive::CommandInProgress) { classify.call }
    end
    with_replaced_singleton_method(Hive::CommandOwnerProof, :dead, ->(*_args, **_kwargs) { :proof }) do
      assert_equal [ :claim, "succeeded" ], classify.call
    end
  end

  def test_reclamation_cursor_wraps_and_fresh_admission_requires_the_canonical_root
    with_store do |project, database, store|
      identity = Hive::ProjectIdentity.resolve(
        project_root: project, database: database, create: true
      )
      live = store.reserve(
        project_root: project, key: "live-owner", command: "approve", target: "task",
        request: {}, principal: "owner"
      )
      live = store.mark_executing(live)
      database.transaction do |connection|
        row = connection[:command_receipts][receipt_id: live.receipt_id]
        connection[:command_namespaces].where(namespace_id: live.namespace_id).update(
          reclamation_cursor_updated_at: row.fetch(:updated_at),
          reclamation_cursor_receipt_id: row.fetch(:receipt_id)
        )
      end

      authority = Hive::CommandMaintenanceAuthority.new(
        principal: "owner", principal_source: "test", installation_owner: true
      )
      reclaiming = Hive::CommandReceiptStore.new(
        database: database, maintenance_authority: authority
      )
      assert_equal 0, reclaiming.send(
        :reclaim_dead_executing_owners, live, scope: "namespace"
      )
      assert_raises(Hive::ConfigError) do
        store.send(:admission_policy!, nil, namespace_id: identity.namespace_id)
      end
      policy = store.send(:admission_policy!, project, namespace_id: identity.namespace_id)
      assert policy.keyed_intake_enabled
      assert_raises(Hive::CommandConflict) do
        store.send(:admission_policy!, project, namespace_id: "changed-namespace")
      end
    end
  end

  def test_negative_logical_byte_adjustment_is_clamped
    with_store do |project, database, store|
      identity = Hive::ProjectIdentity.resolve(
        project_root: project, database: database, create: true
      )
      database.transaction do |connection|
        store.send(:add_logical_bytes!, connection, identity.namespace_id, -1)
      end
    end
  end

  def test_store_requires_the_installed_receipt_extension
    Dir.mktmpdir do |dir|
      database = Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(dir)
      ).migrate!
      store = Hive::CommandReceiptStore.new(database: database)
      assert_raises(Hive::ConfigError) do
        store.lookup_existing(
          project_root: dir, key: "key", command: "approve", target: "task",
          request: {}, principal: "owner"
        )
      end
    ensure
      database&.disconnect
    end
  end

  def test_store_translates_corrupt_contention_and_resume_evidence
    broken = Hive::CommandReceiptStore.new(database: Object.new)
    broken.define_singleton_method(:require_extension!) { raise Hive::Error, "broken" }
    error = assert_raises(Hive::ConfigError) { broken.verify_extension! }
    assert_includes error.message, "cannot verify command receipt storage"

    with_store do |project, database, store|
      claim = store.reserve(
        project_root: project, key: "contention", command: "approve", target: "task",
        request: {}, principal: "owner"
      )
      executing = store.mark_executing(claim)
      effect = store.prepare_effect(
        executing, ordinal: 0, kind: "approve:default", identity: {}
      )
      database.transaction do |connection|
        connection[:command_effects].where(effect_id: effect.fetch(:effect_id)).update(
          evidence_json: Hive::RuntimeControlPlane::Codec.dump_json("submissions" => [])
        )
      end
      aborted = store.abort_pre_submission(
        executing, effect_id: effect.fetch(:effect_id), reason: "busy"
      )
      assert_equal "aborted", aborted.state

      database.transaction do |connection|
        connection[:command_effects].where(effect_id: effect.fetch(:effect_id)).update(
          evidence_json: Hive::RuntimeControlPlane::Codec.dump_json(
            "whole_effect_non_application" => false, "submissions" => []
          )
        )
      end
      assert_raises(Hive::CommandConflict) { store.resume_maintenance(aborted) }
      refute store.send(
        :safely_not_applied_effect?, state: "not_applied", evidence_json: "{"
      )

      corrupt = store.reserve(
        project_root: project, key: "corrupt-contention", command: "approve", target: "task",
        request: {}, principal: "owner"
      )
      corrupt = store.mark_executing(corrupt)
      corrupt_effect = store.prepare_effect(
        corrupt, ordinal: 0, kind: "approve:default", identity: {}
      )
      database.transaction do |connection|
        connection[:command_effects].where(
          effect_id: corrupt_effect.fetch(:effect_id)
        ).update(evidence_json: "{")
      end
      assert_raises(Hive::CommandConflict) do
        store.abort_pre_submission(
          corrupt, effect_id: corrupt_effect.fetch(:effect_id), reason: "busy"
        )
      end
    end
  end

  private

  def with_store
    Dir.mktmpdir do |dir|
      project = File.join(dir, "project")
      FileUtils.mkdir_p(project)
      system("git", "init", "--quiet", project, exception: true)
      write_receipt_config(project)
      state = File.join(dir, "state")
      FileUtils.mkdir_p(state, mode: 0o700)
      database = Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(state)
      ).migrate!
      Hive::RuntimeControlPlane::CommandSchemaInstallation.install!(
        database: database, package_coordinates: TEST_PACKAGE
      )
      yield project, database, Hive::CommandReceiptStore.new(database: database)
    ensure
      database&.disconnect
    end
  end

  def write_receipt_config(project, **overrides)
    config = {
      "keyed_intake_enabled" => true,
      "nonterminal_limit" => 1_000,
      "concurrency_limit" => 32,
      "byte_admission_limit" => 64 * 1024 * 1024
    }.merge(overrides.transform_keys(&:to_s))
    state = File.join(project, ".hive-state")
    FileUtils.mkdir_p(state)
    File.write(File.join(state, "config.yml"), { "command_receipts" => config }.to_yaml)
  end
end
