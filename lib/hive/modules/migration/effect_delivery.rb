require "securerandom"
require "hive/modules/migration/effect_admission"
require "hive/modules/migration/effect_receipt_ledger"
require "hive/modules/migration/effect_sender"

module Hive
  module Modules
    module Migration
      # Product-neutral facade that binds intent identity, live admission, the
      # sender protocol, and canonical receipt projection. Product gateways
      # retain distinct APIs while sharing these collaborators by composition.
      class EffectDelivery
        Result = EffectReceiptLedger::Result

        def initialize(module_name:, product_label:, config_key:,
                       project_root:, hive_state_path:, capture:, authority:,
                       evidence_store:, delivery_store:, denied_error:,
                       reconciliation_error:, migration_lock:,
                       ownership_loader:, config_loader: nil,
                       capability_checker: nil, claim_validator: nil,
                       module_execution: nil, lifecycle_store_factory: nil,
                       diagnostic_transition: false, pass_intent: false,
                       not_delivered_error: nil, clock: -> { Time.now.utc },
                       lease_sec: 300, claimant: nil)
          @module_name = module_name.to_s.freeze
          @product_label = product_label.to_s.freeze
          @capture = validate_capture(capture)
          @authority = authority.to_s
          validate_authority!
          project_root = File.expand_path(project_root)
          hive_state_path = File.expand_path(hive_state_path)
          @admission = EffectAdmission.new(
            module_name: @module_name,
            product_label: @product_label,
            config_key: config_key.to_s.freeze,
            project_root: project_root,
            hive_state_path: hive_state_path,
            capture: @capture,
            authority: @authority,
            migration_lock: migration_lock,
            ownership_loader: ownership_loader,
            config_loader: config_loader,
            capability_checker: capability_checker,
            claim_validator: claim_validator,
            module_execution: module_execution,
            lifecycle_store_factory: lifecycle_store_factory,
            diagnostic_transition: diagnostic_transition
          )
          @receipt_ledger = EffectReceiptLedger.new(
            delivery_store: delivery_store,
            evidence_store: evidence_store,
            denied_error: denied_error,
            clock: clock
          )
          claimant ||= [
            "#{@module_name}-effect",
            Process.pid,
            Thread.current.object_id,
            SecureRandom.hex(12)
          ].join(":")
          @sender = EffectSender.new(
            product_label: @product_label,
            delivery_store: delivery_store,
            receipt_ledger: @receipt_ledger,
            reconciliation_error: reconciliation_error,
            pass_intent: pass_intent,
            not_delivered_error: not_delivered_error,
            clock: clock,
            lease_sec: lease_sec,
            claimant: claimant
          )
        end

        def perform!(sink:, target:, idempotency_key:, capability:,
                     claim_generation: nil, scope: {}, reconcile: nil,
                     &effect)
          raise ArgumentError, "an effect block is required" unless effect

          intent = build_intent(
            sink: sink,
            target: target,
            idempotency_key: idempotency_key,
            capability: capability,
            claim_generation: claim_generation,
            scope: scope
          )
          return shadow_attempt(intent) if @authority == "shadow"

          @sender.prepare(intent)
          if (result = @sender.replay_if_terminal(intent))
            return result
          end

          with_live_authorization(intent) do
            @sender.deliver_or_reconcile(
              intent, reconcile, effect
            )
          end
        end

        # Reconcile-only adoption never enters a sender block. It exists for
        # hosted effects that predate the local occurrence journal.
        def reconcile!(sink:, target:, idempotency_key:, capability:,
                       claim_generation: nil, scope: {}, &reconcile)
          unless reconcile
            raise ArgumentError, "a reconciliation block is required"
          end

          intent = build_intent(
            sink: sink,
            target: target,
            idempotency_key: idempotency_key,
            capability: capability,
            claim_generation: claim_generation,
            scope: scope
          )
          return shadow_attempt(intent) if @authority == "shadow"

          @sender.prepare(intent)
          if (result = @sender.replay_if_terminal(intent))
            return result
          end

          with_live_authorization(intent) do
            @sender.reconcile_observed(intent, reconcile)
          end
        end

        private

        def validate_capture(capture)
          unless capture.is_a?(PatrolCapture) &&
                 capture.module_name == @module_name
            raise Hive::ConfigError,
                  "#{@product_label} effect capture is malformed"
          end
          capture
        end

        def validate_authority!
          return if PatrolEvidence::AUTHORITIES.include?(@authority)

          raise Hive::ConfigError,
                "#{@product_label} effect authority is malformed"
        end

        def build_intent(sink:, target:, idempotency_key:, capability:,
                         claim_generation:, scope:)
          EffectIntent.build(
            module_name: @module_name,
            occurrence_id: @capture.occurrence_id,
            authority: @authority,
            owner_epoch: @capture.owner_epoch,
            sink: sink,
            target: target,
            idempotency_key: idempotency_key,
            capability: capability,
            claim_generation: claim_generation,
            scope: scope,
            created_at: @capture.recorded_at
          )
        end

        def with_live_authorization(intent, &block)
          @admission.with_live_authorization(
            intent,
            on_denied: lambda do |reason|
              @receipt_ledger.deny!(intent, reason)
            end,
            &block
          )
        end

        def shadow_attempt(intent)
          @admission.with_shadow_denial do |reason|
            @receipt_ledger.shadow_denial!(intent, reason)
          end
        end
      end
    end
  end
end
