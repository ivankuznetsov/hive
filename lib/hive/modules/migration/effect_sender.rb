module Hive
  module Modules
    module Migration
      # Serializes one effect sender with a process mutex plus stable flock,
      # records uncertainty before invocation, and allows redispatch only when
      # the product gateway owns an explicit retry-safe sink contract.
      class EffectSender
        def initialize(product_label:, delivery_store:, receipt_ledger:,
                       reconciliation_error:, pass_intent:,
                       not_delivered_error:, retry_safe:, clock:)
          @product_label = product_label
          @delivery_store = delivery_store
          @receipt_ledger = receipt_ledger
          @reconciliation_error = reconciliation_error
          @pass_intent = pass_intent == true
          @not_delivered_error = not_delivered_error
          @retry_safe = retry_safe
          @clock = clock
        end

        def prepare(intent)
          @delivery_store.prepare_effect!(intent, now: @clock.call)
        end

        def replay_if_terminal(intent)
          result = @receipt_ledger.terminal_result(intent)
          return unless result

          @receipt_ledger.replay_terminal(intent, result)
        end

        def deliver_or_reconcile(intent, reconcile, effect)
          with_sender_lock(intent) do
            if (result = @receipt_ledger.terminal_result(intent))
              return @receipt_ledger.replay_terminal(intent, result)
            end

            case delivery_state(intent)
            when "prepared"
              dispatch_prepared(intent, effect)
            when "dispatch_uncertain"
              reconcile_uncertain(intent, reconcile, effect)
            else
              unrecognized_state!
            end
          end
        end

        def reconcile_observed(intent, reconcile)
          with_sender_lock(intent) do
            if (result = @receipt_ledger.terminal_result(intent))
              return @receipt_ledger.replay_terminal(intent, result)
            end

            state = delivery_state(intent)
            if state == "prepared"
              @delivery_store.mark_dispatch_uncertain!(
                intent, now: @clock.call
              )
            elsif state != "dispatch_uncertain"
              unrecognized_state!
            end
            reconcile_uncertain(
              intent, reconcile, nil, send_after_absence: false
            )
          end
        end

        private

        def with_sender_lock(intent, &block)
          @delivery_store.with_effect_sender_lock(intent, &block)
        end

        def delivery_state(intent)
          state = @delivery_store.effect_state(intent)
          state && state.fetch("state")
        rescue KeyError
          unrecognized_state!
        end

        def reconcile_uncertain(intent, reconcile, effect,
                                send_after_absence: true)
          reconciliation = exact_reconciliation(intent, reconcile)
          case reconciliation.fetch("status")
          when "matched"
            settle(intent, "reconciled", reconciliation.fetch("outcome", {}))
          when "absent"
            handle_absence(
              intent,
              reconciliation.fetch("outcome", {}),
              effect,
              send_after_absence: send_after_absence
            )
          else
            reconciliation_required!("remote_identity_ambiguous")
          end
        end

        def handle_absence(intent, outcome, effect, send_after_absence:)
          unless retry_safe?(intent)
            reconciliation_required!("remote_absence_not_retry_safe")
          end

          @delivery_store.reset_effect_prepared!(
            intent, now: @clock.call
          )
          return retry_safe_result(outcome) unless send_after_absence

          dispatch_prepared(intent, effect)
        end

        def dispatch_prepared(intent, effect)
          @delivery_store.mark_dispatch_uncertain!(
            intent, now: @clock.call
          )
          outcome = invoke_effect(effect, intent)
          unless outcome.is_a?(Hash)
            raise Hive::ConfigError,
                  "#{@product_label} effect outcome must be an object"
          end
          settle(intent, "committed", outcome)
        rescue StandardError => e
          raise unless @not_delivered_error&.=== e

          @delivery_store.reset_effect_prepared!(
            intent, now: @clock.call
          )
          retry_safe_result("reason" => e.message.to_s)
        end

        def settle(intent, status, outcome)
          receipt = @delivery_store.settle_effect!(
            intent,
            status: status,
            outcome: outcome,
            now: @clock.call
          )
          @receipt_ledger.drain(intent)
          @receipt_ledger.result_from_receipt(receipt)
        end

        def invoke_effect(effect, intent)
          @pass_intent ? effect.call(intent) : effect.call
        end

        def retry_safe?(intent)
          @retry_safe.respond_to?(:call) &&
            @retry_safe.call(intent) == true
        rescue StandardError
          false
        end

        def retry_safe_result(outcome)
          EffectReceiptLedger::Result.new(
            status: :retry_safe,
            outcome: outcome,
            receipt: nil
          )
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

        def unrecognized_state!
          reconciliation_required!(
            "#{@product_label} sender state is unrecognized"
          )
        end

        def reconciliation_required!(reason)
          raise @reconciliation_error.new(reason, nil)
        end
      end
    end
  end
end
