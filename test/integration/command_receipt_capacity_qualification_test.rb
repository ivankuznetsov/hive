# frozen_string_literal: true

require "test_helper"
require "hive/command_receipt_store"
require "hive/command_receipt_pruner"
require "hive/command_maintenance_authority"
require "hive/runtime_control_plane/command_schema_installation"
require "open3"
require "rbconfig"

class CommandReceiptCapacityQualificationTest < Minitest::Test
  include HiveTestHelper

  TEST_PACKAGE = {
    version: "0.0.0-test", location: "https://example.invalid/compat.gem", sha256: "f" * 64
  }.freeze

  def test_measurement_script_emits_reproducible_qualification_json
    script = File.expand_path("../../script/measure_command_receipts.rb", __dir__)
    output, error, status = Open3.capture3(
      { "HIVE_RECEIPT_MEASUREMENT_SAMPLES" => "2" }, RbConfig.ruby, script
    )

    assert status.success?, error
    payload = JSON.parse(output)
    assert_equal "hive-command-receipt-measurement", payload.fetch("schema")
    assert_equal 2, payload.dig("settlement", "samples")
    assert_equal 100, payload.dig("prune_batch", "candidate_limit")
    assert_operator payload.dig("maximum_finalization", "payload_bytes"), :>, 0
  end

  def test_real_sqlite_page_exhaustion_never_reports_success_and_finalization_recovers
    with_store do |project, database, store|
      claim = store.reserve(
        project_root: project, key: "physical-full", command: "approve",
        target: "task", request: {}, principal: "owner", execute: true,
        owner_process_start: "test-owner"
      )
      effect = store.prepare_effect(
        claim, ordinal: 0, kind: "approve:default", identity: { "target" => "task" }
      )
      payload = { "schema" => "hive-approve", "ok" => true, "value" => "x" * (220 * 1024) }
      result = {
        "format" => "json", "payload" => payload,
        "expanded_sha256" => Digest::SHA256.hexdigest(
          Hive::RuntimeControlPlane::Codec.dump_json(payload)
        )
      }
      store.complete_effect(claim, effect_id: effect.fetch(:effect_id), result: result, status: 0)
      current_pages = database.read do |db|
        pages = Integer(db.fetch("PRAGMA page_count").first.values.first)
        db.run("PRAGMA max_page_count = #{pages}")
        pages
      end

      error = assert_raises(Sequel::DatabaseError, SQLite3::Exception) do
        store.succeed(claim, result: result, status: 0)
      end
      assert_match(/full|max_page_count/i, error.message)
      assert_equal "executing", store.receipt(claim.receipt_id).fetch(:state)
      assert_nil store.receipt(claim.receipt_id)[:result_json]

      database.read { |db| db.run("PRAGMA max_page_count = #{current_pages + 1_000}") }
      replay = store.succeed(claim, result: result, status: 0)
      assert_equal :replay, replay.disposition
      assert_equal "succeeded", store.receipt(claim.receipt_id).fetch(:state)
      assert_equal result, replay.result
    end
  end

  def test_prune_storage_failure_preserves_rows_and_reruns_after_availability_returns
    with_store do |project, database, store|
      terminal = store.reserve(
        project_root: project, key: "old-terminal", command: "approve",
        target: "old", request: {}, principal: "owner"
      )
      terminal = store.succeed(
        terminal, result: { "format" => "text", "text" => "done\n" }, status: 0
      )
      unresolved = store.reserve(
        project_root: project, key: "unresolved", command: "approve",
        target: "unknown", request: {}, principal: "owner", execute: true,
        owner_process_start: "test-owner"
      )
      store.mark_unresolved(unresolved, reason: "unknown")
      database.transaction do |db|
        db[:command_receipts].where(receipt_id: terminal.receipt_id).update(
          terminal_at: Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc - 31 * 86_400)
        )
      end
      authority = Hive::CommandMaintenanceAuthority.new(
        principal: "owner", principal_source: "test", installation_owner: true
      )
      administrative = store.reserve(
        project_root: project, key: "prune-administration", command: "receipt",
        mode: "prune", target: "project", request: { "confirm" => true },
        principal: "owner", maintenance: true, execute: true,
        owner_process_start: "test-owner"
      )
      context = Hive::CommandOperation::Context.new(
        receipt_id: administrative.receipt_id, effect_id: "effect", principal: "owner",
        principal_source: "test", ordinal: 0,
        receipt_generation: administrative.generation,
        request_fingerprint: administrative.request_fingerprint,
        transport_request_id: "command-dispatch:v1:#{'a' * 64}",
        retry_horizon_expires_at: "2030-01-01T00:00:00Z"
      )
      transaction_calls = 0
      unavailable = Object.new
      unavailable.define_singleton_method(:path) { database.path }
      unavailable.define_singleton_method(:read) { |&block| database.read(&block) }
      unavailable.define_singleton_method(:transaction) do |**options, &block|
        transaction_calls += 1
        if transaction_calls == 2
          raise Errno::ENOSPC, "qualification full"
        end
        database.transaction(**options, &block)
      end
      Thread.current[:hive_command_operation_context] = context
      error = assert_raises(Hive::CommandCapacityError) do
        Hive::CommandReceiptPruner.new(database: unavailable, authority: authority)
          .prune(namespace_id: terminal.namespace_id)
      end
      assert_equal "command_prune_storage_unavailable", error.reason
      batch = database.read { |db| db[:command_maintenance_batches].first }
      assert_equal "executing", batch.fetch(:state)
      assert store.receipt(terminal.receipt_id)
      assert_equal "unresolved", store.receipt(unresolved.receipt_id).fetch(:state)

      result = Hive::CommandReceiptPruner.new(
        database: database, authority: authority
      ).prune(namespace_id: terminal.namespace_id)
      assert_equal "deleted", result.fetch("outcomes").first.fetch("outcome")
      assert_nil store.receipt(terminal.receipt_id)
      assert_equal "unresolved", store.receipt(unresolved.receipt_id).fetch(:state)
    ensure
      Thread.current[:hive_command_operation_context] = nil
    end
  end

  private

  def with_store
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
      yield project, database, Hive::CommandReceiptStore.new(database: database)
    ensure
      database&.disconnect
    end
  end
end
