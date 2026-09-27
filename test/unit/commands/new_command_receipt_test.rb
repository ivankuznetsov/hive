# frozen_string_literal: true

require "test_helper"
require "hive/commands/new"

class NewCommandReceiptTest < Minitest::Test
  include HiveTestHelper

  def test_keyed_call_fails_closed_when_receipt_storage_cannot_be_inspected
    database = Object.new
    database.define_singleton_method(:read) { raise Sequel::DatabaseLockTimeout, "busy" }
    store = Struct.new(:database).new(database)
    command = Hive::Commands::New.new("demo", "idea", idempotency_key: "stable")
    command.define_singleton_method(:receipt_store) { store }
    command.define_singleton_method(:perform_call!) { flunk "legacy task capture executed" }

    error = assert_raises(Hive::ConfigError) { command.call! }

    assert_includes error.message, "cannot verify command receipt storage"
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
end
