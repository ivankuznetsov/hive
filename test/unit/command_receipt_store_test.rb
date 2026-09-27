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
        alive: ->(pid) { pid != 41_001 }, ownership: ->(*) { :verified },
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
