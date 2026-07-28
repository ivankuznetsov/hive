module Hive
  module Modules
    module Migration
      # Sender lease, dispatch fencing, exact reconciliation, and terminal
      # settlement protocol. Authorization and receipt projection are injected
      # collaborators so this class owns only delivery state transitions.
      class EffectSender
        def initialize(product_label:, delivery_store:, receipt_ledger:,
                       reconciliation_error:, pass_intent:,
                       not_delivered_error:, clock:, lease_sec:, claimant:)
          @product_label = product_label
          @delivery_store = delivery_store
          @receipt_ledger = receipt_ledger
          @reconciliation_error = reconciliation_error
          @pass_intent = pass_intent == true
          @not_delivered_error = not_delivered_error
          @clock = clock
          @lease_sec = positive_lease(lease_sec)
          @claimant = claimant
        end

        def prepare(intent)
          @delivery_store.prepare_effect!(intent, now: @clock.call)
        end

        def replay_if_terminal(intent)
          return unless @receipt_ledger.terminal_result(intent)

          @receipt_ledger.replay_terminal(intent)
        end

        def deliver_or_reconcile(intent, reconcile, effect)
          claim = acquire(intent)
          handle_claim(intent, claim, reconcile, effect)
        end

        def reconcile_observed(intent, reconcile)
          claim = acquire(intent)
          case claim.status
          when :terminal
            @receipt_ledger.replay_terminal(intent)
          when :busy
            reconciliation_required!(
              "active_sender_lease",
              @receipt_ledger.receipt_for_claim(intent, claim)
            )
          when :acquired
            fence_dispatch(intent, claim)
            reconcile_uncertain(
              intent,
              claim,
              reconcile,
              nil,
              send_after_absence: false
            )
          when :reconcile
            reconcile_uncertain(
              intent,
              claim,
              reconcile,
              nil,
              send_after_absence: false
            )
          else
            unrecognized_disposition!
          end
        end

        private

        def handle_claim(intent, claim, reconcile, effect)
          case claim.status
          when :terminal
            @receipt_ledger.replay_terminal(intent)
          when :busy
            reconciliation_required!(
              "active_sender_lease",
              @receipt_ledger.receipt_for_claim(intent, claim)
            )
          when :reconcile
            reconcile_uncertain(intent, claim, reconcile, effect)
          when :acquired
            dispatch_claimed(intent, claim, effect)
          else
            unrecognized_disposition!
          end
        end

        def acquire(intent)
          @delivery_store.acquire_effect!(
            intent,
            claimant: @claimant,
            now: @clock.call,
            lease_sec: @lease_sec
          )
        end

        def reconcile_uncertain(intent, claim, reconcile, effect,
                                send_after_absence: true)
          reconciliation = exact_reconciliation(intent, reconcile)
          case reconciliation.fetch("status")
          when "matched"
            settle_reconciled(intent, claim, reconciliation)
          when "absent"
            settle_absent(
              intent,
              claim,
              reconciliation,
              effect,
              send_after_absence: send_after_absence
            )
          else
            reconciliation_required!(
              "remote_identity_ambiguous",
              @receipt_ledger.receipt_for_claim(intent, claim)
            )
          end
        end

        def settle_reconciled(intent, claim, reconciliation)
          outcome = reconciliation.fetch("outcome", {})
          receipt = @receipt_ledger.build(
            intent, "reconciled", outcome
          )
          state = @delivery_store.settle_effect_reconciled!(
            intent,
            expected_generation: claim.generation,
            outcome: outcome,
            receipt: receipt,
            now: @clock.call
          )
          @receipt_ledger.drain(intent)
          @receipt_ledger.terminal_result_from_state(intent, state)
        end

        def settle_absent(intent, claim, reconciliation, effect,
                          send_after_absence:)
          outcome = reconciliation.fetch("outcome", {})
          receipt = @receipt_ledger.build(
            intent, "known_not_sent", outcome
          )
          @delivery_store.resolve_effect_absent!(
            intent,
            expected_generation: claim.generation,
            outcome: outcome,
            receipt: receipt,
            now: @clock.call
          )
          @receipt_ledger.drain(intent)
          unless send_after_absence
            return @receipt_ledger.known_not_sent(
              intent, outcome, receipt
            )
          end

          fresh = acquire(intent)
          return dispatch_claimed(intent, fresh, effect) if
            fresh.status == :acquired

          reconciliation_required!(
            "sender_lease_raced_after_reconciliation",
            @receipt_ledger.receipt_for_claim(intent, fresh)
          )
        end

        def dispatch_claimed(intent, claim, effect)
          fence_dispatch(intent, claim)
          outcome = invoke_effect(effect, intent)
          unless outcome.is_a?(Hash)
            raise Hive::ConfigError,
                  "#{@product_label} effect outcome must be an object"
          end
          receipt = @receipt_ledger.build(
            intent, "committed", outcome
          )
          state = @delivery_store.settle_effect_claimed!(
            intent,
            token: claim.token,
            status: "committed",
            outcome: outcome,
            receipt: receipt,
            now: @clock.call
          )
          @receipt_ledger.drain(intent)
          @receipt_ledger.terminal_result_from_state(intent, state)
        rescue StandardError => e
          raise unless @not_delivered_error&.=== e

          settle_not_delivered(intent, claim, e)
        end

        def fence_dispatch(intent, claim)
          @delivery_store.mark_dispatch_uncertain!(
            intent, token: claim.token, now: @clock.call
          )
        end

        def invoke_effect(effect, intent)
          @pass_intent ? effect.call(intent) : effect.call
        end

        def settle_not_delivered(intent, claim, error)
          outcome = { "reason" => error.message.to_s }
          receipt = @receipt_ledger.build(
            intent, "known_not_sent", outcome
          )
          @delivery_store.resolve_effect_absent!(
            intent,
            expected_generation: claim.generation,
            outcome: outcome,
            receipt: receipt,
            now: @clock.call
          )
          @receipt_ledger.drain(intent)
          @receipt_ledger.known_not_sent(intent, outcome, receipt)
        end

        def exact_reconciliation(intent, reconcile)
          unless reconcile
            return { "status" => "ambiguous", "outcome" => {} }
          end

          result = reconcile.call(intent)
          valid = result.is_a?(Hash) &&
                  %w[matched absent ambiguous].include?(result["status"]) &&
                  result.fetch("outcome", {}).is_a?(Hash)
          valid ? result :
            { "status" => "ambiguous", "outcome" => {} }
        rescue StandardError
          { "status" => "ambiguous", "outcome" => {} }
        end

        def positive_lease(value)
          lease = Integer(value)
          return lease if lease.positive?

          raise Hive::ConfigError,
                "#{@product_label} effect lease must be positive"
        rescue ArgumentError, TypeError
          raise Hive::ConfigError,
                "#{@product_label} effect lease is malformed"
        end

        def unrecognized_disposition!
          reconciliation_required!(
            "#{@product_label} sender disposition is unrecognized",
            nil
          )
        end

        def reconciliation_required!(reason, receipt)
          raise @reconciliation_error.new(reason, receipt)
        end
      end
    end
  end
end
