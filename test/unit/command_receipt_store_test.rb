# frozen_string_literal: true

require "test_helper"
require "hive/command_receipt_store"
require "hive/runtime_control_plane/command_schema_installation"

class CommandReceiptStoreTest < Minitest::Test
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
        database: database, maintenance_authority: authority,
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

      admitted = store.mark_executing(
        incoming, owner_host: "test-host", owner_pid: 41_002,
        owner_process_start: "new-start"
      )

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
        delivery_cycle_id: "cycle-1", request_fingerprint: "first"
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
          delivery_cycle_id: "cycle-2", request_fingerprint: "second"
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
    end

    unavailable = Object.new
    unavailable.define_singleton_method(:read) { raise Hive::ConfigError, "unavailable" }
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

      assert_raises(Hive::CommandConflict) do
        store.succeed(prepared, result: { "ok" => true }, status: 0)
      end
      assert_equal "executing", store.receipt(executing.receipt_id).fetch(:state)
      store.succeed(executing, result: { "ok" => true }, status: 0)
      assert_equal "succeeded", store.receipt(executing.receipt_id).fetch(:state)
    end
  end

  def test_bounded_lookup_detects_conflicts_ambiguity_and_absence
    with_store do |project, _database, store|
      first = store.reserve(
        project_root: project, key: "shared", command: "approve", target: "task",
        request: {}, principal: "owner"
      )
      store.succeed(first, result: { "ok" => true }, status: 0)
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
        owner_process_start: "start"
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
      state: "executing", principal: "owner", request_fingerprint: "fingerprint"
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
