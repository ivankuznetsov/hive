# frozen_string_literal: true

require "test_helper"
require "hive/command_operation"
require "hive/runtime_control_plane/command_schema_installation"

class CommandOperationTest < Minitest::Test
  TEST_PACKAGE = {
    version: "0.0.0-test", location: "https://example.invalid/compat.gem", sha256: "d" * 64
  }.freeze

  def test_success_is_durable_before_output_and_identical_retry_does_not_execute
    with_operation do |operation, store|
      effects = 0
      first = capture_io do
        operation.call do
          effects += 1
          context = Hive::CommandOperation.current_context
          refute_nil context
          assert_match(/\Acommand-dispatch:v1:[0-9a-f]{64}\z/, context.transport_request_id)
          puts JSON.generate("schema" => "example", "ok" => true, "value" => 7)
        end
      end.first
      payload = JSON.parse(first)
      receipt = store.receipt(payload.dig("command_receipt", "id"))
      assert_equal "succeeded", receipt.fetch(:state)
      refute_nil receipt.fetch(:owner_process_start)
      effect = store.database.read do |db|
        db[:command_effects][receipt_id: receipt.fetch(:receipt_id)]
      end
      assert_equal "applied", effect.fetch(:state)
      assert_nil Hive::CommandOperation.current_context

      second = capture_io do
        operation.call { flunk "replay must not execute the command body" }
      end.first

      assert_equal payload, JSON.parse(second)
      assert_equal 1, effects
    end
  end

  def test_exception_after_ownership_withholds_success_and_leaves_unresolved
    with_operation(key: "ambiguous") do |operation, store|
      assert_raises(Hive::Error) do
        capture_io do
          operation.call do
            puts JSON.generate("ok" => true)
            raise Hive::Error, "lost acknowledgement"
          end
        end
      end

      row = store.database.read { |db| db[:command_receipts].first(key_digest: Digest::SHA256.hexdigest("ambiguous")) }
      assert_equal "unresolved", row.fetch(:state)
    end
  end

  def test_structured_failed_replay_emits_saved_payload_and_exits_with_saved_status
    with_operation do |_operation, store, project|
      structured = Hive::CommandOperation.new(
        key: "failed", command: "approve", target: "task", request: { from: "3-plan" },
        project_root: project, principal: "owner", json: true, structured: true, store: store
      )
      assert_raises(Hive::UsageError) do
        structured.call { raise Hive::UsageError, "invalid transition" }
      end

      output, = capture_io do
        exit_error = assert_raises(SystemExit) { structured.call { flunk "failed replay executed" } }
        assert_equal Hive::ExitCodes::USAGE, exit_error.status
      end
      payload = JSON.parse(output)
      assert_equal false, payload.fetch("ok")
      assert_equal Hive::ExitCodes::USAGE, payload.fetch("exit_code")
    end
  end

  private

  def with_operation(key: "stable")
    Dir.mktmpdir do |dir|
      project = File.join(dir, "project")
      FileUtils.mkdir_p(File.join(project, ".hive-state"))
      system("git", "init", "--quiet", project, exception: true)
      File.write(
        File.join(project, ".hive-state", "config.yml"),
        { "command_receipts" => { "keyed_intake_enabled" => true } }.to_yaml
      )
      state = File.join(dir, "state")
      FileUtils.mkdir_p(state, mode: 0o700)
      database = Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(state)
      ).migrate!
      Hive::RuntimeControlPlane::CommandSchemaInstallation.install!(
        database: database, package_coordinates: TEST_PACKAGE
      )
      store = Hive::CommandReceiptStore.new(database: database)
      operation = Hive::CommandOperation.new(
        key: key, command: "approve", target: "task", request: { from: "3-plan" },
        project_root: project, principal: "owner", json: true, store: store
      )
      yield operation, store, project
    ensure
      database&.disconnect
    end
  end
end
