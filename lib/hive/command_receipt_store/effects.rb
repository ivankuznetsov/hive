# frozen_string_literal: true

module Hive
  class CommandReceiptStore
    module Effects
      def prepare_effect(claim, ordinal:, kind:, identity: {})
        effect_id = SecureRandom.uuid
        now = timestamp
        database.transaction do |connection|
          row = connection[:command_receipts][receipt_id: claim.receipt_id]
          unless row && row.fetch(:generation) == claim.generation && row.fetch(:state) == "executing"
            raise Hive::CommandConflict, "command receipt ownership changed before effect intent"
          end
          existing = connection[:command_effects][receipt_id: claim.receipt_id, ordinal: Integer(ordinal)]
          next existing if existing
          connection[:command_effects].insert(
            effect_id: effect_id, receipt_id: claim.receipt_id, ordinal: Integer(ordinal),
            effect_kind: kind.to_s,
            identity_json: Hive::RuntimeControlPlane::Codec.dump_json(identity),
            state: "prepared", created_at: now, updated_at: now
          )
          add_logical_bytes!(
            connection, claim.namespace_id,
            Hive::RuntimeControlPlane::Codec.dump_json(identity).bytesize + 512
          )
          connection[:command_effects][effect_id: effect_id]
        end
      end

      def update_effect(claim, effect_id:, from:, to:, evidence: nil)
        now = timestamp
        changed = database.transaction do |connection|
          receipt = connection[:command_receipts][receipt_id: claim.receipt_id]
          next 0 unless receipt && receipt.fetch(:generation) == claim.generation &&
                        receipt.fetch(:state) == "executing"
          effect = connection[:command_effects][effect_id: effect_id, receipt_id: claim.receipt_id]
          next 0 unless effect
          encoded_evidence = if evidence
            prior = effect[:evidence_json] ?
              Hive::RuntimeControlPlane::Codec.load_json(effect.fetch(:evidence_json)) : {}
            Hive::RuntimeControlPlane::Codec.dump_json(
              prior.merge(Hive::RuntimeControlPlane::Codec.normalize(evidence))
            )
          end
          changed = connection[:command_effects].where(
            effect_id: effect_id, receipt_id: claim.receipt_id, state: Array(from)
          ).update(state: to.to_s, evidence_json: encoded_evidence, updated_at: now)
          if changed == 1 && evidence
            add_logical_bytes!(
              connection, claim.namespace_id,
              encoded_evidence.bytesize - effect[:evidence_json].to_s.bytesize
            )
          end
          changed
        end
        raise Hive::CommandConflict, "command effect ownership changed" unless changed == 1
        true
      end

      # Persist the exact replay representation before the receipt can report
      # success, so a lost final commit can be recovered without inventing a result.
      def complete_effect(claim, effect_id:, result:, status:)
        encoded = Hive::RuntimeControlPlane::Codec.dump_json(result)
        if encoded.bytesize > MAX_RESULT_BYTES
          raise Hive::CommandUnresolved.new(
            message: "original command result exceeded the durable receipt limit"
          )
        end
        digest = Digest::SHA256.hexdigest(encoded)
        record_effect_observation(
          receipt_id: claim.receipt_id, effect_id: effect_id,
          principal: claim.principal, request_fingerprint: claim.request_fingerprint,
          generation: claim.generation, source: "command_boundary", correlation_id: effect_id,
          evidence: { "result_sha256" => digest }
        )
        update_effect(
          claim, effect_id: effect_id, from: %w[prepared submitted unknown], to: "applied",
          evidence: {
            "boundary_completed" => true, "authoritative_result" => result,
            "authoritative_result_sha256" => digest, "authoritative_status" => Integer(status)
          }
        )
      end

      def authoritative_result_recorded?(receipt_id:, effect_id:)
        row = database.read do |connection|
          connection[:command_effects][receipt_id: receipt_id.to_s, effect_id: effect_id.to_s]
        end
        !authoritative_result(row).nil?
      end

      def record_effect_submission(receipt_id:, effect_id:, principal:, request_fingerprint:,
                                   generation:, kind:, identity:)
        correlation = {
          "kind" => kind.to_s,
          "identity" => Hive::RuntimeControlPlane::Codec.normalize(identity)
        }
        now = timestamp
        changed = database.transaction do |connection|
          receipt = connection[:command_receipts][receipt_id: receipt_id.to_s]
          next 0 unless receipt && receipt.fetch(:state) == "executing" &&
                        receipt.fetch(:generation) == Integer(generation) &&
                        receipt.fetch(:principal) == principal.to_s &&
                        receipt.fetch(:request_fingerprint) == request_fingerprint.to_s
          effect = connection[:command_effects][
            effect_id: effect_id.to_s, receipt_id: receipt_id.to_s
          ]
          next 0 unless effect && %w[prepared submitted unknown].include?(effect.fetch(:state))
          prior = effect[:evidence_json] ?
            Hive::RuntimeControlPlane::Codec.load_json(effect.fetch(:evidence_json)) : {}
          submissions = Array(prior["submissions"])
          submissions << correlation unless submissions.include?(correlation)
          encoded = Hive::RuntimeControlPlane::Codec.dump_json(
            prior.merge("submissions" => submissions)
          )
          count = connection[:command_effects].where(
            effect_id: effect_id.to_s, receipt_id: receipt_id.to_s,
            state: effect.fetch(:state), updated_at: effect.fetch(:updated_at)
          ).update(state: "submitted", evidence_json: encoded, updated_at: now)
          if count == 1
            add_logical_bytes!(
              connection, receipt.fetch(:namespace_id),
              encoded.bytesize - effect[:evidence_json].to_s.bytesize
            )
          end
          count
        end
        raise Hive::CommandConflict, "command effect submission changed" unless changed == 1
        true
      end

      def record_effect_observation(receipt_id:, effect_id:, principal:, request_fingerprint:,
                                    generation:, source:, correlation_id:, evidence: {})
        observation = {
          "source" => source.to_s, "correlation_id" => correlation_id.to_s,
          "evidence" => Hive::RuntimeControlPlane::Codec.normalize(evidence)
        }
        if observation["source"].empty? || observation["correlation_id"].empty?
          raise Hive::UsageError, "command effect observation requires source and correlation identity"
        end
        now = timestamp
        changed = database.transaction do |connection|
          receipt = connection[:command_receipts][receipt_id: receipt_id.to_s]
          next 0 unless receipt && receipt.fetch(:state) == "executing" &&
                        receipt.fetch(:generation) == Integer(generation) &&
                        receipt.fetch(:principal) == principal.to_s &&
                        receipt.fetch(:request_fingerprint) == request_fingerprint.to_s
          effect = connection[:command_effects][effect_id: effect_id.to_s, receipt_id: receipt_id.to_s]
          next 0 unless effect && %w[prepared submitted unknown].include?(effect.fetch(:state))
          prior = effect[:evidence_json] ?
            Hive::RuntimeControlPlane::Codec.load_json(effect.fetch(:evidence_json)) : {}
          observations = Array(prior["observations"])
          observations << observation unless observations.include?(observation)
          encoded = Hive::RuntimeControlPlane::Codec.dump_json(
            prior.merge("observations" => observations)
          )
          count = connection[:command_effects].where(
            effect_id: effect_id.to_s, receipt_id: receipt_id.to_s,
            state: effect.fetch(:state), updated_at: effect.fetch(:updated_at)
          ).update(evidence_json: encoded, updated_at: now)
          if count == 1
            add_logical_bytes!(
              connection, receipt.fetch(:namespace_id),
              encoded.bytesize - effect[:evidence_json].to_s.bytesize
            )
          end
          count
        end
        raise Hive::CommandConflict, "command effect observation changed" unless changed == 1
        true
      end
    end
  end
end
