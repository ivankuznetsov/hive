# frozen_string_literal: true

require "test_helper"
require "hive/commands/new"

class NewCommandReceiptTest < Minitest::Test
  include HiveTestHelper

  def test_failure_envelope_contains_only_idempotency_key_digest
    raw_key = "operator-secret-key"
    command = Hive::Commands::New.new("demo", "idea", idempotency_key: raw_key, json: true)

    extras = command.envelope_extras_for(Hive::UsageError.new("bad"))

    refute_includes JSON.generate(extras), raw_key
    assert_equal Digest::SHA256.hexdigest(raw_key), extras.fetch("idempotency_key_sha256")
  end

  def test_keyed_call_fails_closed_when_receipt_storage_cannot_be_inspected
    database = Object.new
    database.define_singleton_method(:read) { raise Sequel::DatabaseLockTimeout, "busy" }
    store = Struct.new(:database).new(database)
    command = Hive::Commands::New.new("demo", "idea", idempotency_key: "stable")
    command.define_singleton_method(:receipt_store) { store }
    command.define_singleton_method(:perform_call!) { flunk "legacy task capture executed" }

    error = assert_raises(Hive::ConcurrentRunError) { command.call! }

    assert_includes error.message, "command receipt storage is busy"
  end

  def test_keyed_call_refuses_a_real_base_only_runtime_before_task_creation
    with_tmp_dir do |root|
      activate_test_control_plane(root)
      database = Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(root)
      ).open!
      store = Hive::CommandReceiptStore.new(database: database)
      command = Hive::Commands::New.new(
        "demo", "idea", idempotency_key: "stable", command_receipt_store: store
      )
      command.define_singleton_method(:perform_call!) { flunk "legacy task capture executed" }

      error = assert_raises(Hive::ConfigError) { command.call! }

      assert_includes error.message, "command receipts are not installed"
      database.disconnect
    end
  end

  def test_keyed_call_uses_command_operation_when_receipt_storage_is_available
    store = Struct.new(:database).new(Object.new)
    operation = Object.new
    operation.define_singleton_method(:call) { |&block| block.call }
    command = Hive::Commands::New.new(
      "demo", "idea", idempotency_key: "stable", command_receipt_store: store
    )
    command.define_singleton_method(:command_operation) { operation }
    command.define_singleton_method(:perform_call!) do
      raise "command operation context was not active" unless @inside_command_operation

      "created"
    end

    assert_equal "created", command.call!
    refute command.instance_variable_get(:@inside_command_operation)
  end

  def test_idempotent_existing_task_text_includes_the_next_action
    task = Struct.new(:slug, :stage_index, :stage_name, :folder, :state_file).new(
      "task", 1, "inbox", "/tmp/task", "/tmp/task/task.md"
    )
    action = Struct.new(:key, :command, :allowed_outcomes).new(
      "run", "hive brainstorm task", [ "complete" ]
    )
    workflow = Struct.new(:id).new(:coding)
    command = Hive::Commands::New.new("demo", "idea", idempotency_key: "stable")

    with_replaced_singleton_method(Hive::Task, :new, ->(_folder) { task }) do
      with_replaced_singleton_method(Hive::TaskAction, :for, ->(*_args) { action }) do
        output, = capture_io do
          command.send(:emit_task_result, task.folder, workflow, created: false)
        end

        assert_includes output, "idempotent task already exists at /tmp/task"
        assert_includes output, "next: hive brainstorm task"
      end
    end
  end
end
