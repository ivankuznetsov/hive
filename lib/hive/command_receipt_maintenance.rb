# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "socket"
require "hive/command_maintenance_authority"
require "hive/command_operation"
require "hive/command_owner_proof"
require "hive/command_receipt_capacity"
require "hive/command_receipt_ledger"
require "hive/pid_file"
require "hive/runtime_control_plane"
require "hive/schemas"

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

    def authorize_namespace_selection!(namespace_id)
      unless @authority.installation_owner?
        raise Hive::ConfigError, "--namespace-id requires the installation owner"
      end
      namespace_id
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

      ensure_settlement_safe!(row)
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

      ensure_settlement_safe!(row)
      terminalize!(
        row, state: outcome.fetch("state"), result: outcome.fetch("result"),
        status: outcome.fetch("status"), typed_reason: outcome.fetch("typed_reason"),
        reason: reason, evidence: evidence,
        retry_eligible: outcome.fetch("retry_eligible")
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
          if capacity_counted?(row)
            connection[:command_capacity].where(namespace_id: row.fetch(:namespace_id)).update(
              executing_count: Sequel[:executing_count] - 1,
              revision: Sequel[:revision] + 1, updated_at: now
            )
          end
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
      liveness = owner_liveness_evidence(pin)
      payload = {
        "schema" => "hive-command-receipt", "schema_version" => 1, "ok" => true,
        "operation" => "release_pin", "preview" => !confirm, "confirmed" => confirm,
        "pin_id" => pin.fetch(:pin_id), "generation" => pin.fetch(:generation),
        "warning" => "force release can let a later eligible prune remove replay/conflict protection and duplicate an effect",
        "evidence" => { "horizon" => horizon, "owner_liveness" => liveness }
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
               evidence: { "horizon" => horizon, "owner_liveness" => liveness },
               pin_id: pin.fetch(:pin_id)) if count == 1
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
      authorize_or_conceal!(batch && batch.fetch(:principal))
      raise Hive::UsageError, "unknown receipt maintenance batch #{batch_id}" unless batch
      if namespace_id && batch[:namespace_id] != namespace_id
        raise Hive::UsageError, "batch is not associated with namespace #{namespace_id}"
      end
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
        if count == 1
          settle_abandoned_administrative_receipt!(connection, current, now: now)
          audit!(connection, batch, action: "abandon_batch", reason: reason,
                 evidence: proof, batch_id: batch_id)
        end
        count
      end
      raise Hive::CommandConflict, "batch changed during abandonment" unless changed == 1
      payload.merge("preview" => false, "confirmed" => true,
                    "generation" => batch.fetch(:generation) + 1, "state" => "abandoned")
    end

    private

    def settle_abandoned_administrative_receipt!(connection, batch, now:)
      receipt_id = batch[:administrative_receipt_id]
      return if receipt_id.to_s.empty?

      receipt = connection[:command_receipts][receipt_id: receipt_id]
      @authority.authorize!(receipt.fetch(:principal)) if receipt
      unless receipt && receipt[:namespace_id] == batch[:namespace_id] &&
             receipt[:command] == "receipt" && receipt[:mode] == "prune" &&
             %w[prepared executing unresolved aborted].include?(receipt[:state])
        raise Hive::CommandConflict, "prune administrative receipt changed before abandonment"
      end
      public_receipt = public_receipt(
        receipt, generation: receipt.fetch(:generation) + 1, state: "settled"
      )
      payload = {
        "schema" => "hive-receipt-prune", "schema_version" => 1,
        "ok" => false, "error_class" => "CommandUnresolved",
        "error_kind" => "command_original_result_unavailable",
        "exit_code" => Hive::ExitCodes::COMMAND_UNRESOLVED,
        "message" => "the interrupted prune batch was abandoned after partial progress",
        "reason" => "command_original_result_unavailable", "state" => "settled",
        "batch_id" => batch.fetch(:batch_id),
        "outcomes" => JSON.parse(batch.fetch(:outcomes_json)),
        "command_receipt" => public_receipt
      }
      result = { "format" => "json", "payload" => payload }
      result["expanded_sha256"] = Digest::SHA256.hexdigest(
        Hive::RuntimeControlPlane::Codec.dump_json(payload)
      )
      result_json = Hive::RuntimeControlPlane::Codec.dump_json(result)
      changed = connection[:command_receipts].where(
        receipt_id: receipt_id, generation: receipt.fetch(:generation), state: receipt.fetch(:state)
      ).update(
        state: "settled", generation: receipt.fetch(:generation) + 1,
        result_json: result_json, result_digest: Digest::SHA256.hexdigest(result_json),
        result_status: Hive::ExitCodes::COMMAND_UNRESOLVED,
        typed_reason: "command_original_result_unavailable", retry_eligible: 0,
        owner_token: nil, terminal_at: now, updated_at: now
      )
      raise Hive::CommandConflict, "prune administrative receipt changed before abandonment" unless changed == 1

      connection[:command_effects].where(
        receipt_id: receipt_id, state: %w[prepared submitted]
      ).all.each do |effect|
        prior = effect[:evidence_json] ?
          Hive::RuntimeControlPlane::Codec.load_json(effect.fetch(:evidence_json)) : {}
        encoded = Hive::RuntimeControlPlane::Codec.dump_json(
          prior.merge("batch_abandoned" => true, "batch_id" => batch.fetch(:batch_id))
        )
        changed_effect = connection[:command_effects].where(
          effect_id: effect.fetch(:effect_id), state: effect.fetch(:state),
          updated_at: effect.fetch(:updated_at)
        ).update(state: "unknown", evidence_json: encoded, updated_at: now)
        if changed_effect == 1
          add_logical_bytes!(connection, receipt.fetch(:namespace_id),
                             encoded.bytesize - effect[:evidence_json].to_s.bytesize)
        end
      end
    end

    def receipt!(receipt_id, namespace_id: nil)
      row = @database.read { |connection| connection[:command_receipts][receipt_id: receipt_id] }
      authorize_or_conceal!(row && row.fetch(:principal))
      raise Hive::UsageError, "unknown command receipt #{receipt_id}" unless row
      if namespace_id && row.fetch(:namespace_id) != namespace_id
        raise Hive::UsageError, "receipt is not associated with namespace #{namespace_id}"
      end
      row
    end

    def pin_and_receipt!(pin_id, namespace_id: nil)
      pin = @database.read { |connection| connection[:command_receipt_pins][pin_id: pin_id] }
      receipt = pin && @database.read do |connection|
        connection[:command_receipts][receipt_id: pin.fetch(:receipt_id)]
      end
      authorize_or_conceal!(receipt && receipt.fetch(:principal))
      raise Hive::UsageError, "unknown command receipt pin #{pin_id}" unless pin
      raise Hive::CommandConflict, "maintenance target changed" unless receipt
      if namespace_id && receipt.fetch(:namespace_id) != namespace_id
        raise Hive::UsageError, "receipt is not associated with namespace #{namespace_id}"
      end
      [ pin, receipt ]
    end

    def authorize_or_conceal!(affected_principal)
      return @authority.authorize!(affected_principal) if affected_principal
      return @authority.authority_basis if @authority.installation_owner?

      @authority.authorize!("unknown-maintenance-target")
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
      if data["outcome"] == "succeeded"
        authoritative = validate_successful_reconciliation!(effect_rows, data)
        result = authoritative.fetch("result")
          validate_replay_envelope!(result, row: row)
        return {
          "state" => "succeeded", "status" => authoritative.fetch("status"),
          "typed_reason" => nil, "result" => result, "retry_eligible" => false
        }
      end
      raise Hive::CommandUnresolved.new(
        message: "retirement evidence does not authoritatively account for every command effect"
      )
    rescue KeyError, ArgumentError, TypeError
      raise Hive::UsageError, "retirement evidence has an unsupported shape"
    end

    def validate_successful_reconciliation!(effect_rows, data)
      supplied = Array(data["effects"])
      expected_ids = effect_rows.map { |effect| effect.fetch(:effect_id) }.sort
      supplied_ids = supplied.filter_map { |effect| effect["effect_id"] if effect.is_a?(Hash) }.sort
      unless !effect_rows.empty? && expected_ids == supplied_ids &&
             effect_rows.all? { |effect| effect.fetch(:state) == "applied" }
        raise Hive::CommandUnresolved.new(
          message: "successful retirement requires applied evidence for every command effect"
        )
      end
      effect_rows.each do |effect|
        proof = supplied.find { |entry| entry["effect_id"] == effect.fetch(:effect_id) }
        expected_identity = Digest::SHA256.hexdigest(effect.fetch(:identity_json))
        observation = proof["observation"]
        persisted = effect[:evidence_json] ?
          Hive::RuntimeControlPlane::Codec.load_json(effect.fetch(:evidence_json)) : {}
        valid = proof["ordinal"] == effect.fetch(:ordinal) &&
          proof["identity_sha256"] == expected_identity &&
          observation.is_a?(Hash) && Array(persisted["observations"]).include?(observation)
        unless valid
          raise Hive::CommandUnresolved.new(
            message: "successful retirement evidence does not match a stored authoritative observation"
          )
        end
      end
      boundary = effect_rows.find { |effect| effect.fetch(:ordinal) == 0 }
      persisted = boundary[:evidence_json] &&
        Hive::RuntimeControlPlane::Codec.load_json(boundary.fetch(:evidence_json))
      result = persisted && persisted["authoritative_result"]
      encoded = result && Hive::RuntimeControlPlane::Codec.dump_json(result)
      valid_result = result.is_a?(Hash) &&
        persisted["authoritative_result_sha256"] == Digest::SHA256.hexdigest(encoded)
      if data.key?("result")
        valid_result &&= Hive::RuntimeControlPlane::Codec.dump_json(data["result"]) == encoded
      end
      unless valid_result
        raise Hive::CommandUnresolved.new(
          message: "successful retirement requires the stored authoritative original result"
        )
      end
      {
        "result" => result,
        "status" => Integer(persisted.fetch("authoritative_status"))
      }
    rescue Hive::RuntimeControlPlane::CodecError, KeyError, ArgumentError, TypeError
      raise Hive::CommandUnresolved.new(
        message: "successful retirement requires the stored authoritative original result"
      )
    end

    def terminalize!(row, state:, result:, status:, typed_reason:, reason:, evidence: {},
                     retry_eligible: false)
      validate_replay_envelope!(result, row: row)
      result_json = Hive::RuntimeControlPlane::Codec.dump_json(result)
      now = timestamp
      concurrency_limits = retirement_concurrency_limits(row)
      changed = @database.transaction do |connection|
        current = connection[:command_receipts][receipt_id: row.fetch(:receipt_id)]
        authorize!(current)
        next 0 unless current && current.fetch(:generation) == row.fetch(:generation) &&
                      current.fetch(:state) == row.fetch(:state)
        admit_existing_work_execution!(connection, row, concurrency_limits)
        count = connection[:command_receipts].where(
          receipt_id: row.fetch(:receipt_id), generation: row.fetch(:generation), state: row.fetch(:state)
        ).update(
          state: state, generation: row.fetch(:generation) + 1,
          result_json: result_json, result_digest: Digest::SHA256.hexdigest(result_json),
          result_status: status, typed_reason: typed_reason,
          retry_eligible: retry_eligible ? 1 : 0,
          terminal_at: now, updated_at: now, owner_token: nil
        )
        if count == 1
          if capacity_counted?(row)
            connection[:command_capacity].where(namespace_id: row.fetch(:namespace_id)).update(
              nonterminal_count: Sequel[:nonterminal_count] - 1,
              logical_bytes: Sequel[:logical_bytes] + result_json.bytesize,
              revision: Sequel[:revision] + 1, updated_at: now
            )
          end
          audit!(connection, row, action: "retire_#{state}", reason: reason, evidence: evidence)
        end
        count
      end
      raise Hive::CommandConflict, "receipt changed during retirement" unless changed == 1
    end

    def retirement_concurrency_limits(row)
      global = Hive::CommandReceiptCapacity.global_receipts
      namespace = @database.read do |connection|
        connection[:command_namespaces][namespace_id: row.fetch(:namespace_id)]&.
          fetch(:concurrency_limit, nil)
      end
      installation = global.fetch(
        "installation_concurrency_limit",
        Hive::CommandReceiptCapacity::DEFAULT_INSTALLATION_CONCURRENCY_LIMIT
      )
      unless namespace.is_a?(Integer) && namespace.positive? &&
             installation.is_a?(Integer) && installation.positive?
        raise Hive::ConfigError,
              "command receipt concurrency limits must be positive integers"
      end
      [ namespace, installation ]
    end

    def admit_existing_work_execution!(connection, row, limits)
      namespace_limit, installation_limit = limits
      capacity = connection[:command_capacity][namespace_id: row.fetch(:namespace_id)]
      raise Hive::CommandConflict, "receipt namespace capacity is unavailable" unless capacity

      if capacity.fetch(:executing_count) >= namespace_limit
        raise Hive::CommandCapacityError.new(
          "command concurrency limit at namespace scope; stop live work or confirm orphan recovery first",
          reason: :command_concurrency_limit, scope: :namespace
        )
      end
      if connection[:command_capacity].sum(:executing_count).to_i >= installation_limit
        raise Hive::CommandCapacityError.new(
          "command concurrency limit at installation scope; stop live work or confirm orphan recovery first",
          reason: :command_concurrency_limit, scope: :installation
        )
      end
    end

    def dead_owner_proof!(row)
      Hive::CommandOwnerProof.dead!(
        row, host: Socket.gethostname, alive: @alive, ownership: @ownership, clock: @clock
      )
    end

    def ensure_settlement_safe!(row)
      dead_owner_proof!(row)
      continuations = @database.read do |connection|
        connection[:command_dispatch_contexts]
          .where(receipt_id: row.fetch(:receipt_id)).all.filter_map do |context|
            connection[:dispatch_requests][request_id: context.fetch(:request_id)]
          end
      end
      if continuations.any? { |continuation|
        %w[queued claimed admitted running].include?(continuation[:state].to_s)
      }
        raise Hive::CommandUnresolved.new(
          message: "a resumable command continuation is still queued or in flight"
        )
      end
    end

    def validate_replay_envelope!(result = nil, row: nil, **result_keywords)
      result = result_keywords if result.nil? && !result_keywords.empty?
      unless result.is_a?(Hash) && %w[dual json text].include?(result["format"])
        raise Hive::UsageError, "retirement result must be a durable dual, json, or text replay envelope"
      end
      if %w[dual json].include?(result["format"])
        payload = result["payload"]
        digest = result["expanded_sha256"]
        unless payload.is_a?(Hash) && digest == Digest::SHA256.hexdigest(
          Hive::RuntimeControlPlane::Codec.dump_json(payload)
        )
          raise Hive::UsageError, "retirement JSON result has an invalid replay digest"
        end
        validate_closed_error_enums!(payload, row) if payload["ok"] == false && row
      elsif !result["text"].is_a?(String)
        raise Hive::UsageError, "retirement text result must contain text"
      end
    end

    def validate_closed_error_enums!(payload, row)
      schema_name = case row.fetch(:command)
      when "new" then "hive-new"
      when "approve" then "hive-approve"
      when "answer" then "hive-answer"
      when "act" then "hive-act"
      when "stage_action" then "hive-stage-action"
      when "receipt"
        row[:mode] == "prune" ? "hive-receipt-prune" : "hive-command-receipt"
      end
      return unless schema_name

      document = JSON.parse(File.read(Hive::Schemas.schema_path(schema_name)))
      properties = document.dig("$defs", "ErrorPayload", "properties") || {}
      kinds = properties.dig("error_kind", "enum")
      codes = properties.dig("exit_code", "enum")
      if kinds && !kinds.include?(payload["error_kind"])
        raise Hive::UsageError, "retirement error_kind is outside the command schema"
      end
      if codes && !codes.include?(payload["exit_code"])
        raise Hive::UsageError, "retirement exit_code is outside the command schema"
      end
    rescue Errno::ENOENT, JSON::ParserError => error
      raise Hive::ConfigError, "cannot validate command retirement schema: #{error.message}"
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

    def owner_liveness_evidence(pin)
      proof = Hive::CommandOwnerProof.dead(
        pin, host: Socket.gethostname, alive: @alive, ownership: @ownership, clock: @clock
      )
      return { "status" => "dead", "proof" => proof.last } if proof

      { "status" => "live_remote_or_unverifiable", "proof" => nil }
    rescue Hive::Error, SystemCallError, IOError => error
      { "status" => "unverifiable", "proof" => nil, "error_class" => error.class.name }
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
      encoded_evidence = Hive::RuntimeControlPlane::Codec.dump_json(evidence || {})
      Hive::CommandReceiptLedger.insert_audit!(connection,
        audit_id: SecureRandom.uuid, receipt_id: row[:receipt_id], batch_id: batch_id,
        pin_id: pin_id, namespace_id: row[:namespace_id],
        acting_principal: @authority.principal,
        principal_source: @authority.principal_source,
        authority_basis: @authority.authority_basis,
        peer_address: @authority.peer_address, action: action,
        affected_principal: row[:principal], reason: reason,
        evidence_json: encoded_evidence,
        created_at: timestamp
      )
      add_logical_bytes!(connection, row[:namespace_id], encoded_evidence.bytesize + 512) if row[:namespace_id]
    end

    def same_generation_state?(current, original, state)
      current && current.fetch(:generation) == original.fetch(:generation) &&
        current.fetch(:state) == state
    end

    def same_owner?(left, right)
      %i[owner_host owner_pid owner_process_start].all? { |key| left[key] == right[key] }
    end

    def capacity_counted?(row) = Hive::CommandReceiptLedger.capacity_counted?(row)

    def add_logical_bytes!(connection, namespace_id, delta)
      Hive::CommandReceiptLedger.add_logical_bytes!(
        connection, namespace_id, delta, now: timestamp
      )
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
