require "hive/modules/migration/occurrence_outbox"

module Hive
  module Modules
    module Migration
      # The persisted effect state machine. Sender liveness is deliberately
      # absent from this record: StableProcessLock is the sole live-sender
      # authority, while this class records only crash-recovery facts.
      class OccurrenceEffects
        include OccurrenceContract

        def initialize(store:, validator:, outbox:)
          @store = store
          @validator = validator
          @outbox = outbox
        end

        def prepare(intent, now:)
          intent = @validator.intent(intent)
          @store.mutate(intent.occurrence_id) do |record|
            unless record.fetch("phase") == "reserved"
              malformed!(
                "finalized patrol occurrence rejects new effect dispatch"
              )
            end
            effects = record.fetch("effects")
            existing = effects[intent.intent_id]
            if existing
              validate_effect_identity!(existing, intent)
              remember_authorization!(existing, intent)
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

        def mark_uncertain(intent, now:)
          mutate_nonterminal(intent, now: now) do |record, cell|
            unless cell.fetch("state") == "prepared"
              malformed!("patrol effect is not dispatchable")
            end
            cell["state"] = "dispatch_uncertain"
            touch_cell(record, cell, now)
          end
        end

        def reset_prepared(intent, now:)
          mutate_nonterminal(intent, now: now) do |record, cell|
            unless cell.fetch("state") == "dispatch_uncertain"
              malformed!(
                "patrol effect absence cannot reset this delivery state"
              )
            end
            cell["state"] = "prepared"
            cell["outcome"] = {}
            touch_cell(record, cell, now)
          end
        end

        def settle(intent, status:, outcome:, now:, projections: [])
          status = status.to_s
          unless TERMINAL_STATES.include?(status)
            malformed!("patrol effect terminal status is malformed")
          end
          intent = @validator.intent(intent)
          outcome = @validator.object(outcome, "patrol effect outcome")
          projections = validate_projections(projections)
          persisted = nil
          @store.mutate(intent.occurrence_id) do |record|
            cell = effect_cell!(record, intent)
            if TERMINAL_STATES.include?(cell.fetch("state"))
              assert_terminal_equivalent!(cell, status, outcome)
              persisted = terminal_receipt(record, cell)
              assert_terminal_projections!(
                record, persisted, projections
              )
              next record
            end
            unless record.fetch("phase") == "reserved" &&
                   cell.fetch("state") == "dispatch_uncertain"
              malformed!(
                "patrol effect was not fenced before settlement"
              )
            end
            persisted = terminalize!(
              record, cell, intent,
              status: status, outcome: outcome, now: now,
              projections: projections
            )
            record
          end
          persisted
        end

        def deny(intent, outcome:, now:)
          intent = @validator.intent(intent)
          outcome = @validator.object(outcome, "patrol effect outcome")
          persisted = nil
          @store.mutate(intent.occurrence_id) do |record|
            cell = effect_cell!(record, intent)
            if TERMINAL_STATES.include?(cell.fetch("state"))
              assert_terminal_equivalent!(cell, "denied", outcome)
              persisted = terminal_receipt(record, cell)
              next record
            end
            unless record.fetch("phase") == "reserved" &&
                   cell.fetch("state") == "prepared"
              malformed!(
                "uncertain patrol effect cannot be denied as unsent"
              )
            end
            persisted = terminalize!(
              record, cell, intent,
              status: "denied", outcome: outcome, now: now,
              projections: []
            )
            record
          end
          persisted
        end

        def receipt(receipt_id, occurrence_id:)
          record = @store.fetch(occurrence_id)
          malformed!("patrol occurrence is missing") unless record
          @outbox.receipt(record, receipt_id)
        end

        def assert_publication!(receipt)
          intent = @validator.intent(receipt.intent)
          receipt = @validator.receipt(
            receipt, intent: intent
          )
          record = @store.fetch(receipt.intent.occurrence_id)
          malformed!("patrol occurrence is missing") unless record
          @outbox.assert_publication(record, receipt)
          true
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
            "outcome" => {},
            "receipt_ids" => [],
            "terminal_receipt_id" => nil,
            "updated_at" => timestamp(now)
          }
        end

        def remember_authorization!(cell, intent)
          authorizations = cell.fetch("authorizations")
          stored = authorizations[intent.authorization_digest]
          if stored && stored != intent.to_h
            malformed!("patrol effect authorization conflicts")
          end
          authorizations[intent.authorization_digest] ||= intent.to_h
        end

        def mutate_nonterminal(intent, now:)
          intent = @validator.intent(intent)
          @store.mutate(intent.occurrence_id) do |record|
            unless record.fetch("phase") == "reserved"
              malformed!(
                "finalized patrol occurrence rejects effect dispatch"
              )
            end
            yield record, effect_cell!(record, intent)
          end
          state(intent)
        end

        def terminalize!(record, cell, intent, status:, outcome:, now:,
                         projections:)
          receipt = EffectReceipt.build(
            intent: intent,
            status: status,
            outcome: outcome,
            recorded_at: now
          )
          cell["state"] = status
          cell["outcome"] = outcome
          cell["terminal_receipt_id"] = receipt.receipt_id
          @outbox.append_receipt(record, cell, receipt)
          @outbox.append_publication(record, receipt) if
            projections.include?("publication")
          touch_cell(record, cell, now)
          terminal_receipt(record, cell)
        end

        def terminal_receipt(record, cell)
          @outbox.receipt(
            record, cell.fetch("terminal_receipt_id")
          )
        end

        def effect_cell!(record, intent)
          cell = record.dig("effects", intent.intent_id)
          malformed!("patrol effect intent is missing") unless cell
          validate_effect_identity!(cell, intent)
          cell
        end

        def assert_terminal_equivalent!(cell, status, outcome)
          return if cell.fetch("state") == status &&
                    cell.fetch("outcome") == outcome

          malformed!("patrol effect terminal outcome conflicts")
        end

        def validate_projections(value)
          projections = Array(value).map(&:to_s)
          unless projections.uniq == projections &&
                 (projections - %w[publication]).empty?
            malformed!("patrol effect projections are malformed")
          end
          projections.freeze
        end

        def assert_terminal_projections!(record, receipt, projections)
          @outbox.assert_publication(record, receipt) if
            projections.include?("publication")
        end

        def validate_effect_identity!(cell, intent)
          valid = cell.is_a?(Hash) &&
                  cell.fetch("intent_id") == intent.intent_id &&
                  cell.fetch("semantic") ==
                    @validator.semantic_intent(intent)
          malformed!("patrol effect intent conflicts") unless valid
          true
        rescue KeyError
          malformed!("patrol effect recovery state is malformed")
        end

        def touch_cell(record, cell, now)
          cell["updated_at"] = timestamp(now)
          touch(record, now)
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
