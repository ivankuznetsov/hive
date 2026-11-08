# frozen_string_literal: true

require "hive/command_receipt_capacity"

module Hive
  # Shared writes for the command-receipt byte ledger and maintenance audit.
  module CommandReceiptLedger
    module_function

    def capacity_counted?(row)
      Hive::CommandReceiptCapacity.counts_receipt?(row)
    end

    def add_logical_bytes!(connection, namespace_id, delta, now:)
      return if delta.zero?

      expression = if delta.positive?
        Sequel[:logical_bytes] + delta
      else
        Sequel.function(:max, Sequel[:logical_bytes] + delta, 0)
      end
      connection[:command_capacity].where(namespace_id: namespace_id).update(
        logical_bytes: expression, revision: Sequel[:revision] + 1, updated_at: now
      )
    end

    def insert_audit!(connection, attributes)
      connection[:command_maintenance_audit].insert(attributes)
    end
  end
end
