require "json"
require "hive/modules/migration/occurrence_effects"
require "hive/modules/migration/occurrence_record_store"

module Hive
  module Modules
    module Migration
      # Canonical facade for one patrol occurrence journal. It composes one
      # lock/write owner, one pure validator, one outbox collaborator, and one
      # effect-state machine; callers never persist through those internals.
      class OccurrenceJournal
        SCHEMA = OccurrenceContract::SCHEMA
        SCHEMA_VERSION = OccurrenceContract::SCHEMA_VERSION
        MAX_RECORD_BYTES = OccurrenceContract::MAX_RECORD_BYTES
        MAX_OUTBOX_ENTRIES = OccurrenceContract::MAX_OUTBOX_ENTRIES
        DEFAULT_LEASE_SEC = OccurrenceContract::DEFAULT_LEASE_SEC
        OCCURRENCE_ID = OccurrenceContract::OCCURRENCE_ID
        INTENT_ID = OccurrenceContract::INTENT_ID
        DELIVERY_STATES = OccurrenceContract::DELIVERY_STATES
        TERMINAL_STATES = OccurrenceContract::TERMINAL_STATES
        OUTBOX_KINDS = OccurrenceContract::OUTBOX_KINDS
        Claim = OccurrenceEffects::Claim

        attr_reader :root

        def initialize(root, module_name:)
          @module_name = module_name.to_s
          @validator = OccurrenceRecordValidator.new(
            module_name: @module_name
          )
          @store = OccurrenceRecordStore.new(
            root: root, validator: @validator
          )
          @root = @store.root
          @outbox = OccurrenceOutbox.new(validator: @validator)
          @effects = OccurrenceEffects.new(
            store: @store,
            validator: @validator,
            outbox: @outbox
          )
        end

        def reserve!(capture, now: Time.now.utc)
          capture = @validator.capture(capture)
          @store.mutate(capture.occurrence_id, create: true) do |record|
            if record
              validate_occurrence_identity!(record, capture)
              next record
            end

            timestamp = @validator.timestamp(now)
            build_record(capture, timestamp)
          end
          fetch(capture.occurrence_id)
        end

        def fetch(occurrence_id)
          @store.fetch(occurrence_id)
        end

        def pending
          records.select do |record|
            record.fetch("phase") == "reserved"
          end.freeze
        end

        def projection_pending
          records.select do |record|
            record.fetch("outbox").any? do |entry|
              entry.fetch("acknowledged") == false
            end
          end.freeze
        end

        def records
          @store.records
        end

        def prepare_effect!(intent, now: Time.now.utc)
          @effects.prepare(intent, now: now)
        end

        def effect_state(intent)
          @effects.state(intent)
        end

        def acquire_effect!(intent, claimant:, now: Time.now.utc,
                            lease_sec: DEFAULT_LEASE_SEC)
          @effects.acquire(
            intent,
            claimant: claimant,
            now: now,
            lease_sec: lease_sec
          )
        end

        def mark_dispatch_uncertain!(intent, token:,
                                     now: Time.now.utc)
          @effects.mark_uncertain(
            intent, token: token, now: now
          )
        end

        def resolve_absent!(intent, expected_generation:, outcome:,
                            receipt:, now: Time.now.utc)
          @effects.resolve_absent(
            intent,
            expected_generation: expected_generation,
            outcome: outcome,
            receipt: receipt,
            now: now
          )
        end

        def settle_reconciled!(intent, expected_generation:, outcome:,
                               receipt:, now: Time.now.utc)
          @effects.settle_reconciled(
            intent,
            expected_generation: expected_generation,
            outcome: outcome,
            receipt: receipt,
            now: now
          )
        end

        def settle_claimed!(intent, token:, status:, outcome:, receipt:,
                            now: Time.now.utc)
          @effects.settle_claimed(
            intent,
            token: token,
            status: status,
            outcome: outcome,
            receipt: receipt,
            now: now
          )
        end

        def deny_prepared!(intent, outcome:, receipt:,
                           now: Time.now.utc)
          @effects.deny(
            intent,
            outcome: outcome,
            receipt: receipt,
            now: now
          )
        end

        def finalize!(capture, event_bytes: nil, now: Time.now.utc)
          capture = @validator.capture(capture)
          event_bytes = @validator.canonical_bytes(
            event_bytes, "patrol finalized event"
          ) if event_bytes
          @store.mutate(capture.occurrence_id) do |record|
            validate_occurrence_identity!(record, capture)
            if record.fetch("phase") == "finalized"
              unless record.fetch("final_capture") == capture.to_h
                malformed!(
                  "patrol occurrence final capture conflicts"
                )
              end
              append_finalized_projections!(
                record, capture, event_bytes
              )
              next record
            end

            record["phase"] = "finalized"
            record["final_capture"] = capture.to_h
            append_finalized_projections!(
              record, capture, event_bytes
            )
            touch(record, now)
          end
          fetch(capture.occurrence_id)
        rescue JSON::ParserError, KeyError
          malformed!("patrol finalized event is malformed")
        end

        def effect_receipt_ids(occurrence_id)
          @effects.terminal_receipt_ids(occurrence_id)
        end

        def pending_outbox(occurrence_id)
          record = fetch(occurrence_id)
          malformed!("patrol occurrence is missing") unless record
          @outbox.pending(record)
        end

        def receipt(receipt_id, occurrence_id:)
          @effects.receipt(
            receipt_id, occurrence_id: occurrence_id
          )
        end

        def acknowledge_outbox!(occurrence_id, entry_id:, digest:)
          @store.mutate(occurrence_id) do |record|
            @outbox.acknowledge(
              record, entry_id: entry_id, digest: digest
            )
          end
        end

        private

        def build_record(capture, timestamp)
          {
            "schema" => SCHEMA,
            "schema_version" => SCHEMA_VERSION,
            "module" => @module_name,
            "occurrence_id" => capture.occurrence_id,
            "phase" => "reserved",
            "provisional_capture" => capture.to_h,
            "final_capture" => nil,
            "effects" => {},
            "outbox" => [],
            "next_outbox_sequence" => 1,
            "created_at" => timestamp,
            "updated_at" => timestamp
          }
        end

        def validate_occurrence_identity!(record, capture)
          unless record.fetch("module") == @module_name &&
                 record.fetch("occurrence_id") ==
                   capture.occurrence_id
            malformed!(
              "patrol occurrence identity conflicts"
            )
          end
          provisional = @validator.capture(
            record.fetch("provisional_capture")
          )
          unless provisional.occurrence_id ==
                 capture.occurrence_id
            malformed!(
              "patrol occurrence capture conflicts"
            )
          end
          true
        rescue KeyError
          malformed!("patrol occurrence is malformed")
        end

        def append_finalized_projections!(record, capture, event_bytes)
          @outbox.append(
            record,
            kind: "capture",
            id: capture.capture_id,
            bytes: @validator.canonical(capture.to_h)
          )
          return unless event_bytes

          event = JSON.parse(event_bytes)
          @outbox.append(
            record,
            kind: "event",
            id: event.fetch("event_id"),
            bytes: event_bytes
          )
        end

        def touch(record, now)
          record["updated_at"] = @validator.timestamp(now)
          record
        end

        def malformed!(message)
          raise Hive::ConfigError, message
        end
      end
    end
  end
end
