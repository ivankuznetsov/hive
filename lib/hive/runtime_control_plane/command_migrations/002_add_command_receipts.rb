# frozen_string_literal: true

require "sequel"

module Hive
  module RuntimeControlPlane
    module CommandMigrations
      # Additive receipt extension. This deliberately does not use Sequel's
      # IntegerMigrator: base schema_info remains version 1 so a compatible
      # prior runtime can continue to operate while ignoring these objects.
      module AddCommandReceipts002
        VERSION = 2

        module_function

        def apply(database, checksum:)
          database.create_table(:command_schema_versions) do
            Integer :version, primary_key: true, null: false
            String :schema_sha256, null: false
            String :installed_at, null: false
            check Sequel.lit("version > 0")
            check Sequel.lit("length(schema_sha256) = 64")
          end

          database.create_table(:command_namespaces) do
            String :namespace_id, primary_key: true, null: false
            String :installation_id, null: false
            String :git_common_dir_digest, null: false
            String :project_label
            String :enrollment_state, null: false
            Integer :enrollment_generation, null: false, default: 0
            Integer :keyed_intake_enabled, null: false, default: 0
            Integer :policy_revision, null: false, default: 0
            Integer :nonterminal_limit, null: false, default: 1_000
            Integer :concurrency_limit, null: false, default: 32
            Integer :byte_admission_limit, null: false, default: 67_108_864
            String :reclamation_cursor_updated_at
            String :reclamation_cursor_receipt_id
            String :created_at, null: false
            String :activated_at
            String :updated_at, null: false
            check Sequel.lit("enrollment_state IN ('pending', 'active')")
            check Sequel.lit(
              "enrollment_generation >= 0 AND policy_revision >= 0 AND " \
              "nonterminal_limit > 0 AND concurrency_limit > 0 AND byte_admission_limit > 0"
            )
            check Sequel.lit("keyed_intake_enabled IN (0, 1)")
          end
          database.add_index(:command_namespaces, [ :installation_id, :git_common_dir_digest ],
                             unique: true, name: :command_namespaces_git_common_uidx)

          database.create_table(:command_receipts) do
            String :receipt_id, primary_key: true, null: false
            foreign_key :namespace_id, :command_namespaces, type: String,
                        key: :namespace_id, null: false, on_delete: :restrict, on_update: :restrict
            String :key_digest, null: false
            String :principal, null: false
            String :principal_source, null: false
            String :command, null: false
            String :mode
            String :original_target, null: false
            String :request_fingerprint, null: false
            String :frozen_request_json, text: true, null: false
            String :state, null: false
            Integer :generation, null: false, default: 1
            String :owner_host
            Integer :owner_pid
            String :owner_process_start
            String :owner_token
            String :result_json, text: true
            String :result_digest
            Integer :result_status
            String :typed_reason
            Integer :retry_eligible, null: false, default: 0
            String :created_at, null: false
            String :updated_at, null: false
            String :terminal_at
            check Sequel.lit(
              "state IN ('prepared','executing','unresolved','succeeded','failed','settled','aborted')"
            )
            check Sequel.lit("generation > 0")
            check Sequel.lit("owner_pid IS NULL OR owner_pid > 0")
            check Sequel.lit("retry_eligible IN (0, 1)")
          end
          database.add_index(:command_receipts, [ :namespace_id, :key_digest ],
                             unique: true, name: :command_receipts_key_uidx)
          database.add_index(:command_receipts, [ :namespace_id, :state, :terminal_at, :receipt_id ],
                             name: :command_receipts_terminal_idx)
          database.add_index(:command_receipts, [ :state, :updated_at, :receipt_id ],
                             name: :command_receipts_owner_reclamation_idx)

          database.create_table(:command_effects) do
            String :effect_id, primary_key: true, null: false
            foreign_key :receipt_id, :command_receipts, type: String, key: :receipt_id,
                        null: false, on_delete: :restrict, on_update: :restrict
            Integer :ordinal, null: false
            String :effect_kind, null: false
            String :identity_json, text: true, null: false
            String :state, null: false
            String :evidence_json, text: true
            String :created_at, null: false
            String :updated_at, null: false
            check Sequel.lit("ordinal >= 0")
            check Sequel.lit("state IN ('prepared','submitted','applied','not_applied','unknown')")
          end
          database.add_index(:command_effects, [ :receipt_id, :ordinal ],
                             unique: true, name: :command_effects_ordinal_uidx)

          database.create_table(:command_receipt_pins) do
            String :pin_id, primary_key: true, null: false
            foreign_key :receipt_id, :command_receipts, type: String, key: :receipt_id,
                        null: false, on_delete: :restrict, on_update: :restrict
            String :principal, null: false
            String :intent_id, null: false
            Integer :intent_generation, null: false
            Integer :generation, null: false, default: 1
            String :owner_host
            Integer :owner_pid
            String :owner_process_start
            String :lifecycle_status, null: false
            String :retry_horizon_expires_at
            String :created_at, null: false
            String :updated_at, null: false
            String :released_at
            check Sequel.lit("intent_generation >= 0 AND generation > 0")
            check Sequel.lit("owner_pid IS NULL OR owner_pid > 0")
            check Sequel.lit("lifecycle_status IN ('active','closed','force_released')")
          end
          database.add_index(
            :command_receipt_pins, [ :receipt_id, :principal, :intent_id, :intent_generation ],
            unique: true, name: :command_receipt_pins_intent_uidx
          )
          database.add_index(:command_receipt_pins, [ :lifecycle_status, :receipt_id ],
                             name: :command_receipt_pins_active_idx)

          database.create_table(:command_maintenance_batches) do
            String :batch_id, primary_key: true, null: false
            String :namespace_id
            String :administrative_receipt_id
            String :principal, null: false
            String :principal_scope, null: false
            String :kind, null: false
            String :state, null: false
            Integer :generation, null: false, default: 1
            String :owner_host
            Integer :owner_pid
            String :owner_process_start
            String :fixed_cutoff
            String :candidates_json, text: true, null: false, default: "[]"
            String :outcomes_json, text: true, null: false, default: "[]"
            String :created_at, null: false
            String :updated_at, null: false
            String :completed_at
            check Sequel.lit("kind IN ('prune')")
            check Sequel.lit("state IN ('prepared','executing','completed','abandoned')")
            check Sequel.lit("generation > 0")
          end
          database.add_index(:command_maintenance_batches, [ :kind ],
                             unique: true, where: Sequel.lit("state IN ('prepared','executing')"),
                             name: :command_maintenance_batches_unfinished_uidx)
          database.add_index(:command_maintenance_batches, :administrative_receipt_id,
                             name: :command_maintenance_batches_receipt_idx)
          database.add_index(:command_maintenance_batches, [ :state, :completed_at, :batch_id ],
                             name: :command_maintenance_batches_completed_idx)

          database.create_table(:command_maintenance_audit) do
            String :audit_id, primary_key: true, null: false
            String :receipt_id
            String :batch_id
            String :pin_id
            String :namespace_id
            String :acting_principal, null: false
            String :principal_source, null: false
            String :authority_basis, null: false
            String :peer_address
            String :action, null: false
            String :affected_principal
            String :reason
            String :evidence_json, text: true, null: false, default: "{}"
            String :created_at, null: false
            check Sequel.lit(
              "receipt_id IS NOT NULL OR batch_id IS NOT NULL OR pin_id IS NOT NULL OR namespace_id IS NOT NULL"
            )
          end
          database.add_index(:command_maintenance_audit, [ :receipt_id, :created_at ],
                             name: :command_maintenance_audit_receipt_idx)
          database.add_index(:command_maintenance_audit, [ :batch_id, :created_at ],
                             name: :command_maintenance_audit_batch_idx)

          database.create_table(:command_capacity) do
            foreign_key :namespace_id, :command_namespaces, type: String,
                        key: :namespace_id, primary_key: true, null: false,
                        on_delete: :restrict, on_update: :restrict
            Integer :nonterminal_count, null: false, default: 0
            Integer :executing_count, null: false, default: 0
            Integer :logical_bytes, null: false, default: 0
            Integer :revision, null: false, default: 0
            String :updated_at, null: false
            check Sequel.lit(
              "nonterminal_count >= 0 AND executing_count >= 0 AND " \
              "executing_count <= nonterminal_count AND logical_bytes >= 0 AND revision >= 0"
            )
          end

          database.create_table(:command_successor_allocations) do
            String :allocation_id, primary_key: true, null: false
            foreign_key :namespace_id, :command_namespaces, type: String,
                        key: :namespace_id, null: false, on_delete: :restrict, on_update: :restrict
            String :principal, null: false
            String :intent_id, null: false
            Integer :intent_version, null: false
            String :delivery_cycle_id, null: false
            foreign_key :predecessor_receipt_id, :command_receipts, type: String,
                        key: :receipt_id, null: false, on_delete: :restrict, on_update: :restrict
            String :successor_key_identity, null: false
            foreign_key :successor_receipt_id, :command_receipts, type: String,
                        key: :receipt_id, null: true, on_delete: :restrict, on_update: :restrict
            Integer :successor_ordinal, null: false
            String :request_fingerprint, null: false
            Integer :allocation_version, null: false
            String :created_at, null: false
            check Sequel.lit(
              "intent_version >= 0 AND successor_ordinal > 0 AND allocation_version > 0"
            )
          end
          database.add_index(
            :command_successor_allocations,
            [ :namespace_id, :principal, :intent_id, :intent_version, :delivery_cycle_id ],
            unique: true, name: :command_successor_allocations_cycle_uidx
          )
          database.add_index(
            :command_successor_allocations, :predecessor_receipt_id,
            name: :command_successor_allocations_predecessor_idx
          )
          database.add_index(
            :command_successor_allocations, :successor_receipt_id,
            name: :command_successor_allocations_successor_idx
          )

          database.create_table(:command_dispatch_contexts) do
            String :request_id, primary_key: true, null: false
            foreign_key :receipt_id, :command_receipts, type: String, key: :receipt_id,
                        null: false, on_delete: :restrict, on_update: :restrict
            String :effect_id, null: false
            String :principal, null: false
            String :principal_source, null: false
            Integer :ordinal, null: false
            Integer :receipt_generation, null: false
            String :request_fingerprint, null: false
            String :source_identity
            String :retry_horizon_expires_at
            String :created_at, null: false
            check Sequel.lit("ordinal >= 0 AND receipt_generation > 0")
          end
          database.add_index(:command_dispatch_contexts, [ :receipt_id, :ordinal ],
                             unique: true, name: :command_dispatch_contexts_receipt_ordinal_uidx)

          database.create_table(:command_project_enrollments) do
            String :git_common_dir_digest, primary_key: true, null: false
            foreign_key :namespace_id, :command_namespaces, type: String,
                        key: :namespace_id, null: false, on_delete: :restrict, on_update: :restrict
            String :installation_id, null: false
            Integer :generation, null: false, default: 0
            String :state, null: false
            String :previous_identity
            String :audit_context_json, text: true
            String :created_at, null: false
            String :updated_at, null: false
            check Sequel.lit("generation >= 0")
            check Sequel.lit("state IN ('pending','active')")
          end

          database[:command_schema_versions].insert(
            version: VERSION,
            schema_sha256: checksum,
            installed_at: Hive::RuntimeControlPlane::Codec.dump_time(Time.now.utc)
          )
        end
      end
    end
  end
end
