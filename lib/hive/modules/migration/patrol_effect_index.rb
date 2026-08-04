require "hive/modules/migration/patrol_evidence"

module Hive
  module Modules
    module Migration
      class PatrolEffectIndex < Data.define(
        :observed_receipt_ids, :effect_receipt_ids, :duplicate_effects,
        :unsettled_effects, :replay_count
      )
        MAX_RECEIPTS = 4_096
        TERMINAL_EFFECT_STATUSES = %w[committed reconciled].freeze
        UNSETTLED_EFFECT_STATUSES = %w[attempted unknown].freeze
        LOCAL_TRANSITION_SINKS = %w[job discovery action].freeze

        class << self
          def build(receipts:)
            observed = []
            effects = []
            duplicates = []
            unsettled = []
            replay_count = 0
            seen_receipts = {}
            identities = {
              intent: {}, idempotency: {}, semantic: {}
            }

            receipts.each do |value|
              malformed! if observed.size >= MAX_RECEIPTS
              receipt = coerce(value)
              observed << receipt.receipt_id
              if seen_receipts.key?(receipt.receipt_id)
                replay_count += 1
                next
              end
              seen_receipts[receipt.receipt_id] = true
              if UNSETTLED_EFFECT_STATUSES.include?(receipt.status)
                unsettled << receipt.receipt_id
              end
              next unless TERMINAL_EFFECT_STATUSES.include?(receipt.status)

              keys = identity_keys(receipt)
              collisions = keys.filter_map do |kind, identity|
                "#{kind}:#{identity}" if identities.fetch(kind).key?(identity)
              end
              if collisions.empty?
                effects << receipt.receipt_id
              else
                duplicates.concat(collisions)
              end
              keys.each do |kind, identity|
                identities.fetch(kind)[identity] ||= receipt.receipt_id
              end
            end

            new(
              observed_receipt_ids: observed.freeze,
              effect_receipt_ids: effects.sort.freeze,
              duplicate_effects: duplicates.uniq.sort.freeze,
              unsettled_effects: unsettled.sort.freeze,
              replay_count: replay_count
            )
          rescue NoMethodError, TypeError
            malformed!
          end

          private

          def coerce(value)
            value.is_a?(EffectReceipt) ?
              EffectReceipt.from_h(value.to_h) : EffectReceipt.from_h(value)
          rescue Hive::ConfigError
            malformed!
          end

          def identity_keys(receipt)
            intent = receipt.intent
            keys = {
              intent: intent.intent_id,
              idempotency: PatrolEvidence.digest(
                "effect-key",
                {
                  "module" => intent.module_name,
                  "sink" => intent.sink,
                  "idempotency_key" => intent.idempotency_key
                }
              )
            }
            unless intent.module_name == "architecture-patrol" &&
                   LOCAL_TRANSITION_SINKS.include?(intent.sink)
              keys[:semantic] = PatrolEvidence.digest(
                "effect-semantic",
                {
                  "module" => intent.module_name,
                  "sink" => intent.sink,
                  "target" => intent.target,
                  "scope" => intent.scope
                }
              )
            end
            keys
          end

          def malformed!
            raise Hive::ConfigError, "patrol effect index is malformed"
          end
        end

        def effect_count = effect_receipt_ids.size
        def valid? = duplicate_effects.empty? && unsettled_effects.empty?

        def to_h
          {
            "observed_receipt_ids" => observed_receipt_ids,
            "effect_receipt_ids" => effect_receipt_ids,
            "duplicate_effects" => duplicate_effects,
            "unsettled_effects" => unsettled_effects,
            "replay_count" => replay_count
          }.freeze
        end
      end
    end
  end
end
