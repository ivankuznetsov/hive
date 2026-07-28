require "securerandom"
require "time"
require "hive/modules/migration/occurrence_outbox"

module Hive
  module Modules
    module Migration
      # Sender-CAS and terminal-effect state transitions. Every mutation goes
      # through OccurrenceRecordStore; this collaborator has no persistence
      # path of its own.
      class OccurrenceEffects
        include OccurrenceContract

        Claim = Data.define(
          :status,
          :token,
          :generation,
          :delivery_state,
          :outcome,
          :receipt
        )

        def initialize(store:, validator:, outbox:)
          @store = store
          @validator = validator
          @outbox = outbox
        end

        def prepare(intent, now:)
          intent = @validator.intent(intent)
          @store.mutate(intent.occurrence_id) do |record|
            effects = record.fetch("effects")
            existing = effects[intent.intent_id]
            if existing
              validate_effect_identity!(existing, intent)
              authorizations = existing.fetch("authorizations")
              stored = authorizations[
                intent.authorization_digest
              ]
              if stored && stored != intent.to_h
                malformed!(
                  "patrol effect authorization conflicts"
                )
              end
              authorizations[
                intent.authorization_digest
              ] ||= intent.to_h
            else
              if effects.size >=
                 PatrolEvidence::MAX_EFFECTS_PER_OCCURRENCE
                malformed!(
                  "patrol occurrence effect limit exceeded"
                )
              end
              effects[intent.intent_id] = build_cell(intent, now)
            end
            touch(record, now)
          end
          state(intent)
        end

        def state(intent)
          intent = @validator.intent(intent)
          record = @store.fetch(intent.occurrence_id)
          malformed!("patrol occurrence is missing") unless record
          cell = record.dig("effects", intent.intent_id)
          return nil unless cell

          validate_effect_identity!(cell, intent)
          @validator.copy(cell)
        end

        def acquire(intent, claimant:, now:, lease_sec:)
          intent = @validator.intent(intent)
          claimant = @validator.nonempty(
            claimant, "patrol effect claimant"
          )
          lease_sec = @validator.positive_integer(
            lease_sec, "patrol effect lease"
          )
          result = nil
          @store.mutate(intent.occurrence_id) do |record|
            cell = effect_cell!(record, intent)
            current = cell.fetch("state")
            if TERMINAL_STATES.include?(current)
              result = claim_result(:terminal, cell)
              next record
            end
            if %w[leased dispatch_uncertain].include?(current)
              result = existing_claim_disposition(
                cell, now: now
              )
              next touch(record, now)
            end

            generation = cell.fetch("delivery_generation") + 1
            token = SecureRandom.hex(24)
            cell["delivery_generation"] = generation
            cell["claim"] = {
              "token" => token,
              "claimant" => claimant,
              "generation" => generation,
              "acquired_at" => timestamp(now),
              "expires_at" => timestamp(now + lease_sec)
            }
            cell["state"] = "leased"
            cell["updated_at"] = timestamp(now)
            result = claim_result(:acquired, cell)
            touch(record, now)
          end
          result
        rescue ArgumentError, TypeError
          malformed!("patrol effect claim is malformed")
        end

        def mark_uncertain(intent, token:, now:)
          transition_claimed(intent, token: token) do |record, cell|
            unless cell.fetch("state") == "leased"
              malformed!(
                "patrol effect sender lease is not dispatchable"
              )
            end
            cell["state"] = "dispatch_uncertain"
            cell["updated_at"] = timestamp(now)
            touch(record, now)
          end
        end

        def resolve_absent(intent, expected_generation:, outcome:,
                           receipt:, now:)
          intent = @validator.intent(intent)
          receipt = @validator.receipt(receipt, intent: intent)
          outcome = @validator.object(
            outcome, "patrol effect outcome"
          )
          @store.mutate(intent.occurrence_id) do |record|
            cell = effect_cell!(record, intent)
            unless cell.fetch("state") ==
                     "dispatch_uncertain" &&
                   cell.fetch("delivery_generation") ==
                     Integer(expected_generation)
              malformed!(
                "patrol effect reconciliation fence is stale"
              )
            end
            cell["state"] = "known_not_sent"
            cell["claim"] = nil
            cell["outcome"] = outcome
            @outbox.append_receipt(record, cell, receipt)
            cell["updated_at"] = timestamp(now)
            touch(record, now)
          end
          state(intent)
        rescue ArgumentError, TypeError
          malformed!(
            "patrol effect reconciliation fence is malformed"
          )
        end

        def settle_reconciled(intent, expected_generation:, outcome:,
                              receipt:, now:)
          intent = @validator.intent(intent)
          receipt = @validator.receipt(receipt, intent: intent)
          outcome = @validator.object(
            outcome, "patrol effect outcome"
          )
          @store.mutate(intent.occurrence_id) do |record|
            cell = effect_cell!(record, intent)
            if TERMINAL_STATES.include?(cell.fetch("state"))
              assert_terminal_equivalent!(
                cell, "reconciled", outcome, receipt
              )
              next record
            end
            unless cell.fetch("state") ==
                     "dispatch_uncertain" &&
                   cell.fetch("delivery_generation") ==
                     Integer(expected_generation)
              malformed!(
                "patrol effect reconciliation fence is stale"
              )
            end
            terminalize!(
              record,
              cell,
              status: "reconciled",
              outcome: outcome,
              receipt: receipt,
              now: now
            )
          end
          state(intent)
        rescue ArgumentError, TypeError
          malformed!(
            "patrol effect reconciliation fence is malformed"
          )
        end

        def settle_claimed(intent, token:, status:, outcome:, receipt:,
                           now:)
          status = status.to_s
          unless TERMINAL_STATES.include?(status)
            malformed!(
              "patrol effect terminal status is malformed"
            )
          end
          intent = @validator.intent(intent)
          receipt = @validator.receipt(receipt, intent: intent)
          outcome = @validator.object(
            outcome, "patrol effect outcome"
          )
          transition_claimed(intent, token: token) do |record, cell|
            unless cell.fetch("state") ==
                   "dispatch_uncertain"
              malformed!(
                "patrol effect was not fenced before settlement"
              )
            end
            terminalize!(
              record,
              cell,
              status: status,
              outcome: outcome,
              receipt: receipt,
              now: now
            )
          end
          state(intent)
        end

        def deny(intent, outcome:, receipt:, now:)
          intent = @validator.intent(intent)
          receipt = @validator.receipt(receipt, intent: intent)
          outcome = @validator.object(
            outcome, "patrol effect outcome"
          )
          @store.mutate(intent.occurrence_id) do |record|
            cell = effect_cell!(record, intent)
            if TERMINAL_STATES.include?(cell.fetch("state"))
              next record
            end
            unless %w[
              prepared known_not_sent
            ].include?(cell.fetch("state"))
              @outbox.append_receipt(record, cell, receipt)
              next touch(record, now)
            end
            terminalize!(
              record,
              cell,
              status: "denied",
              outcome: outcome,
              receipt: receipt,
              now: now
            )
          end
          state(intent)
        end

        def receipt(receipt_id, occurrence_id:)
          record = @store.fetch(occurrence_id)
          malformed!("patrol occurrence is missing") unless record
          @outbox.receipt(record, receipt_id)
        end

        def terminal_receipt_ids(occurrence_id)
          record = @store.fetch(occurrence_id)
          malformed!("patrol occurrence is missing") unless record
          record.fetch("effects").values.filter_map do |cell|
            cell["terminal_receipt_id"]
          end.sort.freeze
        end

        private

        def build_cell(intent, now)
          {
            "intent_id" => intent.intent_id,
            "semantic" => @validator.semantic_intent(intent),
            "authorizations" => {
              intent.authorization_digest => intent.to_h
            },
            "state" => "prepared",
            "delivery_generation" => 0,
            "claim" => nil,
            "outcome" => {},
            "receipt_ids" => [],
            "terminal_receipt_id" => nil,
            "updated_at" => timestamp(now)
          }
        end

        def existing_claim_disposition(cell, now:)
          claim = cell.fetch("claim")
          unless claim.is_a?(Hash)
            malformed!("patrol effect claim is malformed")
          end
          disposition = Time.iso8601(
            claim.fetch("expires_at")
          ) > now ? :busy : :reconcile
          if disposition == :reconcile &&
             cell.fetch("state") == "leased"
            cell["state"] = "dispatch_uncertain"
            cell["updated_at"] = timestamp(now)
          end
          claim_result(disposition, cell)
        end

        def terminalize!(record, cell, status:, outcome:, receipt:,
                         now:)
          unless receipt.status == status &&
                 receipt.outcome == outcome
            malformed!(
              "patrol effect receipt contradicts its terminal outcome"
            )
          end
          cell["state"] = status
          cell["claim"] = nil
          cell["outcome"] = outcome
          cell["terminal_receipt_id"] = receipt.receipt_id
          @outbox.append_receipt(record, cell, receipt)
          cell["updated_at"] = timestamp(now)
          touch(record, now)
        end

        def transition_claimed(intent, token:)
          intent = @validator.intent(intent)
          token = @validator.nonempty(
            token, "patrol effect claim token"
          )
          @store.mutate(intent.occurrence_id) do |record|
            cell = effect_cell!(record, intent)
            claim = cell.fetch("claim")
            unless claim.is_a?(Hash) &&
                   claim.fetch("token") == token
              malformed!("patrol effect sender lease is stale")
            end
            yield record, cell
          end
        end

        def claim_result(status, cell)
          Claim.new(
            status: status,
            token: cell.dig("claim", "token"),
            generation: cell.fetch("delivery_generation"),
            delivery_state: cell.fetch("state"),
            outcome: @validator.copy(cell.fetch("outcome")),
            receipt: cell["terminal_receipt_id"]
          )
        end

        def effect_cell!(record, intent)
          cell = record.dig("effects", intent.intent_id)
          malformed!("patrol effect intent is missing") unless cell
          validate_effect_identity!(cell, intent)
          cell
        end

        def assert_terminal_equivalent!(cell, status, outcome, receipt)
          valid = cell.fetch("state") == status &&
                  cell.fetch("outcome") == outcome &&
                  cell.fetch("terminal_receipt_id") ==
                    receipt.receipt_id
          unless valid
            malformed!(
              "patrol effect terminal outcome conflicts"
            )
          end
        end

        def validate_effect_identity!(cell, intent)
          valid = cell.is_a?(Hash) &&
                  cell.fetch("intent_id") == intent.intent_id &&
                  cell.fetch("semantic") ==
                    @validator.semantic_intent(intent)
          unless valid
            malformed!("patrol effect intent conflicts")
          end
          true
        rescue KeyError
          malformed!("patrol effect recovery state is malformed")
        end

        def timestamp(value)
          @validator.timestamp(value)
        end

        def touch(record, now)
          record["updated_at"] = timestamp(now)
          record
        end

        def malformed!(message)
          raise Hive::ConfigError, message
        end
      end
    end
  end
end
