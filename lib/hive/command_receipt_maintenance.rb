# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "socket"
require "hive/command_maintenance_authority"
require "hive/command_operation"
require "hive/pid_file"
require "hive/runtime_control_plane"

module Hive
  class CommandReceiptMaintenance
    def initialize(database: Hive::RuntimeControlPlane.database, authority: nil,
                   clock: -> { Time.now.utc }, alive: Hive::PidFile.method(:alive?),
                   ownership: Hive::PidFile.method(:ownership))
      @database = database
      @authority = authority || Hive::CommandMaintenanceAuthority.local(
        principal: Hive::CommandOperation.local_principal(database)
      )
      @clock = clock
      @alive = alive
      @ownership = ownership
    end

    def settle_without_result(receipt_id, expected_generation:, reason:, confirm: false,
                              namespace_id: nil)
      require_reason!(reason)
      row = receipt!(receipt_id, namespace_id: namespace_id)
      authorize!(row)
      validate_generation!(row, expected_generation)
      unless %w[unresolved aborted].include?(row.fetch(:state))
        raise Hive::UsageError, "settlement without result requires an unresolved or aborted receipt"
      end
      payload = maintenance_payload(
        "retire", row, preview: !confirm,
        outcome: "original_result_unavailable",
        warning: "effects may have occurred; automatic retry is forbidden; eligible prune ends duplicate protection"
      )
      return payload unless confirm

      result = {
        "format" => "json",
        "payload" => {
          "schema" => "hive-command-receipt", "schema_version" => 1,
          "ok" => false, "error_kind" => "command_original_result_unavailable",
          "exit_code" => Hive::ExitCodes::COMMAND_UNRESOLVED,
          "message" => "the original command result is unavailable",
          "state" => "settled", "reason" => "command_original_result_unavailable",
          "command_receipt" => public_receipt(row, generation: row.fetch(:generation) + 1,
                                               state: "settled")
        }
      }
      result["expanded_sha256"] = Digest::SHA256.hexdigest(
        Hive::RuntimeControlPlane::Codec.dump_json(result.fetch("payload"))
      )
      terminalize!(row, state: "settled", result: result,
                   status: Hive::ExitCodes::COMMAND_UNRESOLVED,
                   typed_reason: "command_original_result_unavailable", reason: reason)
      payload.merge(
        "preview" => false, "confirmed" => true, "state" => "settled",
        "command_receipt" => public_receipt(row, generation: row.fetch(:generation) + 1,
                                             state: "settled")
      )
    end

    def retire_with_evidence(receipt_id, expected_generation:, evidence:, reason:, confirm: false,
                             namespace_id: nil)
      require_reason!(reason)
      row = receipt!(receipt_id, namespace_id: namespace_id)
      authorize!(row)
      validate_generation!(row, expected_generation)
      unless %w[unresolved aborted].include?(row.fetch(:state))
        raise Hive::UsageError, "evidence retirement requires an unresolved or aborted receipt"
      end
      outcome = validate_retirement_evidence!(row, evidence)
      payload = maintenance_payload("retire", row, preview: !confirm, outcome: outcome.fetch("state"))
      return payload unless confirm

      terminalize!(
        row, state: outcome.fetch("state"), result: outcome.fetch("result"),
        status: outcome.fetch("status"), typed_reason: outcome.fetch("typed_reason"),
        reason: reason, evidence: evidence
      )
      payload.merge(
        "preview" => false, "confirmed" => true, "state" => outcome.fetch("state"),
        "command_receipt" => public_receipt(
          row, generation: row.fetch(:generation) + 1, state: outcome.fetch("state")
        )
      )
    end

    def orphaned_owner(receipt_id, expected_generation:, reason:, confirm: false,
                       namespace_id: nil)
      require_reason!(reason)
      row = receipt!(receipt_id, namespace_id: namespace_id)
      authorize!(row)
      validate_generation!(row, expected_generation)
      raise Hive::UsageError, "orphan-owner recovery requires an executing receipt" unless row.fetch(:state) == "executing"
      proof = dead_owner_proof!(row)
      payload = maintenance_payload("orphaned_owner", row, preview: !confirm,
                                    outcome: "unresolved").merge("evidence" => proof)
      return payload unless confirm

      now = timestamp
      changed = @database.transaction do |connection|
        current = connection[:command_receipts][receipt_id: row.fetch(:receipt_id)]
        authorize!(current)
        next 0 unless same_generation_state?(current, row, "executing") && same_owner?(current, row)
        count = connection[:command_receipts].where(
          receipt_id: row.fetch(:receipt_id), generation: row.fetch(:generation), state: "executing"
        ).update(
          state: "unresolved", generation: row.fetch(:generation) + 1,
          typed_reason: "command_orphaned_owner", owner_token: nil, updated_at: now
        )
        if count == 1
          connection[:command_capacity].where(namespace_id: row.fetch(:namespace_id)).update(
            executing_count: Sequel[:executing_count] - 1,
            revision: Sequel[:revision] + 1, updated_at: now
          )
          audit!(connection, row, action: "orphaned_owner", reason: reason, evidence: proof)
        end
        count
      end
      raise Hive::CommandConflict, "receipt ownership changed during orphan recovery" unless changed == 1
      payload.merge("preview" => false, "confirmed" => true, "state" => "unresolved",
                    "command_receipt" => public_receipt(row, generation: row.fetch(:generation) + 1,
                                                         state: "unresolved"))
    end

    def release_pin(pin_id, expected_generation:, reason:, confirm: false, force: false,
                    namespace_id: nil)
      require_reason!(reason)
      pin, row = pin_and_receipt!(pin_id, namespace_id: namespace_id)
      authorize!(row)
      validate_generation!(pin, expected_generation)
      raise Hive::UsageError, "pin is not active" unless pin.fetch(:lifecycle_status) == "active"
      horizon = horizon_evidence(pin)
      payload = {
        "schema" => "hive-command-receipt", "schema_version" => 1, "ok" => true,
        "operation" => "release_pin", "preview" => !confirm, "confirmed" => confirm,
        "pin_id" => pin.fetch(:pin_id), "generation" => pin.fetch(:generation),
        "warning" => "force release can let a later eligible prune remove replay/conflict protection and duplicate an effect"
      }.merge(horizon)
      return payload unless confirm
      raise Hive::UsageError, "confirmed pin release requires --force" unless force

      now = timestamp
      changed = @database.transaction do |connection|
        current_pin = connection[:command_receipt_pins][pin_id: pin.fetch(:pin_id)]
        current_receipt = connection[:command_receipts][receipt_id: row.fetch(:receipt_id)]
        authorize!(current_receipt)
        next 0 unless current_pin && current_pin.fetch(:generation) == pin.fetch(:generation) &&
                      current_pin.fetch(:lifecycle_status) == "active"
        count = connection[:command_receipt_pins].where(
          pin_id: pin.fetch(:pin_id), generation: pin.fetch(:generation), lifecycle_status: "active"
        ).update(lifecycle_status: "force_released", generation: pin.fetch(:generation) + 1,
                 released_at: now, updated_at: now)
        audit!(connection, row, action: "force_release_pin", reason: reason,
               evidence: horizon, pin_id: pin.fetch(:pin_id)) if count == 1
        count
      end
      raise Hive::CommandConflict, "pin changed during release" unless changed == 1
      payload.merge("preview" => false, "confirmed" => true,
                    "generation" => pin.fetch(:generation) + 1, "state" => "force_released")
    end

    def abandon_batch(batch_id, expected_generation:, reason:, confirm: false,
                      namespace_id: nil)
      require_reason!(reason)
      batch = @database.read { |connection| connection[:command_maintenance_batches][batch_id: batch_id] }
      raise Hive::UsageError, "unknown receipt maintenance batch #{batch_id}" unless batch
      if namespace_id && batch[:namespace_id] != namespace_id
        raise Hive::UsageError, "batch is not associated with namespace #{namespace_id}"
      end
      @authority.authorize!(batch.fetch(:principal))
      validate_generation!(batch, expected_generation)
      unless %w[prepared executing].include?(batch.fetch(:state))
        raise Hive::UsageError, "only an unfinished receipt maintenance batch can be abandoned"
      end
      proof = dead_owner_proof!(batch)
      payload = {
        "schema" => "hive-command-receipt", "schema_version" => 1, "ok" => true,
        "operation" => "abandon_batch", "preview" => !confirm, "confirmed" => confirm,
        "batch_id" => batch_id, "generation" => batch.fetch(:generation),
        "prior_progress" => JSON.parse(batch.fetch(:outcomes_json)), "evidence" => proof,
        "warning" => "already committed deletions remain committed"
      }
      return payload unless confirm

      now = timestamp
      changed = @database.transaction do |connection|
        current = connection[:command_maintenance_batches][batch_id: batch_id]
        @authority.authorize!(current.fetch(:principal)) if current
        next 0 unless current && current.fetch(:generation) == batch.fetch(:generation) &&
                      %w[prepared executing].include?(current.fetch(:state)) && same_owner?(current, batch)
        count = connection[:command_maintenance_batches].where(
          batch_id: batch_id, generation: batch.fetch(:generation), state: batch.fetch(:state)
        ).update(state: "abandoned", generation: batch.fetch(:generation) + 1,
                 updated_at: now, completed_at: now)
        audit!(connection, batch, action: "abandon_batch", reason: reason,
               evidence: proof, batch_id: batch_id) if count == 1
        count
      end
      raise Hive::CommandConflict, "batch changed during abandonment" unless changed == 1
      payload.merge("preview" => false, "confirmed" => true,
                    "generation" => batch.fetch(:generation) + 1, "state" => "abandoned")
    end

    private

    def receipt!(receipt_id, namespace_id: nil)
      row = @database.read { |connection| connection[:command_receipts][receipt_id: receipt_id] }
      raise Hive::UsageError, "unknown command receipt #{receipt_id}" unless row
      if namespace_id && row.fetch(:namespace_id) != namespace_id
        raise Hive::UsageError, "receipt is not associated with namespace #{namespace_id}"
      end
      row
    end

    def pin_and_receipt!(pin_id, namespace_id: nil)
      pin = @database.read { |connection| connection[:command_receipt_pins][pin_id: pin_id] }
      raise Hive::UsageError, "unknown command receipt pin #{pin_id}" unless pin
      [ pin, receipt!(pin.fetch(:receipt_id), namespace_id: namespace_id) ]
    end

    def authorize!(row)
      raise Hive::CommandConflict, "maintenance target changed" unless row
      @authority.authorize!(row.fetch(:principal))
    end

    def validate_generation!(row, expected)
      value = Integer(expected)
      unless value.positive? && row.fetch(:generation) == value
        raise Hive::CommandConflict, "expected generation does not match the maintenance target"
      end
    rescue ArgumentError, TypeError
      raise Hive::UsageError, "--expected-generation must be a positive integer"
    end

    def validate_retirement_evidence!(row, evidence)
      data = evidence.is_a?(Hash) ? evidence : {}
      effect_rows = @database.read do |connection|
        connection[:command_effects].where(receipt_id: row.fetch(:receipt_id)).order(:ordinal).all
      end
      states = effect_rows.map { |effect| effect.fetch(:state) }
      if data["outcome"] == "not_applied" && data["whole_effect_non_application"] == true &&
         !states.empty? && states.all? { |state| state == "not_applied" }
        return {
          "state" => "failed", "status" => Integer(data.fetch("status", Hive::ExitCodes::GENERIC)),
          "typed_reason" => data.fetch("typed_reason", "command_effect_not_applied"),
          "result" => data.fetch("result"), "retry_eligible" => true
        }
      end
      if data["outcome"] == "succeeded" && !states.empty? && states.all? { |state| state == "applied" }
        return {
          "state" => "succeeded", "status" => Hive::ExitCodes::SUCCESS,
          "typed_reason" => nil, "result" => data.fetch("result")
        }
      end
      raise Hive::CommandUnresolved.new(
        message: "retirement evidence does not authoritatively account for every command effect"
      )
    rescue KeyError, ArgumentError, TypeError
      raise Hive::UsageError, "retirement evidence has an unsupported shape"
    end

    def terminalize!(row, state:, result:, status:, typed_reason:, reason:, evidence: {})
      result_json = Hive::RuntimeControlPlane::Codec.dump_json(result)
      now = timestamp
      changed = @database.transaction do |connection|
        current = connection[:command_receipts][receipt_id: row.fetch(:receipt_id)]
        authorize!(current)
        next 0 unless current && current.fetch(:generation) == row.fetch(:generation) &&
                      current.fetch(:state) == row.fetch(:state)
        count = connection[:command_receipts].where(
          receipt_id: row.fetch(:receipt_id), generation: row.fetch(:generation), state: row.fetch(:state)
        ).update(
          state: state, generation: row.fetch(:generation) + 1,
          result_json: result_json, result_digest: Digest::SHA256.hexdigest(result_json),
          result_status: status, typed_reason: typed_reason,
          retry_eligible: evidence["whole_effect_non_application"] == true ? 1 : 0,
          terminal_at: now, updated_at: now, owner_token: nil
        )
        if count == 1
          connection[:command_capacity].where(namespace_id: row.fetch(:namespace_id)).update(
            nonterminal_count: Sequel[:nonterminal_count] - 1,
            revision: Sequel[:revision] + 1, updated_at: now
          )
          audit!(connection, row, action: "retire_#{state}", reason: reason, evidence: evidence)
        end
        count
      end
      raise Hive::CommandConflict, "receipt changed during retirement" unless changed == 1
    end

    def dead_owner_proof!(row)
      host = row[:owner_host]
      pid = row[:owner_pid]
      recorded = row[:owner_process_start]
      unless host == Socket.gethostname && pid.is_a?(Integer) && pid.positive? && recorded
        raise Hive::CommandUnresolved.new(
          reason: "command_orphaned_pin",
          message: "owner identity is remote or incomplete and cannot be proven dead"
        )
      end
      observed_at = timestamp
      alive = @alive.call(pid)
      ownership = alive ? @ownership.call({ "process_start_time" => recorded }, pid) : :dead
      proven = !alive || ownership == :reused
      unless proven
        raise Hive::CommandUnresolved.new(
          reason: "command_orphaned_pin",
          message: "owner is live or its identity is unverifiable"
        )
      end
      {
        "host" => host, "pid" => pid, "recorded_start_time" => recorded,
        "alive" => alive, "ownership" => ownership.to_s, "observed_at" => observed_at
      }
    end

    def horizon_evidence(pin)
      observed = @clock.call.utc
      raw = pin[:retry_horizon_expires_at]
      return { "retry_horizon_expires_at" => nil, "observed_at" => timestamp(observed),
               "horizon_evidence" => "unavailable" } unless raw
      horizon = Hive::RuntimeControlPlane::Codec.load_time(raw)
      elapsed = [ observed - horizon, 0 ].max
      {
        "retry_horizon_expires_at" => raw, "observed_at" => timestamp(observed),
        "horizon_elapsed" => observed >= horizon, "elapsed_seconds" => elapsed.round(6)
      }
    rescue Hive::RuntimeControlPlane::CodecError
      { "retry_horizon_expires_at" => raw, "observed_at" => timestamp(observed),
        "horizon_evidence" => "invalid" }
    end

    def maintenance_payload(operation, row, preview:, outcome:, warning: nil)
      payload = {
        "schema" => "hive-command-receipt", "schema_version" => 1, "ok" => true,
        "operation" => operation, "preview" => preview, "confirmed" => !preview,
        "receipt_id" => row.fetch(:receipt_id), "generation" => row.fetch(:generation),
        "state" => row.fetch(:state), "outcome" => outcome
      }
      payload["warning"] = warning if warning
      payload
    end

    def audit!(connection, row, action:, reason:, evidence:, pin_id: nil, batch_id: nil)
      connection[:command_maintenance_audit].insert(
        audit_id: SecureRandom.uuid, receipt_id: row[:receipt_id], batch_id: batch_id,
        pin_id: pin_id, namespace_id: row[:namespace_id],
        acting_principal: @authority.principal,
        principal_source: @authority.principal_source,
        authority_basis: @authority.authority_basis,
        peer_address: @authority.peer_address, action: action,
        affected_principal: row[:principal], reason: reason,
        evidence_json: Hive::RuntimeControlPlane::Codec.dump_json(evidence || {}),
        created_at: timestamp
      )
    end

    def same_generation_state?(current, original, state)
      current && current.fetch(:generation) == original.fetch(:generation) &&
        current.fetch(:state) == state
    end

    def same_owner?(left, right)
      %i[owner_host owner_pid owner_process_start].all? { |key| left[key] == right[key] }
    end

    def public_receipt(row, generation:, state:)
      { "id" => row.fetch(:receipt_id), "generation" => generation, "state" => state }
    end

    def require_reason!(reason)
      raise Hive::UsageError, "--reason is required" if reason.to_s.strip.empty?
    end

    def timestamp(value = @clock.call.utc) = Hive::RuntimeControlPlane::Codec.dump_time(value)
  end
end
