require "digest"
require "json"
require "hive/modules/migration/patrol_evidence"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      module OccurrenceContract
        SCHEMA = "hive-patrol-occurrence".freeze
        SCHEMA_VERSION = 2
        MAX_RECORD_BYTES = 2 * 1024 * 1024
        MAX_OUTBOX_ENTRIES = 512
        OCCURRENCE_ID = /\Aocc-[0-9a-f]{64}\z/
        INTENT_ID = /\Aintent-[0-9a-f]{64}\z/
        DELIVERY_STATES = %w[
          prepared dispatch_uncertain committed reconciled denied failed
        ].freeze
        TERMINAL_STATES = %w[
          committed reconciled denied failed
        ].freeze
        OUTBOX_KINDS = %w[receipt capture event].freeze
      end

      # Pure canonical-record validation and value normalization for the
      # occurrence store. It never acquires locks or writes state.
      class OccurrenceRecordValidator
        include OccurrenceContract

        def initialize(module_name:)
          @module_name = PatrolEvidence.enum(
            module_name,
            PatrolEvidence::MODULES,
            label: "patrol occurrence journal"
          )
        end

        def validate!(record, expected_id:)
          required = %w[
            created_at effects final_capture module next_outbox_sequence
            occurrence_id outbox phase provisional_capture schema
            schema_version updated_at
          ]
          valid = record.is_a?(Hash) &&
                  record.keys.sort == required.sort &&
                  record["schema"] == SCHEMA &&
                  record["schema_version"] == SCHEMA_VERSION &&
                  record["module"] == @module_name &&
                  record["occurrence_id"] == expected_id &&
                  %w[reserved finalized].include?(record["phase"]) &&
                  record["effects"].is_a?(Hash) &&
                  record["outbox"].is_a?(Array) &&
                  record["next_outbox_sequence"].is_a?(Integer) &&
                  record["next_outbox_sequence"].positive?
          malformed!("patrol occurrence is malformed") unless valid

          provisional = capture(record.fetch("provisional_capture"))
          unless provisional.occurrence_id == expected_id
            malformed!("patrol occurrence capture is malformed")
          end
          if record.fetch("phase") == "finalized"
            final = capture(record.fetch("final_capture"))
            unless final.occurrence_id == expected_id
              malformed!("patrol occurrence final capture is malformed")
            end
          elsif !record["final_capture"].nil?
            malformed!("reserved patrol occurrence has a final capture")
          end

          outbox = validate_outbox(
            record.fetch("outbox"),
            record.fetch("next_outbox_sequence"),
            occurrence_id: expected_id
          )
          validate_effects(
            record.fetch("effects"),
            expected_id,
            receipts: outbox.fetch("receipt")
          )
          validate_finalized_outbox(record, outbox)
          validate_finalized_effects(record)
          timestamp(record.fetch("created_at"))
          timestamp(record.fetch("updated_at"))
          true
        end

        def capture(value)
          result = value.is_a?(PatrolCapture) ?
            value : PatrolCapture.from_h(value)
          unless result.module_name == @module_name
            malformed!("patrol capture is malformed")
          end
          result
        end

        def intent(value)
          result = value.is_a?(EffectIntent) ?
            value : EffectIntent.from_h(value)
          unless result.module_name == @module_name
            malformed!("patrol effect intent is malformed")
          end
          result
        end

        def receipt(value, intent:)
          result = value.is_a?(EffectReceipt) ?
            value : EffectReceipt.from_h(value)
          unless result.intent.intent_id == intent.intent_id &&
                 result.intent.authorization_digest ==
                   intent.authorization_digest
            malformed!(
              "patrol effect receipt does not match its authorization"
            )
          end
          result
        end

        def semantic_intent(intent)
          {
            "intent_id" => intent.intent_id,
            "module" => intent.module_name,
            "occurrence_id" => intent.occurrence_id,
            "owner_epoch" => intent.owner_epoch,
            "sink" => intent.sink,
            "target" => intent.target,
            "idempotency_key" => intent.idempotency_key,
            "scope" => intent.scope
          }
        end

        def object(value, label)
          result = PatrolEvidence.immutable_json(
            copy(value), label: label
          )
          malformed!("#{label} is malformed") unless
            result.is_a?(Hash)
          result
        rescue JSON::GeneratorError, JSON::NestingError, TypeError
          malformed!("#{label} is malformed")
        end

        def canonical_bytes(value, label)
          bytes = value.to_s
          data = JSON.parse(bytes)
          unless bytes == canonical(data)
            malformed!("#{label} is malformed")
          end
          bytes
        rescue JSON::ParserError, EncodingError
          malformed!("#{label} is malformed")
        end

        def occurrence_id(value)
          id = value.to_s
          return id if OCCURRENCE_ID.match?(id)

          malformed!("patrol occurrence identity is malformed")
        end

        def timestamp(value)
          PatrolEvidence.timestamp(
            value, label: "patrol occurrence timestamp"
          )
        end

        def positive_integer(value, label)
          integer = Integer(value)
          return integer if integer.positive?

          malformed!("#{label} is malformed")
        rescue ArgumentError, TypeError
          malformed!("#{label} is malformed")
        end

        def nonempty(value, label)
          string = value.to_s
          return string unless string.empty?

          malformed!("#{label} is malformed")
        end

        def copy(value)
          JSON.parse(JSON.generate(value))
        end

        def canonical(value)
          Hive::WorkflowPackage::CanonicalJSON.generate(value)
        end

        private

        def validate_effects(effects, occurrence_id, receipts:)
          if effects.size >
             PatrolEvidence::MAX_EFFECTS_PER_OCCURRENCE
            malformed!("patrol occurrence effect limit exceeded")
          end
          effects.each do |intent_id, cell|
            validate_effect_cell!(intent_id, cell)
            authorizations = cell.fetch("authorizations")
            authorizations.each do |digest, value|
              authorization = intent(value)
              unless digest == authorization.authorization_digest &&
                     authorization.intent_id == intent_id &&
                     authorization.occurrence_id == occurrence_id &&
                     semantic_intent(authorization) ==
                       cell.fetch("semantic")
                malformed!(
                  "patrol effect authorization is malformed"
                )
              end
            end
            validate_receipt_bindings!(
              intent_id, cell, authorizations, receipts
            )
            timestamp(cell.fetch("updated_at"))
          end
          referenced = effects.values.flat_map do |cell|
            cell.fetch("receipt_ids")
          end.uniq.sort
          unless referenced == receipts.keys.sort
            malformed!("patrol effect receipt binding is malformed")
          end
        end

        def validate_effect_cell!(intent_id, cell)
          valid = INTENT_ID.match?(intent_id.to_s) &&
                  cell.is_a?(Hash) &&
                  cell.keys.sort == %w[
                    authorizations intent_id outcome receipt_ids semantic
                    state terminal_receipt_id updated_at
                  ] &&
                  cell["intent_id"] == intent_id &&
                  DELIVERY_STATES.include?(cell["state"]) &&
                  cell["outcome"].is_a?(Hash) &&
                  cell["receipt_ids"].is_a?(Array) &&
                  cell["receipt_ids"].uniq == cell["receipt_ids"] &&
                  cell["receipt_ids"].all? do |receipt_id|
                    receipt_id.to_s.match?(
                      /\Areceipt-[0-9a-f]{64}\z/
                    )
                  end &&
                  cell["authorizations"].is_a?(Hash) &&
                  !cell["authorizations"].empty?
          unless valid
            malformed!("patrol effect recovery state is malformed")
          end
        end

        def validate_receipt_bindings!(intent_id, cell, authorizations,
                                       receipts)
          cell.fetch("receipt_ids").each do |receipt_id|
            value = receipts[receipt_id]
            unless value &&
                   value.intent.intent_id == intent_id &&
                   authorizations.key?(
                     value.intent.authorization_digest
                   )
              malformed!("patrol effect receipt binding is malformed")
            end
          end
          terminal_id = cell.fetch("terminal_receipt_id")
          if TERMINAL_STATES.include?(cell.fetch("state"))
            value = receipts[terminal_id]
            unless value &&
                   cell.fetch("receipt_ids").include?(terminal_id) &&
                   value.status == cell.fetch("state") &&
                   value.outcome == cell.fetch("outcome")
              malformed!("patrol effect terminal receipt is malformed")
            end
          elsif !terminal_id.nil?
            malformed!("patrol effect terminal receipt is malformed")
          end
        end

        def validate_outbox(outbox, next_sequence, occurrence_id:)
          if outbox.size > MAX_OUTBOX_ENTRIES
            malformed!("patrol outbox entry limit exceeded")
          end
          sequences = []
          identities = []
          values = OUTBOX_KINDS.to_h { |kind| [ kind, {} ] }
          outbox.each do |entry|
            validate_outbox_entry!(entry)
            bytes = canonical_bytes(
              entry.fetch("bytes"), "patrol outbox bytes"
            )
            value = validate_outbox_value(
              entry.fetch("kind"),
              entry.fetch("id"),
              bytes,
              occurrence_id: occurrence_id
            )
            values.fetch(entry.fetch("kind"))[
              entry.fetch("id")
            ] = value
            sequences << entry.fetch("sequence")
            identities << [
              entry.fetch("kind"), entry.fetch("id")
            ]
          end
          valid = sequences.uniq == sequences &&
                  sequences.sort == sequences &&
                  identities.uniq == identities &&
                  next_sequence == sequences.fetch(-1, 0) + 1
          unless valid
            malformed!("patrol outbox ordering is malformed")
          end
          values.each_value(&:freeze)
          values.freeze
        end

        def validate_outbox_entry!(entry)
          valid = entry.is_a?(Hash) &&
                  entry.keys.sort == %w[
                    acknowledged bytes digest id kind sequence
                  ] &&
                  entry["sequence"].is_a?(Integer) &&
                  entry["sequence"].positive? &&
                  OUTBOX_KINDS.include?(entry["kind"]) &&
                  !entry["id"].to_s.empty? &&
                  entry["digest"] ==
                    Digest::SHA256.hexdigest(
                      entry["bytes"].to_s
                    ) &&
                  [ true, false ].include?(entry["acknowledged"])
          malformed!("patrol outbox entry is malformed") unless valid
        end

        def validate_outbox_value(kind, id, bytes, occurrence_id:)
          data = JSON.parse(bytes)
          case kind
          when "receipt"
            value = EffectReceipt.from_h(data)
            unless value.receipt_id == id &&
                   value.intent.module_name == @module_name &&
                   value.intent.occurrence_id == occurrence_id
              malformed!("patrol outbox receipt is malformed")
            end
            value
          when "capture"
            value = PatrolCapture.from_h(data)
            unless value.capture_id == id &&
                   value.module_name == @module_name &&
                   value.occurrence_id == occurrence_id
              malformed!("patrol outbox capture is malformed")
            end
            value
          when "event"
            unless data.is_a?(Hash) && data["event_id"] == id
              malformed!("patrol outbox event is malformed")
            end
            data.freeze
          else
            malformed!("patrol outbox kind is malformed")
          end
        rescue JSON::ParserError
          malformed!("patrol outbox bytes are malformed")
        end

        def validate_finalized_outbox(record, outbox)
          captures = outbox.fetch("capture")
          events = outbox.fetch("event")
          if record.fetch("phase") == "reserved"
            unless captures.empty? && events.empty?
              malformed!(
                "reserved patrol occurrence has finalized projection"
              )
            end
            return
          end

          final = capture(record.fetch("final_capture"))
          valid = captures.keys == [ final.capture_id ] &&
                  captures.fetch(final.capture_id).to_h ==
                    final.to_h &&
                  events.size <= 1
          unless valid
            malformed!("patrol finalized projection is malformed")
          end
        end

        def validate_finalized_effects(record)
          return unless record.fetch("phase") == "finalized"

          effects = record.fetch("effects").values
          unless effects.all? do |cell|
                   TERMINAL_STATES.include?(cell.fetch("state"))
                 end
            malformed!(
              "patrol finalized occurrence has a nonterminal effect"
            )
          end
          expected = effects.map do |cell|
            cell.fetch("terminal_receipt_id")
          end.sort
          actual = capture(
            record.fetch("final_capture")
          ).effect_ids.sort
          unless actual == expected
            malformed!(
              "patrol final capture effect binding is malformed"
            )
          end
        end

        def malformed!(message)
          raise Hive::ConfigError, message
        end
      end
    end
  end
end
