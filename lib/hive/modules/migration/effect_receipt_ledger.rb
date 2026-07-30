require "hive/modules/migration/patrol_evidence"
require "hive/modules/migration/occurrence_record_validator"

module Hive
  module Modules
    module Migration
      # Materializes terminal results and projects canonical receipts from the
      # delivery store into the evidence store. It does not decide sender
      # transitions or authorization policy.
      class EffectReceiptLedger
        Result = Data.define(:status, :outcome, :receipt)
        TERMINAL_STATES = OccurrenceContract::TERMINAL_STATES

        def initialize(delivery_store:, evidence_store:, denied_error:,
                       clock:)
          @delivery_store = delivery_store
          @evidence_store = evidence_store
          @denied_error = denied_error
          @clock = clock
        end

        def terminal_result(intent)
          state = @delivery_store.effect_state(intent)
          return unless state &&
                        TERMINAL_STATES.include?(state["state"])

          terminal_result_from_state(intent, state)
        end

        def replay_terminal(intent, result = terminal_result(intent))
          return unless result

          drain(intent)
          result
        end

        def terminal_result_from_state(intent, state)
          status = state.fetch("state")
          receipt = @delivery_store.effect_receipt(
            state.fetch("terminal_receipt_id"),
            occurrence_id: intent.occurrence_id
          )
          result_from_receipt(
            receipt,
            expected_status: status,
            expected_outcome: state.fetch("outcome")
          )
        end

        def result_from_receipt(receipt, expected_status: nil,
                                expected_outcome: nil)
          status = receipt.status
          outcome = receipt.outcome
          if (expected_status && status != expected_status) ||
             (expected_outcome && outcome != expected_outcome)
            raise Hive::ConfigError,
                  "patrol effect receipt contradicts persisted state"
          end
          if status == "denied"
            raise @denied_error.new(
              outcome.fetch("reason", "denied"), receipt
            )
          end
          Result.new(
            status: status.to_sym,
            outcome: outcome,
            receipt: receipt
          )
        end

        def deny!(intent, reason)
          reason = reason.to_s
          outcome = { "reason" => reason }
          receipt = @delivery_store.deny_effect!(
            intent,
            outcome: outcome,
            now: @clock.call
          )
          drain(intent)
          raise @denied_error.new(reason, receipt)
        end

        def shadow_denial!(intent, reason)
          outcome = { "attempted" => true, "reason" => reason }
          receipt = EffectReceipt.build(
            intent: intent,
            status: "attempted",
            outcome: outcome,
            recorded_at: @clock.call
          )
          @evidence_store.append_receipt(receipt)
          raise @denied_error.new(reason, receipt)
        end

        def drain(intent)
          @delivery_store.drain_occurrence_outbox!(
            intent.occurrence_id,
            evidence_store: @evidence_store,
            kinds: [ "receipt" ]
          )
        end
      end
    end
  end
end
