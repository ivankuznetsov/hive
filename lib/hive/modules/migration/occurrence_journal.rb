require "json"
require "digest"
require "hive/modules/migration/occurrence_effects"
require "hive/modules/migration/occurrence_record_store"
require "hive/modules/migration/stable_process_lock"

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
        OCCURRENCE_ID = OccurrenceContract::OCCURRENCE_ID
        INTENT_ID = OccurrenceContract::INTENT_ID
        DELIVERY_STATES = OccurrenceContract::DELIVERY_STATES
        TERMINAL_STATES = OccurrenceContract::TERMINAL_STATES
        OUTBOX_KINDS = OccurrenceContract::OUTBOX_KINDS

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
          @sender_locks = StableProcessLock.new(
            root: File.join(@root, ".sender-locks"),
            label: "patrol effect sender locks"
          )
          @attempt_locks = StableProcessLock.new(
            root: File.join(@root, ".attempt-locks"),
            label: "patrol occurrence attempt locks"
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

        # Allocates one durable attempt generation for an ordinary schedule
        # identity. A concurrent/restarted scheduler reuses the sole reserved
        # attempt; only a terminal prior attempt advances the generation.
        def reserve_attempt!(reservation_id, now: Time.now.utc)
          base_id = @validator.nonempty(
            reservation_id, "patrol reservation identity"
          )
          key = Digest::SHA256.hexdigest(base_id)
          @attempt_locks.synchronize(key) do
            attempts = each_record.filter_map do |record|
              reservation = record.dig(
                "provisional_capture", "reservation"
              )
              next unless reservation.is_a?(Hash) &&
                          reservation["kind"] == "ordinary" &&
                          reservation["id"] == base_id

              [ record, attempt_generation(reservation) ]
            end
            reserved = attempts.select do |record, _generation|
              record.fetch("phase") == "reserved"
            end
            if reserved.size > 1
              malformed!(
                "patrol schedule has multiple reserved attempts"
              )
            end
            if reserved.one?
              return @validator.capture(
                reserved.first.first.fetch("provisional_capture")
              )
            end

            generation = attempts.map(&:last).max.to_i + 1
            capture = @validator.capture(yield(generation))
            reservation = capture.reservation
            unless reservation["kind"] == "ordinary" &&
                   reservation["id"] == base_id &&
                   attempt_generation(reservation) == generation
              malformed!(
                "patrol schedule attempt capture is malformed"
              )
            end
            reserve!(capture, now: now)
            capture
          end
        end

        def fetch(occurrence_id)
          @store.fetch(occurrence_id)
        end

        def pending
          each_record.select do |record|
            record.fetch("phase") == "reserved"
          end.freeze
        end

        # One bounded pass over the sole occurrence journal is the durable
        # scheduler recovery inventory. Reserved occurrences still own product
        # work; finalized occurrences remain active only while their projection
        # outbox has unacknowledged entries.
        def recovery_active
          each_record.select do |record|
            record.fetch("phase") == "reserved" ||
              record.fetch("outbox").any? do |entry|
              entry.fetch("acknowledged") == false
            end
          end.freeze
        end

        def projection_pending
          each_record.select do |record|
            record.fetch("outbox").any? do |entry|
              entry.fetch("acknowledged") == false
            end
          end.freeze
        end

        def records
          @store.records
        end

        def each_record(&block)
          return @store.each_record unless block

          @store.each_record(&block)
        end

        def prepare_effect!(intent, now: Time.now.utc)
          @effects.prepare(intent, now: now)
        end

        def effect_state(intent)
          @effects.state(intent)
        end

        def effect_intent(occurrence_id, intent_id)
          record = fetch(occurrence_id)
          malformed!("patrol occurrence is missing") unless record
          cell = record.dig("effects", intent_id.to_s)
          malformed!("patrol effect intent is missing") unless cell

          terminal_receipt_id = cell["terminal_receipt_id"]
          if terminal_receipt_id
            return receipt(
              terminal_receipt_id,
              occurrence_id: occurrence_id
            ).intent
          end
          authorization = cell.fetch("authorizations")
                              .sort_by(&:first)
                              .last&.last
          malformed!("patrol effect authorization is missing") unless
            authorization

          @validator.intent(authorization)
        end

        def with_effect_sender_lock(intent, &block)
          intent = @validator.intent(intent)
          key = [ intent.occurrence_id, intent.intent_id ].join(".")
          @sender_locks.synchronize(key, &block)
        end

        def mark_dispatch_uncertain!(intent, now: Time.now.utc)
          @effects.mark_uncertain(intent, now: now)
        end

        def reset_effect_prepared!(intent, now: Time.now.utc)
          @effects.reset_prepared(intent, now: now)
        end

        def settle_effect!(intent, status:, outcome:,
                           now: Time.now.utc)
          @effects.settle(
            intent, status: status, outcome: outcome, now: now
          )
        end

        def deny_effect!(intent, outcome:, now: Time.now.utc)
          @effects.deny(
            intent, outcome: outcome, now: now
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

            assert_terminal_effects!(record, capture)
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

        def attempt_generation(reservation)
          @validator.positive_integer(
            reservation["attempt_generation"],
            "patrol occurrence attempt generation"
          )
        end

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

        def assert_terminal_effects!(record, capture)
          cells = record.fetch("effects").values
          unless cells.all? do |cell|
                   TERMINAL_STATES.include?(cell.fetch("state"))
                 end
            malformed!(
              "patrol occurrence has nonterminal effects"
            )
          end
          expected = cells.map do |cell|
            cell.fetch("terminal_receipt_id")
          end.sort
          unless expected == capture.effect_ids.sort
            malformed!(
              "patrol final capture effect binding is malformed"
            )
          end
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
