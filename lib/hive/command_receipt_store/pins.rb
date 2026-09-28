# frozen_string_literal: true

module Hive
  class CommandReceiptStore
    module Pins
      def acquire_pin(receipt_id:, principal:, intent_id:, intent_generation:,
                      retry_horizon_expires_at:, owner_host: Socket.gethostname,
                      owner_pid: Process.pid, owner_process_start: nil, project_root: nil)
        owner_process_start ||= process_start(owner_pid)
        horizon = parse_retry_horizon!(retry_horizon_expires_at)
        intent_generation = Integer(intent_generation)
        raise Hive::UsageError, "intent generation must be nonnegative" if intent_generation.negative?
        now_time = @clock.call.utc
        now = Hive::RuntimeControlPlane::Codec.dump_time(now_time)
        receipt_snapshot, existing = database.read do |connection|
          [
            connection[:command_receipts][receipt_id: receipt_id],
            connection[:command_receipt_pins][
              receipt_id: receipt_id, principal: principal.to_s,
              intent_id: intent_id.to_s, intent_generation: intent_generation
            ]
          ]
        end
        unless receipt_snapshot
          raise Hive::CommandUnresolved.new(
            reason: "command_pin_horizon_elapsed",
            message: "receipt replay protection is no longer available; close the intent and " \
                     "begin a new acquisition identity with a fresh future horizon"
          )
        end
        raise Hive::CommandConflict unless receipt_snapshot.fetch(:principal) == principal.to_s
        if !existing && horizon <= now_time
          raise Hive::UsageError, "a new receipt pin requires a future retry horizon"
        end
        policy = existing ? nil : admission_policy!(project_root, receipt_id: receipt_id)
        persist_namespace_policy!(receipt_snapshot.fetch(:namespace_id), policy) if
          policy && !policy.keyed_intake_enabled
        row = database.transaction do |connection|
          receipt = connection[:command_receipts][receipt_id: receipt_id]
          unless receipt
            raise Hive::CommandUnresolved.new(
              reason: "command_pin_horizon_elapsed",
              message: "receipt replay protection is no longer available; close the intent and " \
                       "begin a new acquisition identity with a fresh future horizon"
            )
          end
          raise Hive::CommandConflict unless receipt.fetch(:principal) == principal.to_s
          existing = connection[:command_receipt_pins][
            receipt_id: receipt_id, principal: principal.to_s,
            intent_id: intent_id.to_s, intent_generation: intent_generation
          ]
          if existing
            unless existing[:retry_horizon_expires_at] == Hive::RuntimeControlPlane::Codec.dump_time(horizon)
              raise Hive::CommandConflict, "pin retry horizon cannot be changed for an acquisition identity"
            end
            if existing.fetch(:lifecycle_status) != "active"
              raise Hive::CommandUnresolved.new(
                reason: "command_pin_horizon_elapsed",
                message: "receipt pin was already released; close the intent and begin a new " \
                         "acquisition identity with a fresh future horizon"
              )
            end
            next existing
          end
          raise Hive::CommandConflict, "receipt pin admission changed" unless policy
          intake_disabled! unless policy.keyed_intake_enabled
          capacity = Hive::CommandReceiptCapacity.new(database: database, policy: policy)
          capacity.admit_bytes!(
            connection, namespace_id: receipt.fetch(:namespace_id), request_bytes: 512,
            occupied_installation_bytes: capacity.occupied_installation_bytes(connection: connection)
          )
          sync_namespace_policy!(connection, receipt.fetch(:namespace_id), policy, now)
          pin_id = SecureRandom.uuid
          connection[:command_receipt_pins].insert(
            pin_id: pin_id, receipt_id: receipt_id, principal: principal.to_s,
            intent_id: intent_id.to_s, intent_generation: intent_generation,
            generation: 1, owner_host: owner_host, owner_pid: owner_pid,
            owner_process_start: owner_process_start, lifecycle_status: "active",
            retry_horizon_expires_at: Hive::RuntimeControlPlane::Codec.dump_time(horizon),
            created_at: now, updated_at: now
          )
          add_logical_bytes!(connection, receipt.fetch(:namespace_id), 512)
          connection[:command_receipt_pins][pin_id: pin_id]
        end
        pin_from(row)
      rescue ArgumentError, TypeError
        raise Hive::UsageError, "intent generation must be nonnegative"
      end

      def close_pin(receipt_id:, principal:, intent_id:, intent_generation:)
        intent_generation = Integer(intent_generation)
        now = timestamp
        database.transaction do |connection|
          pin = connection[:command_receipt_pins][
            receipt_id: receipt_id, principal: principal.to_s,
            intent_id: intent_id.to_s, intent_generation: intent_generation
          ]
          next false unless pin && pin.fetch(:lifecycle_status) == "active"
          connection[:command_receipt_pins].where(
            pin_id: pin.fetch(:pin_id), generation: pin.fetch(:generation),
            lifecycle_status: "active"
          ).update(
            lifecycle_status: "closed", generation: pin.fetch(:generation) + 1,
            released_at: now, updated_at: now
          ) == 1
        end
      rescue ArgumentError, TypeError
        false
      end
    end
  end
end
