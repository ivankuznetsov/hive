# frozen_string_literal: true

require "digest"
require "hive/runtime_control_plane/codec"

module Hive
  module RuntimeControlPlane
    module CommandSchema
      VERSION = 2
      EXPECTED_SCHEMA_SHA256 = "cf2d9423475a3117089f9c92dff976395671c7712995c8c1c446614e9599f8cb".freeze
      TABLE_NAMES = %w[
        command_capacity
        command_installation_capacity
        command_dispatch_contexts
        command_effects
        command_maintenance_audit
        command_maintenance_batches
        command_namespaces
        command_project_enrollments
        command_receipt_pins
        command_receipts
        command_schema_versions
        command_successor_allocations
      ].freeze
      TRIGGER_NAMES = %w[
        command_capacity_installation_delete
        command_capacity_installation_insert
        command_capacity_installation_update
      ].freeze
      INDEX_NAMES = %w[
        command_effects_ordinal_uidx
        command_dispatch_contexts_receipt_ordinal_uidx
        command_maintenance_audit_receipt_idx
        command_maintenance_audit_batch_idx
        command_maintenance_batches_completed_idx
        command_maintenance_batches_receipt_idx
        command_maintenance_batches_unfinished_uidx
        command_receipt_pins_active_idx
        command_receipt_pins_intent_uidx
        command_receipts_key_uidx
        command_receipts_owner_reclamation_idx
        command_receipts_terminal_idx
        command_namespaces_git_common_uidx
        command_successor_allocations_cycle_uidx
        command_successor_allocations_predecessor_idx
        command_successor_allocations_successor_idx
      ].freeze
      OBJECT_NAMES = (TABLE_NAMES + INDEX_NAMES + TRIGGER_NAMES).freeze

      module_function

      def extension_object?(name)
        OBJECT_NAMES.include?(name.to_s)
      end

      def object_rows(database)
        database[:sqlite_master].where(type: %w[table index trigger], name: OBJECT_NAMES)
          .exclude(Sequel.like(:name, "sqlite_%"))
          .order(:type, :name).select_map([ :type, :name, :tbl_name, :sql ])
      end

      def checksum(database)
        Digest::SHA256.hexdigest(Codec.dump_json(object_rows(database)))
      end

      def absent?(database)
        names = database[:sqlite_master].where(type: %w[table index trigger])
          .select_map(:name).map(&:to_s)
        (names & OBJECT_NAMES).empty?
      end

      def exact?(database)
        rows = object_rows(database)
        rows.map { |row| row[1].to_s }.sort == OBJECT_NAMES.sort &&
          checksum(database) == EXPECTED_SCHEMA_SHA256 &&
          version_ledger_exact?(database)
      rescue Sequel::Error
        false
      end

      def version_ledger_exact?(database)
        rows = database[:command_schema_versions].order(:version).all
        rows.length == 1 && rows.first.fetch(:version) == VERSION &&
          rows.first.fetch(:schema_sha256) == EXPECTED_SCHEMA_SHA256
      end

      def installed?(database)
        database.read { |connection| exact?(connection) }
      end
    end
  end
end
