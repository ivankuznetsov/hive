# frozen_string_literal: true

require "test_helper"
require "json_schemer"
require "hive/command_receipt_maintenance"
require "hive/command_receipt_pruner"
require "hive/command_receipt_store"
require "hive/runtime_control_plane/command_schema_installation"
require "open3"
require "rbconfig"

class CommandReceiptMaintenanceTest < Minitest::Test
  include HiveTestHelper

  TEST_PACKAGE = {
    version: "0.0.0-test", location: "https://example.invalid/compat.gem", sha256: "e" * 64
  }.freeze

  def test_namespace_selection_requires_the_installation_owner
    owner = Hive::CommandMaintenanceAuthority.new(
      principal: "owner", principal_source: "test", installation_owner: true
    )
    nonowner = Hive::CommandMaintenanceAuthority.new(
      principal: "caller", principal_source: "test"
    )

    assert_equal "namespace", Hive::CommandReceiptMaintenance.new(
      database: Object.new, authority: owner
    ).authorize_namespace_selection!("namespace")
    assert_raises(Hive::ConfigError) do
      Hive::CommandReceiptMaintenance.new(
        database: Object.new, authority: nonowner
      ).authorize_namespace_selection!("namespace")
    end
  end

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
      schema = JSONSchemer.schema(
        JSON.parse(File.read(Hive::Schemas.schema_path("hive-receipt-prune")))
      )

      preview = pruner.preview(namespace_id: namespace)
      assert_empty schema.validate(preview).to_a
      assert_equal [ old.receipt_id ], preview.fetch("candidates").map { |row| row.fetch("receipt_id") }
      assert database.read { |db| db[:command_receipts][receipt_id: old.receipt_id] }

      result = pruner.prune(namespace_id: namespace)
      assert_empty schema.validate(result).to_a
      assert_equal "deleted", result.fetch("outcomes").first.fetch("outcome")
      assert_nil store.receipt(old.receipt_id)
      assert store.receipt(recent.receipt_id)
      assert store.receipt(unresolved.receipt_id)
    end
  end

  def test_prune_cutoff_is_strict_and_excludes_future_terminal_rows
    with_receipts do |project, database, store, authority|
      now = Time.utc(2030, 2, 1, 12)
      cutoff = now - Hive::CommandReceiptPruner::RETENTION_SECONDS
      claims = %w[before exact after future].to_h do |name|
        [ name, terminal_receipt(store, project, "cutoff-#{name}") ]
      end
      terminal_times = {
        "before" => cutoff - 1, "exact" => cutoff,
        "after" => cutoff + 1, "future" => now + 86_400
      }
      database.transaction do |connection|
        claims.each do |name, claim|
          connection[:command_receipts].where(receipt_id: claim.receipt_id).update(
            terminal_at: Hive::RuntimeControlPlane::Codec.dump_time(terminal_times.fetch(name))
          )
        end
      end

      pruner = Hive::CommandReceiptPruner.new(
        database: database, authority: authority, clock: -> { now }
      )
      preview = pruner.preview(namespace_id: claims.fetch("before").namespace_id)
      assert_equal [ claims.fetch("before").receipt_id ],
                   preview.fetch("candidates").map { |row| row.fetch("receipt_id") }
      result = pruner.prune(namespace_id: claims.fetch("before").namespace_id)
      assert_equal [ claims.fetch("before").receipt_id ],
                   result.fetch("outcomes").map { |row| row.fetch("receipt_id") }
      %w[exact after future].each { |name| assert store.receipt(claims.fetch(name).receipt_id) }
    end
  end

  def test_prune_limit_default_and_maximum_boundaries
    with_receipts do |project, database, store, authority|
      claims = 101.times.map { |index| terminal_receipt(store, project, "limit-#{index}") }
      old = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc - 31 * 86_400)
      database.transaction do |connection|
        connection[:command_receipts].where(
          receipt_id: claims.map(&:receipt_id)
        ).update(terminal_at: old)
      end
      pruner = Hive::CommandReceiptPruner.new(database: database, authority: authority)

      assert_equal 100, pruner.preview(namespace_id: claims.first.namespace_id)
        .fetch("candidates").length
      assert_equal 101, pruner.preview(namespace_id: claims.first.namespace_id, limit: 1_000)
        .fetch("candidates").length
      assert_raises(Hive::UsageError) do
        pruner.preview(namespace_id: claims.first.namespace_id, limit: 1_001)
      end
    end
  end

  def test_prune_preserves_successor_binding_while_predecessor_intent_is_active
    with_receipts do |project, database, store, authority|
      predecessor = terminal_receipt(store, project, "bound-predecessor")
      successor = terminal_receipt(store, project, "bound-successor")
      horizon = (Time.now.utc + 3600).iso8601
      store.acquire_pin(
        receipt_id: predecessor.receipt_id, principal: "owner", intent_id: "intent",
        intent_generation: 1, retry_horizon_expires_at: horizon, project_root: project
      )
      old = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc - 31 * 86_400)
      database.transaction do |db|
        db[:command_receipts].where(
          receipt_id: [ predecessor.receipt_id, successor.receipt_id ]
        ).update(terminal_at: old)
        db[:command_successor_allocations].insert(
          allocation_id: SecureRandom.uuid, namespace_id: predecessor.namespace_id,
          principal: "owner", intent_id: "intent", intent_version: 1,
          delivery_cycle_id: "cycle", predecessor_receipt_id: predecessor.receipt_id,
          successor_receipt_id: successor.receipt_id, successor_key_identity: "successor-key",
          successor_ordinal: 1, request_fingerprint: predecessor.request_fingerprint,
          allocation_version: 1, created_at: old
        )
      end

      preview = Hive::CommandReceiptPruner.new(database: database, authority: authority)
        .preview(namespace_id: predecessor.namespace_id)
      ids = preview.fetch("candidates").map { |candidate| candidate.fetch("receipt_id") }
      refute_includes ids, predecessor.receipt_id
      refute_includes ids, successor.receipt_id
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
        intent_generation: 1, retry_horizon_expires_at: horizon, project_root: project
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
        owner_process_start: "start", project_root: project
      )
      maintenance = Hive::CommandReceiptMaintenance.new(
        database: database, authority: authority
      )
      preview = maintenance.release_pin(
        pin.pin_id, expected_generation: pin.generation,
        reason: "intent was explicitly cancelled"
      )
      assert_equal false, preview.fetch("horizon_elapsed")
      assert_includes preview.fetch("warning"), "unreachable-but-live"
      assert_includes preview.fetch("warning"), "replay/conflict protection"
      assert_includes %w[dead live_remote_or_unverifiable unverifiable],
                      preview.dig("evidence", "owner_liveness", "status")
      maintenance.release_pin(
        pin.pin_id, expected_generation: pin.generation,
        reason: "intent was explicitly cancelled", confirm: true, force: true
      )
      audit = database.read do |db|
        db[:command_maintenance_audit][pin_id: pin.pin_id]
      end
      evidence = Hive::RuntimeControlPlane::Codec.load_json(audit.fetch(:evidence_json))
      assert evidence.fetch("horizon").key?("horizon_elapsed")
      assert evidence.fetch("owner_liveness").fetch("status")
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
        owner_process_start: "start", project_root: project
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

  def test_active_pin_reacquisition_keeps_identity_after_horizon
    with_receipts do |project, database, store, _authority|
      claim = terminal_receipt(store, project, "active-pin-past-horizon")
      now = Time.utc(2030, 1, 1)
      horizon = (now + 60).iso8601
      initial_store = Hive::CommandReceiptStore.new(database: database, clock: -> { now })
      first = initial_store.acquire_pin(
        receipt_id: claim.receipt_id, principal: "owner", intent_id: "intent",
        intent_generation: 1, retry_horizon_expires_at: horizon, project_root: project
      )
      later_store = Hive::CommandReceiptStore.new(database: database, clock: -> { now + 120 })
      repeated = later_store.acquire_pin(
        receipt_id: claim.receipt_id, principal: "owner", intent_id: "intent",
        intent_generation: 1, retry_horizon_expires_at: horizon
      )

      assert_equal first.pin_id, repeated.pin_id
      assert_equal "active", repeated.lifecycle_status
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

      foreign_error = assert_raises(Hive::ConfigError) do
        maintenance.settle_without_result(
          claim.receipt_id, expected_generation: row.fetch(:generation),
          reason: "denied", confirm: true
        )
      end
      missing_error = assert_raises(Hive::ConfigError) do
        maintenance.settle_without_result(
          "unknown", expected_generation: 1, reason: "denied", confirm: false
        )
      end
      assert_equal foreign_error.message.b, missing_error.message.b
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

  def test_cold_preview_refuses_without_creating_wal_or_shm_sidecars
    with_receipts do |project, database, _store, authority|
      database.disconnect
      wal = "#{database.path}-wal"
      shm = "#{database.path}-shm"
      File.delete(wal) if File.exist?(wal)
      File.delete(shm) if File.exist?(shm)
      before = Digest::SHA256.file(database.path).hexdigest

      error = assert_raises(Hive::CommandCapacityError) do
        Hive::CommandReceiptPruner.new(database: database, authority: authority)
          .preview(project_root: project)
      end

      assert_equal "command_prune_preview_unavailable", error.reason
      assert_equal before, Digest::SHA256.file(database.path).hexdigest
      refute File.exist?(wal)
      refute File.exist?(shm)
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

    wrapped_busy = Object.new
    wrapped_busy.define_singleton_method(:read_only) do
      begin
        raise SQLite3::BusyException, "busy"
      rescue SQLite3::BusyException
        raise Sequel::DatabaseError, "wrapped busy"
      end
    end
    error = assert_raises(Hive::CommandCapacityError) do
      Hive::CommandReceiptPruner.new(database: wrapped_busy, authority: authority).preview
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

  def test_real_sqlite_writer_contention_reports_command_prune_busy
    with_receipts do |project, database, store, authority|
      claim = terminal_receipt(store, project, "busy-real")
      locker = <<~'RUBY'
        database = SQLite3::Database.new(ARGV.fetch(0))
        database.execute("PRAGMA busy_timeout = 1")
        database.execute("BEGIN IMMEDIATE")
        database.execute("UPDATE command_capacity SET revision = revision")
        STDOUT.write("locked")
        STDOUT.flush
        sleep
      RUBY
      child_input, child_output, child_error, child = Open3.popen3(
        RbConfig.ruby, "-rsqlite3", "-e", locker, database.path
      )
      child_input.close
      assert_equal "locked", child_output.read(6), child_error.read_nonblock(4096, exception: false).to_s
      contender = Hive::RuntimeControlPlane::Database.new(
        path: database.path, busy_timeout_ms: 1
      ).open!

      error = assert_raises(Hive::CommandCapacityError) do
        Hive::CommandReceiptPruner.new(database: contender, authority: authority)
          .prune(namespace_id: claim.namespace_id)
      end
      assert_equal "command_prune_busy", error.reason
    ensure
      contender&.disconnect
      child_output&.close unless child_output&.closed?
      child_error&.close unless child_error&.closed?
      if child
        Process.kill("KILL", child.pid) rescue Errno::ESRCH
        child.value
      end
    end
  end

  def test_settle_then_prune_returns_the_logical_byte_ledger_to_baseline
    with_receipts do |project, database, store, authority|
      identity = Hive::ProjectIdentity.resolve(
        project_root: project, database: database, create: true
      )
      baseline = database.read do |db|
        db[:command_capacity][namespace_id: identity.namespace_id].fetch(:logical_bytes)
      end
      claim = store.reserve(
        project_root: project, key: "settle-prune-ledger", command: "approve",
        target: "task", request: {}, principal: "owner"
      )
      executing = store.mark_executing(
        claim, owner_host: Socket.gethostname, owner_pid: 424_242,
        owner_process_start: "dead-start"
      )
      store.mark_unresolved(executing, reason: "lost")
      before_settlement = database.read do |db|
        db[:command_capacity][namespace_id: identity.namespace_id].fetch(:nonterminal_count)
      end
      assert_equal 1, before_settlement
      row = store.receipt(claim.receipt_id)
      Hive::CommandReceiptMaintenance.new(
        database: database, authority: authority,
        alive: ->(*) { false }, ownership: ->(*) { :reused }
      ).settle_without_result(
        claim.receipt_id, expected_generation: row.fetch(:generation),
        reason: "settled for ledger test", confirm: true
      )
      after_settlement = database.read do |db|
        db[:command_capacity][namespace_id: identity.namespace_id].fetch(:nonterminal_count)
      end
      assert_equal 0, after_settlement
      database.transaction do |db|
        db[:command_receipts].where(receipt_id: claim.receipt_id).update(
          terminal_at: Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc - 31 * 86_400)
        )
      end

      Hive::CommandReceiptPruner.new(database: database, authority: authority)
        .prune(namespace_id: identity.namespace_id)

      after = database.read do |db|
        db[:command_capacity][namespace_id: identity.namespace_id]
      end
      assert_equal baseline, after.fetch(:logical_bytes)
      assert_equal after_settlement, after.fetch(:nonterminal_count),
                   "prune must not decrement nonterminal capacity a second time"
    end
  end

  def test_maintenance_negative_logical_bytes_are_clamped
    with_receipts do |project, database, _store, authority|
      identity = Hive::ProjectIdentity.resolve(
        project_root: project, database: database, create: true
      )
      maintenance = Hive::CommandReceiptMaintenance.new(
        database: database, authority: authority
      )

      database.transaction do |connection|
        maintenance.send(:add_logical_bytes!, connection, identity.namespace_id, -1)
      end

      logical_bytes = database.read do |connection|
        connection[:command_capacity][namespace_id: identity.namespace_id].fetch(:logical_bytes)
      end
      assert_equal 0, logical_bytes
    end
  end

  def test_pruner_derives_local_authority_from_runtime_installation_identity
    installation = Object.new
    installation.define_singleton_method(:first) { { installation_id: "installation-1" } }
    connection = Object.new
    connection.define_singleton_method(:[]) { |_name| installation }
    derived = Hive::CommandMaintenanceAuthority.new(
      principal: "derived", principal_source: "test", installation_owner: true
    )
    principals = []
    test_case = self

    with_replaced_singleton_method(
      Hive::CommandMaintenanceAuthority, :local,
      lambda { |principal:| principals << principal; derived }
    ) do
      pruner = Hive::CommandReceiptPruner.new(database: Object.new)
      assert_same derived, pruner.send(:authority, connection)

      database = Object.new
      with_replaced_singleton_method(
        Hive::CommandOperation, :local_principal,
        ->(value) { test_case.assert_same database, value; "fallback" }
      ) do
        assert_same derived, Hive::CommandReceiptPruner.new(database: database).send(:authority)
      end
    end

    assert_equal [
      "installation:installation-1:uid:#{Process.uid}", "fallback"
    ], principals

    missing = Object.new
    missing.define_singleton_method(:first) { nil }
    connection.define_singleton_method(:[]) { |_name| missing }
    assert_raises(Hive::ConfigError) do
      Hive::CommandReceiptPruner.new(database: Object.new).send(:authority, connection)
    end
  end

  def test_confirmed_prune_expires_completed_batch_bookkeeping_and_audit
    with_receipts do |project, database, store, authority|
      terminal = terminal_receipt(store, project, "batch-retention")
      old = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc - 31 * 86_400)
      now = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc)
      database.transaction do |connection|
        connection[:command_maintenance_batches].insert(
          batch_id: "expired-batch", namespace_id: terminal.namespace_id,
          principal: "owner", principal_scope: "own", kind: "prune",
          state: "completed", generation: 2, fixed_cutoff: old,
          candidates_json: "[]", outcomes_json: "[]", created_at: old,
          updated_at: old, completed_at: old
        )
        connection[:command_maintenance_batches].insert(
          batch_id: "expired-unkeyed-batch", namespace_id: nil,
          administrative_receipt_id: nil, principal: "owner",
          principal_scope: "installation", kind: "prune", state: "completed",
          generation: 1, fixed_cutoff: old, candidates_json: "[]",
          outcomes_json: "[]", created_at: old, updated_at: old, completed_at: old
        )
        connection[:command_maintenance_audit].insert(
          audit_id: "expired-batch-audit", batch_id: "expired-batch",
          namespace_id: terminal.namespace_id, acting_principal: "owner",
          principal_source: "test", authority_basis: "installation_owner",
          action: "prune", evidence_json: "{}", created_at: now
        )
      end

      Hive::CommandReceiptPruner.new(database: database, authority: authority)
        .prune(namespace_id: terminal.namespace_id)

      database.read do |connection|
        assert_nil connection[:command_maintenance_batches][batch_id: "expired-batch"]
        assert_nil connection[:command_maintenance_batches][batch_id: "expired-unkeyed-batch"]
        assert_nil connection[:command_maintenance_audit][audit_id: "expired-batch-audit"]
      end
    end
  end

  def test_maintenance_validation_and_capacity_guards_are_explicit
    with_receipts do |project, database, store, authority|
      claim = store.reserve(
        project_root: project, key: "validation", command: "approve", target: "task",
        request: {}, principal: "owner"
      )
      executing = store.mark_executing(
        claim, owner_host: Socket.gethostname, owner_pid: 424_242,
        owner_process_start: "dead-start"
      )
      effect = store.prepare_effect(
        executing, ordinal: 0, kind: "approve:default", identity: {}
      )
      store.update_effect(
        executing, effect_id: effect.fetch(:effect_id), from: "prepared", to: "not_applied"
      )
      store.mark_unresolved(executing, reason: "lost")
      row = store.receipt(claim.receipt_id)
      maintenance = Hive::CommandReceiptMaintenance.new(
        database: database, authority: authority,
        alive: ->(*) { false }, ownership: ->(*) { :dead }
      )

      pin = store.acquire_pin(
        receipt_id: claim.receipt_id, principal: "owner", intent_id: "intent",
        intent_generation: 1, retry_horizon_expires_at: (Time.now.utc + 3600).iso8601,
        owner_process_start: "dead-start", project_root: project
      )
      assert_raises(Hive::UsageError) do
        maintenance.release_pin(
          pin.pin_id, expected_generation: pin.generation, reason: "wrong namespace",
          namespace_id: "other"
        )
      end

      assert_raises(Hive::UsageError) do
        maintenance.send(
          :validate_retirement_evidence!, row,
          "outcome" => "not_applied", "whole_effect_non_application" => true,
          "status" => "invalid", "result" => {}
        )
      end

      effect = {
        effect_id: "effect", ordinal: 0, state: "applied", identity_json: "{}",
        evidence_json: "{"
      }
      proof = {
        "effect_id" => "effect", "ordinal" => 0,
        "identity_sha256" => Digest::SHA256.hexdigest("{}"), "observation" => {}
      }
      assert_raises(Hive::CommandUnresolved) do
        maintenance.send(:validate_successful_reconciliation!, [ effect ], "effects" => [ proof ])
      end

      database.read do |connection|
        capacity = connection[:command_capacity][namespace_id: row.fetch(:namespace_id)]
        limits = [ capacity.fetch(:executing_count), 100 ]
        assert_raises(Hive::CommandCapacityError) do
          maintenance.send(:admit_existing_work_execution!, connection, row, limits)
        end
        limits = [ 100, connection[:command_capacity].sum(:executing_count).to_i ]
        assert_raises(Hive::CommandCapacityError) do
          maintenance.send(:admit_existing_work_execution!, connection, row, limits)
        end
      end

      bad_limits = Object.new
      bad_limits.define_singleton_method(:read) do |&block|
        table = Object.new
        table.define_singleton_method(:[]) { |_query| { concurrency_limit: 0 } }
        connection = Object.new
        connection.define_singleton_method(:[]) { |_name| table }
        block.call(connection)
      end
      invalid = Hive::CommandReceiptMaintenance.new(database: bad_limits, authority: authority)
      with_replaced_singleton_method(
        Hive::CommandReceiptCapacity, :global_receipts,
        -> { { "installation_concurrency_limit" => 1 } }
      ) do
        assert_raises(Hive::ConfigError) do
          invalid.send(:retirement_concurrency_limits, namespace_id: "namespace")
        end
      end
    end
  end

  def test_terminalization_uses_validated_retry_eligibility_not_raw_evidence
    with_receipts do |project, database, store, authority|
      claim = store.reserve(
        project_root: project, key: "validated-retry", command: "approve", target: "task",
        request: {}, principal: "owner"
      )
      executing = store.mark_executing(claim)
      store.mark_unresolved(executing, reason: "lost")
      row = store.receipt(claim.receipt_id)
      result = {
        "format" => "json", "payload" => { "ok" => true },
        "expanded_sha256" => Digest::SHA256.hexdigest(
          Hive::RuntimeControlPlane::Codec.dump_json("ok" => true)
        )
      }
      maintenance = Hive::CommandReceiptMaintenance.new(
        database: database, authority: authority
      )

      maintenance.send(
        :terminalize!, row, state: "succeeded", result: result, status: 0,
        typed_reason: nil, reason: "validated success",
        evidence: { "whole_effect_non_application" => true }, retry_eligible: false
      )

      assert_equal 0, store.receipt(claim.receipt_id).fetch(:retry_eligible)
    end
  end

  def test_settlement_rejects_an_in_flight_continuation
    authority = Hive::CommandMaintenanceAuthority.new(
      principal: "owner", principal_source: "test", installation_owner: true
    )
    contexts = Object.new
    contexts.define_singleton_method(:where) { |**| contexts }
    contexts.define_singleton_method(:all) { [ { request_id: "request" } ] }
    requests = Object.new
    requests.define_singleton_method(:[]) { |_query| { state: "queued" } }
    database = Object.new
    database.define_singleton_method(:read) do |&block|
      connection = Object.new
      connection.define_singleton_method(:[]) do |name|
        name == :command_dispatch_contexts ? contexts : requests
      end
      block.call(connection)
    end
    maintenance = Hive::CommandReceiptMaintenance.new(
      database: database, authority: authority,
      alive: ->(*) { false }, ownership: ->(*) { :dead }
    )
    row = {
      receipt_id: "receipt", owner_host: Socket.gethostname,
      owner_pid: 424_242, owner_process_start: "dead-start"
    }
    assert_raises(Hive::CommandUnresolved) do
      maintenance.send(:ensure_settlement_safe!, row)
    end
  end

  def test_replay_envelopes_require_complete_typed_payloads
    maintenance = Hive::CommandReceiptMaintenance.allocate
    assert_raises(Hive::UsageError) do
      maintenance.send(:validate_replay_envelope!, {})
    end
    assert_raises(Hive::UsageError) do
      maintenance.send(
        :validate_replay_envelope!, "format" => "json", "payload" => {},
        "expanded_sha256" => "wrong"
      )
    end
    payload = { "ok" => true }
    digest = Digest::SHA256.hexdigest(Hive::RuntimeControlPlane::Codec.dump_json(payload))
    maintenance.send(
      :validate_replay_envelope!, "format" => "dual", "payload" => payload,
      "expanded_sha256" => digest
    )
    assert_raises(Hive::UsageError) do
      maintenance.send(:validate_replay_envelope!, "format" => "text", "text" => nil)
    end
    invalid = {
      "schema" => "hive-approve", "schema_version" => 2, "ok" => false,
      "error_class" => "CommandConflict", "error_kind" => "not-published",
      "exit_code" => 99, "message" => "bad"
    }
    invalid_digest = Digest::SHA256.hexdigest(
      Hive::RuntimeControlPlane::Codec.dump_json(invalid)
    )
    assert_raises(Hive::UsageError) do
      maintenance.send(
        :validate_replay_envelope!,
        { "format" => "json", "payload" => invalid,
          "expanded_sha256" => invalid_digest },
        row: { command: "approve", mode: nil }
      )
    end

    {
      "new" => [ "usage", 1 ],
      "answer" => [ "invalid_answer", 1 ],
      "stage_action" => [ "error", 1 ]
    }.each do |command, (kind, exit_code)|
      maintenance.send(
        :validate_closed_error_enums!,
        { "error_kind" => kind, "exit_code" => exit_code },
        { command: command, mode: nil }
      )
    end
    assert_raises(Hive::UsageError) do
      maintenance.send(
        :validate_closed_error_enums!,
        { "error_kind" => "error", "exit_code" => 99 },
        { command: "approve", mode: nil }
      )
    end
    with_replaced_singleton_method(
      Hive::Schemas, :schema_path, ->(*) { "/missing/command-schema.json" }
    ) do
      assert_raises(Hive::ConfigError) do
        maintenance.send(
          :validate_closed_error_enums!,
          { "error_kind" => "error", "exit_code" => 1 },
          { command: "approve", mode: nil }
        )
      end
    end

    authority = Hive::CommandMaintenanceAuthority.new(
      principal: "owner", principal_source: "test", installation_owner: true
    )
    liveness = Hive::CommandReceiptMaintenance.new(database: Object.new, authority: authority)
    with_replaced_singleton_method(Hive::CommandOwnerProof, :dead, ->(*, **) { nil }) do
      evidence = liveness.send(:owner_liveness_evidence, {})
      assert_equal "live_remote_or_unverifiable", evidence.fetch("status")
    end
    with_replaced_singleton_method(
      Hive::CommandOwnerProof, :dead, ->(*, **) { raise Hive::Error, "unavailable" }
    ) do
      evidence = liveness.send(:owner_liveness_evidence, {})
      assert_equal "unverifiable", evidence.fetch("status")
    end

    pruner = Hive::CommandReceiptPruner.new(
      database: Object.new, authority: authority, clock: -> { Time.utc(2030) }
    )
    with_replaced_singleton_method(Hive::CommandOwnerProof, :dead, ->(*, **) { nil }) do
      evidence = pruner.send(
        :active_pin_identity,
        pin_id: "pin", generation: 1, retry_horizon_expires_at: nil
      )
      assert_equal "unavailable", evidence.fetch("horizon_evidence")
    end
    evidence = pruner.send(
      :active_pin_identity,
      pin_id: "pin", generation: 1, retry_horizon_expires_at: "not-a-time"
    )
    assert_equal "invalid_or_unavailable", evidence.fetch("horizon_evidence")
  end

  def test_owner_proof_uses_default_ownership_probe
    row = {
      owner_host: Socket.gethostname, owner_pid: Process.pid,
      owner_process_start: "dead-start"
    }
    proof = Hive::CommandOwnerProof.dead(
      row, alive: ->(*) { true }, clock: -> { Time.now.utc }
    )
    assert_equal "reused", proof.last.fetch("ownership")
  end

  def test_prune_resume_and_receipt_accounting_cover_persisted_maintenance_state
    with_receipts do |project, database, store, authority|
      old = terminal_receipt(store, project, "resume-old")
      now = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc)
      database.transaction do |connection|
        connection[:command_receipts].where(receipt_id: old.receipt_id).update(
          terminal_at: Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc - 31 * 86_400)
        )
        connection[:command_effects].insert(
          effect_id: "accounted-effect", receipt_id: old.receipt_id, ordinal: 0,
          effect_kind: "approve:default", state: "applied", identity_json: "{}",
          evidence_json: "{}", created_at: now, updated_at: now
        )
        connection[:command_maintenance_audit].insert(
          audit_id: "accounted-audit", receipt_id: old.receipt_id,
          namespace_id: old.namespace_id, acting_principal: "owner",
          principal_source: "test", authority_basis: "state_home_owner",
          action: "test", evidence_json: "{}", created_at: now
        )
      end
      pruner = Hive::CommandReceiptPruner.new(database: database, authority: authority)
      database.read do |connection|
        assert_operator pruner.send(
          :receipt_storage_bytes, connection, store.receipt(old.receipt_id)
        ), :>, 0
      end
      assert_raises(Hive::UsageError) do
        pruner.send(
          :resolve_namespace, project_root: project,
          namespace_id: old.namespace_id, write: true
        )
      end

      batch_id = "resume-batch"
      context = Hive::CommandOperation::Context.new(
        receipt_id: "administrative", effect_id: "effect", principal: "owner",
        principal_source: "test", ordinal: 0, receipt_generation: 1,
        request_fingerprint: "fingerprint",
        transport_request_id: "command-dispatch:v1:#{'d' * 64}",
        retry_horizon_expires_at: "2030-01-01T00:00:00Z"
      )
      database.transaction do |connection|
        connection[:command_maintenance_batches].insert(
          batch_id: batch_id, namespace_id: old.namespace_id,
          administrative_receipt_id: context.receipt_id, principal: "owner",
          principal_scope: "own", kind: "prune", state: "executing", generation: 1,
          owner_host: Socket.gethostname, owner_pid: Process.pid,
          owner_process_start: Hive::Lock.process_start_time(Process.pid),
          fixed_cutoff: Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc - 30 * 86_400),
          candidates_json: JSON.generate([
            { receipt_id: old.receipt_id, generation: old.generation }
          ]),
          outcomes_json: JSON.generate([
            { "receipt_id" => "already-deleted", "generation" => 1, "outcome" => "deleted" }
          ]),
          created_at: now, updated_at: now
        )
      end
      Thread.current[:hive_command_operation_context] = context
      result = pruner.prune(namespace_id: old.namespace_id)
      assert_equal batch_id, result.fetch("batch_id")
      assert_includes result.fetch("outcomes"),
                      { "receipt_id" => "already-deleted", "generation" => 1,
                        "outcome" => "deleted" }
      assert_equal "deleted", result.fetch("outcomes").find {
        |outcome| outcome.fetch("receipt_id") == old.receipt_id
      }.fetch("outcome")
      assert_nil store.receipt(old.receipt_id)
    ensure
      Thread.current[:hive_command_operation_context] = nil
    end
  end

  def test_pruner_translates_storage_exhaustion_and_fences_lost_batch_ownership
    authority = Hive::CommandMaintenanceAuthority.new(
      principal: "owner", principal_source: "test", installation_owner: true
    )
    database = Object.new
    database.define_singleton_method(:read_only) { raise Errno::ENOSPC, "full" }
    error = assert_raises(Hive::CommandCapacityError) do
      Hive::CommandReceiptPruner.new(database: database, authority: authority).preview
    end
    assert_equal "command_prune_storage_unavailable", error.reason

    wrapped_full = Object.new
    wrapped_full.define_singleton_method(:transaction) do |**|
      begin
        raise SQLite3::FullException, "database or disk is full"
      rescue SQLite3::FullException
        raise Sequel::DatabaseError, "wrapped SQLITE_FULL"
      end
    end
    wrapped_pruner = Hive::CommandReceiptPruner.new(database: wrapped_full, authority: authority)
    with_replaced_singleton_method(
      wrapped_pruner, :resolve_namespace, ->(**) { "namespace" }
    ) do
      error = assert_raises(Hive::CommandCapacityError) do
        wrapped_pruner.prune(namespace_id: "namespace")
      end
      assert_equal "command_prune_storage_unavailable", error.reason
    end

    with_receipts do |project, database, store, owner|
      receipt = terminal_receipt(store, project, "unexpected-database-fault")
      broken = Object.new
      broken.define_singleton_method(:path) { database.path }
      broken.define_singleton_method(:read) { |&block| database.read(&block) }
      broken.define_singleton_method(:transaction) do |**|
        raise Sequel::DatabaseError, "constraint or schema failure"
      end
      assert_raises(Sequel::DatabaseError) do
        Hive::CommandReceiptPruner.new(database: broken, authority: owner)
          .prune(namespace_id: receipt.namespace_id)
      end
    end

    with_receipts do |_project, database, _store, owner|
      now = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc)
      database.transaction do |connection|
        connection[:command_maintenance_batches].insert(
          batch_id: "completed", namespace_id: nil, principal: "owner",
          principal_scope: "own", kind: "prune", state: "completed", generation: 1,
          fixed_cutoff: now, candidates_json: "[]", outcomes_json: "[]",
          created_at: now, updated_at: now, completed_at: now
        )
      end
      pruner = Hive::CommandReceiptPruner.new(database: database, authority: owner)
      assert_raises(Hive::CommandConflict) do
        pruner.send(
          :delete_candidates, "completed", "namespace",
          [ { receipt_id: "r", generation: 1 } ], Time.now.utc
        )
      end
    end
  end

  def test_preview_exposes_active_pin_and_unfinished_batch_identities
    with_receipts do |project, database, store, authority|
      claim = terminal_receipt(store, project, "identities")
      pin = store.acquire_pin(
        receipt_id: claim.receipt_id, principal: "owner", intent_id: "intent",
        intent_generation: 1, retry_horizon_expires_at: (Time.now.utc + 3600).iso8601,
        owner_process_start: "start", project_root: project
      )
      now = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc)
      database.transaction do |connection|
        connection[:command_maintenance_batches].insert(
          batch_id: "unfinished-identity", namespace_id: claim.namespace_id,
          principal: "owner", principal_scope: "own", kind: "prune",
          state: "executing", generation: 1, owner_host: "host", owner_pid: 1,
          owner_process_start: "start", fixed_cutoff: now,
          candidates_json: "[]", outcomes_json: "[]", created_at: now, updated_at: now
        )
      end
      preview = Hive::CommandReceiptPruner.new(database: database, authority: authority)
        .preview(namespace_id: claim.namespace_id)
      assert_equal pin.pin_id, preview.fetch("active_pins").first.fetch("pin_id")
      assert_equal "unfinished-identity",
                   preview.fetch("unfinished_batches").first.fetch("batch_id")
    end
  end

  def test_nonowner_preview_exposes_only_own_utilization_and_maintenance_identities
    with_receipts do |project, _database, store, _authority|
      own = store.reserve(
        project_root: project, key: "own-preview", command: "approve", target: "own",
        request: {}, principal: "caller"
      )
      store.reserve(
        project_root: project, key: "foreign-preview", command: "approve", target: "foreign",
        request: {}, principal: "foreign"
      )
      authority = Hive::CommandMaintenanceAuthority.new(
        principal: "caller", principal_source: "test"
      )

      preview = Hive::CommandReceiptPruner.new(
        database: store.database, authority: authority
      ).preview(project_root: project)

      assert_equal true, preview.fetch("keyed_intake_enabled")
      assert_equal 1, preview.dig("namespace_utilization", "nonterminal_count")
      assert_equal [ own.receipt_id ],
                   preview.fetch("nonterminal_receipts").map { |row| row.fetch("receipt_id") }
      assert_equal "ask_installation_owner", preview.fetch("installation_pressure")
      refute preview.key?("installation_utilization")
      refute_includes preview.to_json, "occupied_bytes"
      refute_includes preview.to_json, "page_count"
      refute_includes preview.to_json, "wal_bytes"
    end
  end

  def test_nonowner_cleanup_preserves_expired_foreign_administrative_batches
    with_receipts do |project, database, store, _authority|
      identity = terminal_receipt(store, project, "cleanup-namespace")
      old = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc - 31 * 86_400)
      database.transaction do |connection|
        %w[caller foreign].each do |principal|
          connection[:command_maintenance_batches].insert(
            batch_id: "expired-#{principal}", namespace_id: identity.namespace_id,
            principal: principal, principal_scope: "own", kind: "prune",
            state: "completed", generation: 2, fixed_cutoff: old,
            candidates_json: "[]", outcomes_json: "[]", created_at: old,
            updated_at: old, completed_at: old
          )
        end
      end
      authority = Hive::CommandMaintenanceAuthority.new(
        principal: "caller", principal_source: "test"
      )

      Hive::CommandReceiptPruner.new(database: database, authority: authority)
        .prune(project_root: project)

      database.read do |connection|
        assert_nil connection[:command_maintenance_batches][batch_id: "expired-caller"]
        assert connection[:command_maintenance_batches][batch_id: "expired-foreign"]
      end
    end
  end

  def test_completed_keyed_prune_batch_reconstructs_committed_outcomes
    with_receipts do |project, database, store, authority|
      Hive::ProjectIdentity.resolve(project_root: project, database: database, create: true)
      administrative = store.reserve(
        project_root: project, key: "completed-prune", command: "receipt", mode: "prune",
        target: "demo", request: { "confirm" => true }, principal: "owner",
        maintenance: true, execute: true
      )
      store.mark_unresolved(administrative, reason: "lost_result_commit")
      now = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc)
      candidate = {
        "receipt_id" => "already-deleted", "generation" => 2,
        "state" => "succeeded", "terminal_at" => now
      }
      outcome = candidate.merge("outcome" => "deleted")
      database.transaction do |connection|
        connection[:command_maintenance_batches].insert(
          batch_id: "completed-prune-batch", namespace_id: administrative.namespace_id,
          administrative_receipt_id: administrative.receipt_id, principal: "owner",
          principal_scope: "own", kind: "prune", state: "completed", generation: 3,
          fixed_cutoff: now, candidates_json: JSON.generate([ candidate ]),
          outcomes_json: JSON.generate([ outcome ]), created_at: now, updated_at: now,
          completed_at: now
        )
      end
      context = Hive::CommandOperation::Context.new(
        receipt_id: administrative.receipt_id, effect_id: "effect", principal: "owner",
        principal_source: "test", ordinal: 0, receipt_generation: administrative.generation,
        request_fingerprint: administrative.request_fingerprint,
        transport_request_id: "command-dispatch:v1:#{'e' * 64}", retry_horizon_expires_at: nil
      )
      Thread.current[:hive_command_operation_context] = context

      result = Hive::CommandReceiptPruner.new(database: database, authority: authority)
        .prune(project_root: project)

      assert_equal "completed-prune-batch", result.fetch("batch_id")
      assert_equal [ outcome ], result.fetch("outcomes")
    ensure
      Thread.current[:hive_command_operation_context] = nil
    end
  end

  def test_abandonment_rejects_a_changed_administrative_receipt
    with_receipts do |project, database, store, authority|
      receipt = terminal_receipt(store, project, "administrative")
      now = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc)
      database.transaction do |connection|
        connection[:command_maintenance_batches].insert(
          batch_id: "changed-admin", namespace_id: receipt.namespace_id,
          administrative_receipt_id: receipt.receipt_id, principal: "owner",
          principal_scope: "own", kind: "prune", state: "executing", generation: 1,
          owner_host: Socket.gethostname, owner_pid: 424_242,
          owner_process_start: "dead-start", fixed_cutoff: now,
          candidates_json: "[]", outcomes_json: "[]", created_at: now, updated_at: now
        )
      end
      maintenance = Hive::CommandReceiptMaintenance.new(
        database: database, authority: authority,
        alive: ->(*) { false }, ownership: ->(*) { :dead }
      )
      assert_raises(Hive::CommandConflict) do
        maintenance.abandon_batch(
          "changed-admin", expected_generation: 1, reason: "dead", confirm: true
        )
      end
    end
  end

  def test_abandonment_reauthorizes_the_administrative_receipt_principal
    with_receipts do |project, database, store, _authority|
      Hive::ProjectIdentity.resolve(project_root: project, database: database, create: true)
      administrative = store.reserve(
        project_root: project, key: "foreign-administrative", command: "receipt",
        mode: "prune", target: "demo", request: {}, principal: "other",
        maintenance: true, execute: true, owner_process_start: "dead-start"
      )
      store.mark_unresolved(administrative, reason: "lost")
      now = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc)
      database.transaction do |connection|
        connection[:command_maintenance_batches].insert(
          batch_id: "foreign-admin", namespace_id: administrative.namespace_id,
          administrative_receipt_id: administrative.receipt_id, principal: "owner",
          principal_scope: "own", kind: "prune", state: "executing", generation: 1,
          owner_host: Socket.gethostname, owner_pid: 424_242,
          owner_process_start: "dead-start", fixed_cutoff: now,
          candidates_json: "[]", outcomes_json: "[]", created_at: now, updated_at: now
        )
      end
      authority = Hive::CommandMaintenanceAuthority.new(
        principal: "owner", principal_source: "test"
      )
      maintenance = Hive::CommandReceiptMaintenance.new(
        database: database, authority: authority,
        alive: ->(*) { false }, ownership: ->(*) { :dead }
      )

      assert_raises(Hive::ConfigError) do
        maintenance.abandon_batch(
          "foreign-admin", expected_generation: 1, reason: "owner died", confirm: true
        )
      end
      assert_equal "unresolved", store.receipt(administrative.receipt_id).fetch(:state)
    end
  end

  def test_abandonment_preserves_existing_effect_evidence
    with_receipts do |project, database, store, authority|
      Hive::ProjectIdentity.resolve(project_root: project, database: database, create: true)
      claim = store.reserve(
        project_root: project, key: "abandon-evidence", command: "receipt", mode: "prune",
        target: "demo", request: {}, principal: "owner", maintenance: true,
        execute: true, owner_process_start: "dead-start"
      )
      effect = store.prepare_effect(
        claim, ordinal: 0, kind: "receipt:prune", identity: { "target" => "demo" }
      )
      store.update_effect(
        claim, effect_id: effect.fetch(:effect_id), from: "prepared", to: "submitted",
        evidence: { "provider_receipt" => "retain-me" }
      )
      store.mark_unresolved(claim, reason: "lost")
      now = Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc)
      database.transaction do |connection|
        connection[:command_maintenance_batches].insert(
          batch_id: "abandon-evidence-batch", namespace_id: claim.namespace_id,
          administrative_receipt_id: claim.receipt_id, principal: "owner",
          principal_scope: "own", kind: "prune", state: "executing", generation: 1,
          owner_host: Socket.gethostname, owner_pid: 424_242,
          owner_process_start: "dead-start", fixed_cutoff: now,
          candidates_json: "[]", outcomes_json: "[]", created_at: now, updated_at: now
        )
      end
      maintenance = Hive::CommandReceiptMaintenance.new(
        database: database, authority: authority,
        alive: ->(*) { false }, ownership: ->(*) { :reused }
      )

      maintenance.abandon_batch(
        "abandon-evidence-batch", expected_generation: 1,
        reason: "owner died", confirm: true
      )

      evidence = database.read do |connection|
        row = connection[:command_effects][effect_id: effect.fetch(:effect_id)]
        Hive::RuntimeControlPlane::Codec.load_json(row.fetch(:evidence_json))
      end
      assert_equal "retain-me", evidence.fetch("provider_receipt")
      assert_equal true, evidence.fetch("batch_abandoned")
      assert_equal "abandon-evidence-batch", evidence.fetch("batch_id")
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
