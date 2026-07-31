require "hive/patrol/state_store"

module Hive
  module Modules
    module Migration
      # Qualification-only StateStore seam for injecting faults at durable
      # effect and reconciliation boundaries.
      class QualificationFaultingStateStore < Hive::Patrol::StateStore
        AFTER_EFFECT_INTENT = :after_effect_intent
        BEFORE_EFFECT_SETTLEMENT = :before_effect_settlement
        DURING_RECONCILIATION = :during_reconciliation
        CHECKPOINT_PHASES = [
          AFTER_EFFECT_INTENT,
          BEFORE_EFFECT_SETTLEMENT,
          DURING_RECONCILIATION
        ].freeze

        def initialize(project_root, checkpoint: nil, **options)
          unless checkpoint.nil? || checkpoint.respond_to?(:call)
            raise ArgumentError, "checkpoint must be callable"
          end

          @qualification_checkpoint = checkpoint
          super(project_root, **options)
        end

        def prepare_effect!(intent, now: Time.now.utc)
          result = super
          qualification_checkpoint(
            AFTER_EFFECT_INTENT,
            identity: effect_identity(intent),
            result: result
          ) if @qualification_checkpoint
          result
        end

        def settle_effect!(intent, status:, outcome:, now: Time.now.utc)
          if @qualification_checkpoint
            qualification_checkpoint(
              BEFORE_EFFECT_SETTLEMENT,
              identity: effect_identity(intent),
              result: {
                "effect_state" => effect_state(intent),
                "status" => status.to_s,
                "outcome" => outcome
              }
            )
          end
          super
        end

        private

        def reconcile_fingerprint_mapping(fingerprint, set:, deleted:,
                                          replace: false)
          result = super
          qualification_checkpoint(
            DURING_RECONCILIATION,
            identity: { "fingerprint" => fingerprint.to_s },
            result: result
          ) if @qualification_checkpoint
          result
        end

        def qualification_checkpoint(phase, identity:, result:)
          payload =
            Hive::Modules::Migration::PatrolEvidence.immutable_json(
              {
                "identity" => identity,
                "result" => result
              },
              label: "patrol qualification checkpoint"
            )
          @qualification_checkpoint.call(phase, payload)
        end

        def effect_identity(intent)
          {
            "intent_id" => intent.intent_id.to_s,
            "module" => intent.module_name.to_s,
            "occurrence_id" => intent.occurrence_id.to_s,
            "sink" => intent.sink.to_s,
            "target" => intent.target.to_s,
            "idempotency_key" => intent.idempotency_key.to_s
          }
        end
      end
    end
  end
end
