# frozen_string_literal: true

module Hive
  class CommandReceiptStore
    module Replay
      private

      def classify_existing!(row, principal:, request_fingerprint:, project_root:)
        unless row.fetch(:principal) == principal.to_s &&
               row.fetch(:request_fingerprint) == request_fingerprint
          raise Hive::CommandConflict
        end

        if row.fetch(:state) == "executing" && !current_process_owner?(row) &&
           receipt_effects_empty?(row.fetch(:receipt_id))
          proof = Hive::CommandOwnerProof.dead(
            row, host: @host, alive: @alive, ownership: @ownership, clock: @clock
          )
          if proof
            claim = claim_from(row, :resume, project_root: project_root)
            return abort_before_effect(claim, reason: "command_orphaned_owner")
          end
        end

        if %w[executing unresolved].include?(row.fetch(:state)) &&
           (authoritative = authoritative_result_for_receipt(row))
          if row.fetch(:state) == "executing" && !current_process_owner?(row)
            proof = Hive::CommandOwnerProof.dead(
              row, host: @host, alive: @alive, ownership: @ownership, clock: @clock
            )
            raise Hive::CommandInProgress.new(command_receipt: public_receipt(row)) unless proof
          end
          begin
            result, status = authoritative
            claim = claim_from(row, :replay, project_root: project_root)
            claim = resume_maintenance(claim) if row.fetch(:state) == "unresolved"
            return finalize!(
              claim, state: "succeeded", result: result, status: status,
              reason: nil, retry_eligible: false
            )
          rescue Hive::CommandConflict
            row = receipt(row.fetch(:receipt_id))
          end
        end

        public_receipt = public_receipt(row)
        case row.fetch(:state)
        when *TERMINAL_STATES
          claim_from(row, :replay, project_root: project_root)
        when "prepared", "executing"
          raise Hive::CommandInProgress.new(command_receipt: public_receipt)
        when "unresolved", "aborted"
          if resumable_prune?(row) || reconcilable_effect?(row) || orderly_aborted?(row)
            return claim_from(row, :resume, project_root: project_root)
          end
          raise Hive::CommandUnresolved.new(command_receipt: public_receipt)
        else
          raise Hive::RuntimeControlPlane::IntegrityError.new(
            "command receipt has an unknown state",
            code: :command_receipt_state_invalid,
            action: Hive::RuntimeControlPlane::Database::BACKUP_ACTION
          )
        end
      end

      def claim_from(row, disposition, project_root: nil)
        result = row[:result_json] && Hive::RuntimeControlPlane::Codec.load_json(row[:result_json])
        Claim.new(
          disposition: disposition,
          receipt_id: row.fetch(:receipt_id),
          namespace_id: row.fetch(:namespace_id),
          generation: row.fetch(:generation),
          state: row.fetch(:state),
          principal: row.fetch(:principal),
          request_fingerprint: row.fetch(:request_fingerprint),
          result: result,
          status: row[:result_status],
          reason: row[:typed_reason],
          public_receipt: public_receipt(row),
          project_root: project_root
        )
      end

      def public_receipt(row)
        {
          "id" => row.fetch(:receipt_id),
          "generation" => row.fetch(:generation),
          "state" => row.fetch(:state)
        }
      end

      def resumable_prune?(row)
        return false unless row[:command] == "receipt" && row[:mode] == "prune" && row[:state] == "unresolved"
        database.read do |connection|
          connection[:command_maintenance_batches].where(
            administrative_receipt_id: row.fetch(:receipt_id), state: %w[prepared executing completed]
          ).any?
        end
      end

      RECONCILABLE_EFFECT_KINDS = %w[
        github_push github_pull_request attempt_dispatch dispatch_request task_activity
      ].freeze

      def reconcilable_effect?(row)
        return false unless row.fetch(:state) == "unresolved"
        effect = database.read do |connection|
          connection[:command_effects][receipt_id: row.fetch(:receipt_id), ordinal: 0]
        end
        return false unless effect && %w[submitted unknown].include?(effect.fetch(:state))
        evidence = effect[:evidence_json] ?
          Hive::RuntimeControlPlane::Codec.load_json(effect.fetch(:evidence_json)) : {}
        submissions = Array(evidence["submissions"])
        observations = Array(evidence["observations"])
        evidence["owner_released"] == true && !submissions.empty? && submissions.all? do |entry|
          entry.is_a?(Hash) && RECONCILABLE_EFFECT_KINDS.include?(entry["kind"]) &&
            authoritative_submission_observed?(entry, observations)
        end
      rescue Hive::RuntimeControlPlane::CodecError
        false
      end

      def orderly_aborted?(row)
        return false unless row.fetch(:state) == "aborted"
        effects = database.read do |connection|
          connection[:command_effects].where(receipt_id: row.fetch(:receipt_id)).all
        end
        effects.empty? || effects.all? { |effect| safely_not_applied_effect?(effect) }
      end

      def safely_not_applied_effect?(effect)
        return false unless effect.fetch(:state) == "not_applied" && effect[:evidence_json]
        evidence = Hive::RuntimeControlPlane::Codec.load_json(effect.fetch(:evidence_json))
        evidence["whole_effect_non_application"] == true && Array(evidence["submissions"]).empty?
      rescue Hive::RuntimeControlPlane::CodecError
        false
      end

      def authoritative_submission_observed?(submission, observations)
        kind = submission["kind"]
        identity = submission["identity"]
        return false unless identity.is_a?(Hash)

        correlation = identity["publication_id"] || identity["request_id"] || identity["operation_id"]
        return false if correlation.to_s.empty?
        return true if observations.any? do |observation|
          observation.is_a?(Hash) && observation["source"] == kind &&
            observation["correlation_id"] == correlation.to_s
        end

        return false unless %w[attempt_dispatch dispatch_request].include?(kind)
        database.read do |connection|
          request = connection[:dispatch_requests][request_id: correlation.to_s]
          request && %w[queued claimed admitted running completed].include?(request[:state].to_s)
        end
      end

      def receipt_effects_empty?(receipt_id)
        database.read do |connection|
          !connection[:command_effects].where(receipt_id: receipt_id).any?
        end
      end

      def current_process_owner?(row)
        context = defined?(Hive::CommandOperation) && Hive::CommandOperation.current_context
        context && context.receipt_id == row.fetch(:receipt_id) &&
          row[:owner_host] == @host && row[:owner_pid] == Process.pid &&
          row[:owner_process_start] == process_start(Process.pid)
      rescue Hive::Error, SystemCallError, IOError
        false
      end

      def authoritative_result_for_receipt(row)
        effect = database.read do |connection|
          connection[:command_effects][receipt_id: row.fetch(:receipt_id), ordinal: 0]
        end
        data = authoritative_result(effect)
        data && [ data.fetch("result"), data.fetch("status") ]
      end

      def authoritative_result(effect)
        return unless effect && effect.fetch(:state) == "applied"
        unless effect[:evidence_json]
          raise Hive::CommandUnresolved.new(
            reason: "command_original_result_unavailable",
            message: "the applied command effect has no recoverable original result"
          )
        end
        evidence = Hive::RuntimeControlPlane::Codec.load_json(effect.fetch(:evidence_json))
        result = evidence["authoritative_result"]
        encoded = Hive::RuntimeControlPlane::Codec.dump_json(result)
        unless result.is_a?(Hash) && encoded.bytesize <= MAX_RESULT_BYTES &&
               evidence["authoritative_result_sha256"] == Digest::SHA256.hexdigest(encoded)
          raise Hive::CommandUnresolved.new(
            reason: "command_original_result_unavailable",
            message: "the applied command effect's original result is unrecoverable"
          )
        end
        status = Integer(evidence.fetch("authoritative_status"))
        { "result" => result, "status" => status }
      rescue Hive::RuntimeControlPlane::CodecError, KeyError, ArgumentError, TypeError
        raise Hive::CommandUnresolved.new(
          reason: "command_original_result_unavailable",
          message: "the applied command effect's original result is unrecoverable"
        )
      end
    end
  end
end
