require "hive/modules/migration/shadow_comparator"

module Hive
  module Modules
    module Migration
      class PatrolEffectIndex < Data.define(
        :entries, :duplicate_keys, :counts, :digest
      )
        class << self
          def build(records:)
            validator = ShadowComparator.new(root: Dir.pwd)
            entries = []
            seen = 0
            records.each do |value|
              seen += 1
              if seen > ShadowComparator::MAX_RECORDS
                raise Hive::ConfigError,
                      "module shadow evidence exceeds the bounded read limit"
              end
              record = validator.validate_record!(value)
              append_entries(entries, record, "legacy")
              append_entries(entries, record, "module")
            end
            entries.sort_by! do |entry|
              [
                entry.fetch("effect_key"),
                entry.fetch("receipt_id"),
                entry.fetch("decision_id"),
                entry.fetch("channel")
              ]
            end
            entries.freeze
            duplicate_keys = entries
              .map { |entry| entry.fetch("effect_key") }
              .tally
              .select { |_key, count| count > 1 }
              .keys
              .sort
              .freeze
            counts = {
              "legacy" =>
                entries.count { |entry| entry["channel"] == "legacy" },
              "module" =>
                entries.count { |entry| entry["channel"] == "module" },
              "total" => entries.length
            }.freeze
            digest = PatrolEvidence.digest(
              "effect-index",
              {
                "entries" => entries,
                "duplicate_keys" => duplicate_keys,
                "counts" => counts
              }
            )
            new(
              entries: entries,
              duplicate_keys: duplicate_keys,
              counts: counts,
              digest: digest
            ).freeze
          rescue NoMethodError, TypeError
            raise Hive::ConfigError, "module shadow evidence is malformed"
          end

          private

          def append_entries(entries, record, channel)
            key = channel == "legacy" ? "legacy_effects" : "module_effects"
            record.fetch(key).each do |value|
              receipt = EffectReceipt.from_h(value)
              intent = receipt.intent
              identity = {
                "effect_kind" => intent.sink,
                "target" => intent.target,
                "owner_epoch" => intent.owner_epoch,
                "idempotency_identity" => intent.idempotency_key
              }
              entries << {
                "effect_key" =>
                  PatrolEvidence.digest("effect", identity),
                "effect_kind" => intent.sink,
                "target" => intent.target,
                "owner_epoch" => intent.owner_epoch,
                "idempotency_identity" => intent.idempotency_key,
                "channel" => channel,
                "authority" => intent.authority,
                "module" => intent.module_name,
                "occurrence_id" => intent.occurrence_id,
                "intent_id" => intent.intent_id,
                "receipt_id" => receipt.receipt_id,
                "status" => receipt.status,
                "decision_id" => record.fetch("decision_id")
              }.freeze
            end
          end
        end

        def legacy_count = counts.fetch("legacy")
        def module_count = counts.fetch("module")
        def legacy_keys
          entries
            .select { |entry| entry["channel"] == "legacy" }
            .map { |entry| entry.fetch("effect_key") }
            .sort
            .freeze
        end

        def to_h
          {
            "entries" => entries,
            "duplicate_keys" => duplicate_keys,
            "counts" => counts,
            "digest" => digest
          }.freeze
        end
      end
    end
  end
end
