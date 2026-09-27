# frozen_string_literal: true

require "test_helper"
require "hive/command_receipt_maintenance"
require "hive/command_receipt_pruner"
require "hive/command_receipt_store"
require "hive/runtime_control_plane/command_schema_installation"

class CommandReceiptMaintenanceTest < Minitest::Test
  TEST_PACKAGE = {
    version: "0.0.0-test", location: "https://example.invalid/compat.gem", sha256: "e" * 64
  }.freeze

  def test_preview_and_confirm_prune_only_old_unpinned_terminals
    with_receipts do |project, database, store, authority|
      old = terminal_receipt(store, project, "old")
      recent = terminal_receipt(store, project, "recent")
      unresolved = store.reserve(
        project_root: project, key: "unknown", command: "approve", target: "task",
        request: {}, principal: "owner"
      )
      store.mark_unresolved(unresolved, reason: "lost")
      database.transaction do |db|
        db[:command_receipts].where(receipt_id: old.receipt_id).update(
          terminal_at: Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc - 31 * 86_400)
        )
      end
      namespace = old.namespace_id
      pruner = Hive::CommandReceiptPruner.new(database: database, authority: authority)

      preview = pruner.preview(namespace_id: namespace)
      assert_equal [ old.receipt_id ], preview.fetch("candidates").map { |row| row.fetch("receipt_id") }
      assert database.read { |db| db[:command_receipts][receipt_id: old.receipt_id] }

      result = pruner.prune(namespace_id: namespace)
      assert_equal "deleted", result.fetch("outcomes").first.fetch("outcome")
      assert_nil store.receipt(old.receipt_id)
      assert store.receipt(recent.receipt_id)
      assert store.receipt(unresolved.receipt_id)
    end
  end

  def test_settle_without_result_is_terminal_audited_and_never_retries
    with_receipts do |project, database, store, authority|
      claim = store.reserve(
        project_root: project, key: "unknown", command: "act", target: "task",
        request: { observation: "a" * 64 }, principal: "owner"
      )
      claim = store.mark_executing(claim)
      store.mark_unresolved(claim, reason: "lost_acknowledgement")
      row = store.receipt(claim.receipt_id)
      maintenance = Hive::CommandReceiptMaintenance.new(
        database: database, authority: authority, alive: ->(_) { false }
      )

      preview = maintenance.settle_without_result(
        claim.receipt_id, expected_generation: row.fetch(:generation),
        reason: "authority unavailable", confirm: false
      )
      assert_equal true, preview.fetch("preview")
      assert_equal "unresolved", store.receipt(claim.receipt_id).fetch(:state)

      result = maintenance.settle_without_result(
        claim.receipt_id, expected_generation: row.fetch(:generation),
        reason: "authority unavailable", confirm: true
      )
      assert_equal "settled", result.fetch("state")
      settled = store.receipt(claim.receipt_id)
      assert_equal "settled", settled.fetch(:state)
      assert_equal Hive::ExitCodes::COMMAND_UNRESOLVED, settled.fetch(:result_status)
      assert_equal 1, database.read { |db| db[:command_maintenance_audit].count }

      error = assert_raises(Hive::CommandUnresolved) do
        Hive::CommandOperation.new(
          key: "unknown", command: "act", target: "task",
          request: { observation: "a" * 64 }, project_root: project,
          principal: "owner", json: true, store: store
        ).call { flunk "settled command must not execute" }
      end
      assert_equal "command_original_result_unavailable", error.reason
      assert_equal "settled", error.state
    end
  end

  def test_pin_requires_absolute_future_horizon_and_identity_is_immutable
    with_receipts do |project, _database, store, _authority|
      claim = terminal_receipt(store, project, "pinned")
      assert_raises(Hive::UsageError) do
        store.acquire_pin(
          receipt_id: claim.receipt_id, principal: "owner", intent_id: "intent",
          intent_generation: 1, retry_horizon_expires_at: nil
        )
      end
      horizon = (Time.now.utc + 3600).iso8601
      first = store.acquire_pin(
        receipt_id: claim.receipt_id, principal: "owner", intent_id: "intent",
        intent_generation: 1, retry_horizon_expires_at: horizon
      )
      repeated = store.acquire_pin(
        receipt_id: claim.receipt_id, principal: "owner", intent_id: "intent",
        intent_generation: 1, retry_horizon_expires_at: horizon
      )
      assert_equal first.pin_id, repeated.pin_id
      assert_raises(Hive::CommandConflict) do
        store.acquire_pin(
          receipt_id: claim.receipt_id, principal: "owner", intent_id: "intent",
          intent_generation: 1, retry_horizon_expires_at: (Time.now.utc + 7200).iso8601
        )
      end
    end
  end

  def test_force_released_pin_cannot_be_reacquired_after_its_persisted_horizon
    with_receipts do |project, database, store, authority|
      claim = terminal_receipt(store, project, "released-pin")
      horizon = (Time.now.utc + 3600).iso8601
      pin = store.acquire_pin(
        receipt_id: claim.receipt_id, principal: "owner", intent_id: "intent",
        intent_generation: 1, retry_horizon_expires_at: horizon,
        owner_process_start: "start"
      )
      maintenance = Hive::CommandReceiptMaintenance.new(
        database: database, authority: authority
      )
      maintenance.release_pin(
        pin.pin_id, expected_generation: pin.generation,
        reason: "intent was explicitly cancelled", confirm: true, force: true
      )
      past = (Time.now.utc - 1).iso8601
      database.transaction do |db|
        db[:command_receipt_pins].where(pin_id: pin.pin_id).update(
          retry_horizon_expires_at: Hive::RuntimeControlPlane::Codec.dump_time(Time.iso8601(past))
        )
      end

      error = assert_raises(Hive::CommandUnresolved) do
        store.acquire_pin(
          receipt_id: claim.receipt_id, principal: "owner", intent_id: "intent",
          intent_generation: 1, retry_horizon_expires_at: past
        )
      end
      assert_equal "command_pin_horizon_elapsed", error.reason
      assert_includes error.message, "new acquisition identity"
    end
  end

  def test_force_released_pin_cannot_be_reacquired_before_horizon_either
    with_receipts do |project, database, store, authority|
      claim = terminal_receipt(store, project, "released-pin-future")
      horizon = (Time.now.utc + 3600).iso8601
      pin = store.acquire_pin(
        receipt_id: claim.receipt_id, principal: "owner", intent_id: "intent",
        intent_generation: 1, retry_horizon_expires_at: horizon,
        owner_process_start: "start"
      )
      Hive::CommandReceiptMaintenance.new(database: database, authority: authority).release_pin(
        pin.pin_id, expected_generation: pin.generation,
        reason: "intent cancelled", confirm: true, force: true
      )

      assert_raises(Hive::CommandUnresolved) do
        store.acquire_pin(
          receipt_id: claim.receipt_id, principal: "owner", intent_id: "intent",
          intent_generation: 1, retry_horizon_expires_at: horizon
        )
      end
    end
  end

  def test_maintenance_authorization_precedes_disclosure_and_mutation
    with_receipts do |project, database, store, owner|
      claim = store.reserve(
        project_root: project, key: "foreign", command: "approve", target: "task",
        request: {}, principal: "foreign"
      )
      claim = store.mark_executing(claim)
      store.mark_unresolved(claim, reason: "lost")
      row = store.receipt(claim.receipt_id)
      nonowner = Hive::CommandMaintenanceAuthority.new(
        principal: "caller", principal_source: "test"
      )
      maintenance = Hive::CommandReceiptMaintenance.new(
        database: database, authority: nonowner, alive: ->(_) { false }
      )

      assert_raises(Hive::ConfigError) do
        maintenance.settle_without_result(
          claim.receipt_id, expected_generation: row.fetch(:generation),
          reason: "denied", confirm: true
        )
      end
      assert_raises(Hive::ConfigError) do
        maintenance.settle_without_result(
          "unknown", expected_generation: 1, reason: "denied", confirm: false
        )
      end
      assert_equal "unresolved", store.receipt(claim.receipt_id).fetch(:state)
      assert_equal 0, database.read { |db| db[:command_maintenance_audit].count }

      preview = Hive::CommandReceiptMaintenance.new(
        database: database, authority: owner, alive: ->(_) { false }
      ).settle_without_result(
        claim.receipt_id, expected_generation: row.fetch(:generation),
        reason: "owner preview", confirm: false
      )
      assert_equal true, preview.fetch("preview")
    end
  end

  def test_revoked_github_owner_is_denied_at_confirm_time_without_audit
    with_receipts do |project, database, store, _owner|
      claim = store.reserve(
        project_root: project, key: "github-revoked", command: "approve", target: "task",
        request: {}, principal: "foreign"
      )
      executing = store.mark_executing(claim)
      store.mark_unresolved(executing, reason: "lost")
      row = store.receipt(claim.receipt_id)
      current = { "github" => { "owner" => "Alice", "owner_id" => 42 } }
      authority = Hive::CommandMaintenanceAuthority.github(
        config: current, login: "Alice", id: 42, config_loader: -> { current }
      )
      maintenance = Hive::CommandReceiptMaintenance.new(
        database: database, authority: authority, alive: ->(*) { false }
      )
      preview = maintenance.settle_without_result(
        claim.receipt_id, expected_generation: row.fetch(:generation),
        reason: "preview", confirm: false
      )
      assert preview.fetch("preview")

      current = { "github" => { "owner" => "Bob", "owner_id" => 7 } }
      assert_raises(Hive::ConfigError) do
        maintenance.settle_without_result(
          claim.receipt_id, expected_generation: row.fetch(:generation),
          reason: "revoked", confirm: true
        )
      end
      assert_equal "unresolved", store.receipt(claim.receipt_id).fetch(:state)
      assert_equal 0, database.read { |db| db[:command_maintenance_audit].count }
    end
  end

  def test_maintenance_prune_receipt_does_not_decrement_unreserved_capacity
    with_receipts do |project, database, store, authority|
      Hive::ProjectIdentity.resolve(project_root: project, database: database, create: true)
      claim = store.reserve(
        project_root: project, key: "maintenance", command: "receipt", mode: "prune",
        target: "demo", request: {}, principal: "owner", maintenance: true,
        execute: true, owner_process_start: "dead"
      )
      before = database.read { |db| db[:command_capacity][namespace_id: claim.namespace_id] }
      maintenance = Hive::CommandReceiptMaintenance.new(
        database: database, authority: authority, alive: ->(_) { false }
      )
      maintenance.orphaned_owner(
        claim.receipt_id, expected_generation: claim.generation,
        reason: "dead maintenance owner", confirm: true
      )
      unresolved = store.receipt(claim.receipt_id)
      maintenance.settle_without_result(
        claim.receipt_id, expected_generation: unresolved.fetch(:generation),
        reason: "abandon interrupted prune", confirm: true
      )
      after = database.read { |db| db[:command_capacity][namespace_id: claim.namespace_id] }

      assert_equal before.slice(:nonterminal_count, :executing_count),
                   after.slice(:nonterminal_count, :executing_count)
    end
  end

  def test_read_only_preview_does_not_change_database_or_sidecar_bytes
    with_receipts do |project, database, store, authority|
      terminal_receipt(store, project, "snapshot")
      paths = [ database.path, "#{database.path}-wal", "#{database.path}-shm" ]
      before_entries = Dir.children(File.dirname(database.path)).sort
      before = paths.to_h do |path|
        [ path, File.exist?(path) ? Digest::SHA256.file(path).hexdigest : nil ]
      end

      Hive::CommandReceiptPruner.new(
        database: database, authority: authority
      ).preview(project_root: project)

      assert_equal before_entries, Dir.children(File.dirname(database.path)).sort
      after = paths.to_h do |path|
        [ path, File.exist?(path) ? Digest::SHA256.file(path).hexdigest : nil ]
      end
      assert_equal before, after
    end
  end

  def test_selected_namespace_maintenance_identities_paginate_with_effective_limits
    with_receipts do |project, database, store, authority|
      claims = 3.times.map do |index|
        store.reserve(
          project_root: project, key: "page-#{index}", command: "approve",
          target: "task-#{index}", request: {}, principal: "owner"
        )
      end
      pruner = Hive::CommandReceiptPruner.new(database: database, authority: authority)

      first = pruner.preview(namespace_id: claims.first.namespace_id, limit: 1)
      cursor = first.fetch("maintenance_next_cursor")
      second = pruner.preview(
        namespace_id: claims.first.namespace_id, limit: 1, cursor: cursor
      )

      refute_nil cursor
      refute_equal first.fetch("nonterminal_receipts"), second.fetch("nonterminal_receipts")
      assert_equal 1_000, first.dig("namespace_utilization", "limits", "nonterminal_count")
      assert first.dig("installation_utilization", "occupied_bytes").positive?
      assert_includes %w[normal warning action],
                      first.dig("installation_utilization", "pressure_band")
    end
  end

  def test_entirely_unenrolled_project_previews_empty_without_enrollment
    with_receipts do |_project, database, _store, authority|
      Dir.mktmpdir do |dir|
        system("git", "init", "--quiet", dir, exception: true)
        preview = Hive::CommandReceiptPruner.new(
          database: database, authority: authority
        ).preview(project_root: dir)
        assert_equal "absent", preview.fetch("project_enrollment")
        assert_equal 0, preview.fetch("candidate_count")
        rows = database.read do |db|
          db[:command_namespaces].where(project_label: File.basename(dir)).all
        end
        assert_empty rows
      end
    end
  end

  def test_prune_contention_and_unfinished_batches_return_recoverable_failures
    authority = Hive::CommandMaintenanceAuthority.new(
      principal: "owner", principal_source: "test", installation_owner: true
    )
    locked = Object.new
    locked.define_singleton_method(:read_only) { raise Sequel::DatabaseLockTimeout, "locked" }
    error = assert_raises(Hive::CommandCapacityError) do
      Hive::CommandReceiptPruner.new(database: locked, authority: authority).preview
    end
    assert_equal "command_prune_busy", error.reason

    locked = Object.new
    locked.define_singleton_method(:transaction) { raise Sequel::DatabaseLockTimeout, "locked" }
    pruner = Hive::CommandReceiptPruner.new(database: locked, authority: authority)
    pruner.define_singleton_method(:resolve_namespace) { |**| "namespace" }
    error = assert_raises(Hive::CommandCapacityError) { pruner.prune(project_root: "/project") }
    assert_equal "command_prune_busy", error.reason

    with_receipts do |project, database, store, owner|
      claim = terminal_receipt(store, project, "busy")
      now = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc)
      database.transaction do |connection|
        connection[:command_maintenance_batches].insert(
          batch_id: "unfinished", namespace_id: claim.namespace_id, principal: "foreign",
          principal_scope: "own", kind: "prune", state: "executing", generation: 3,
          owner_host: "host", owner_pid: 1, fixed_cutoff: now,
          candidates_json: "[]", outcomes_json: "[]", created_at: now, updated_at: now
        )
      end

      error = assert_raises(Hive::CommandCapacityError) do
        Hive::CommandReceiptPruner.new(database: database, authority: owner)
          .prune(namespace_id: claim.namespace_id)
      end
      assert_includes error.message, "unfinished"
      assert_includes error.message, "generation 3"

      own = Hive::CommandMaintenanceAuthority.new(
        principal: "owner", principal_source: "test", installation_owner: false
      )
      error = assert_raises(Hive::CommandCapacityError) do
        Hive::CommandReceiptPruner.new(database: database, authority: own)
          .prune(project_root: project)
      end
      assert_equal "another prune batch is unfinished; ask the installation owner to recover it",
                   error.message
    end
  end

  private

  def terminal_receipt(store, project, key)
    claim = store.reserve(
      project_root: project, key: key, command: "approve", target: "task",
      request: {}, principal: "owner"
    )
    store.succeed(claim, result: { "ok" => true }, status: 0)
  end

  def with_receipts
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
      store = Hive::CommandReceiptStore.new(database: database)
      authority = Hive::CommandMaintenanceAuthority.new(
        principal: "owner", principal_source: "test", installation_owner: true
      )
      yield project, database, store, authority
    ensure
      database&.disconnect
    end
  end
end
