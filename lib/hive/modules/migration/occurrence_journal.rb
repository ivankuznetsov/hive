require "json"
require "digest"
require "hive/modules/migration/occurrence_effects"
require "hive/modules/migration/occurrence_journal_state"
require "hive/modules/migration/occurrence_recovery_index"
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
        LOCK_STRIPES = 64

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
          @journal_state = OccurrenceJournalState.new(
            root: @root,
            module_name: @module_name
          )
          @recovery_index = OccurrenceRecoveryIndex.new(
            root: @root,
            module_name: @module_name,
            validator: @validator
          )
          @outbox = OccurrenceOutbox.new(validator: @validator)
          @effects = OccurrenceEffects.new(
            store: @store,
            validator: @validator,
            outbox: @outbox
          )
          @sender_locks = StableProcessLock.new(
            root: File.join(@root, ".sender-locks"),
            label: "patrol effect sender locks",
            stripes: LOCK_STRIPES
          )
          @attempt_locks = StableProcessLock.new(
            root: File.join(@root, ".attempt-locks"),
            label: "patrol occurrence attempt locks",
            stripes: LOCK_STRIPES
          )
          @inventory_lock = StableProcessLock.new(
            root: File.join(@root, ".inventory-locks"),
            label: "patrol occurrence inventory lock",
            stripes: 1
          )
        end

        def reserve!(capture, now: Time.now.utc)
          capture = @validator.capture(capture)
          @journal_state.synchronize do |state, checkpoint|
            @inventory_lock.synchronize("inventory") do
              reserve_coordinated!(
                capture,
                state: state,
                checkpoint: checkpoint,
                now: now
              )
            end
          end
          fetch(capture.occurrence_id)
        end

        # Allocates one durable attempt generation for an ordinary schedule
        # identity. A concurrent/restarted scheduler reuses the sole reserved
        # attempt; only a terminal prior attempt advances the generation.
        def reserve_attempt!(reservation_id, window_started_at:,
                             now: Time.now.utc)
          base_id = @validator.nonempty(
            reservation_id, "patrol reservation identity"
          )
          window = @validator.timestamp(window_started_at)
          key = Digest::SHA256.hexdigest(base_id)
          @attempt_locks.synchronize(key) do
            @journal_state.synchronize do |state, checkpoint|
              @inventory_lock.synchronize("inventory") do
                ensure_recovery_index_current_locked!(
                  state, checkpoint
                )
                reserved_capture = nil
                reserved_count = 0
                observed_generation = 0
                each_record do |record|
                  reservation = record.dig(
                    "provisional_capture", "reservation"
                  )
                  next unless reservation.is_a?(Hash) &&
                              reservation["kind"] == "ordinary" &&
                              reservation["id"] == base_id

                  generation = attempt_generation(reservation)
                  observed_generation = [
                    observed_generation, generation
                  ].max
                  next unless record.fetch("phase") == "reserved"

                  reserved_count += 1
                  reserved_capture = @validator.capture(
                    record.fetch("provisional_capture")
                  )
                end
                if reserved_count > 1
                  malformed!(
                    "patrol schedule has multiple reserved attempts"
                  )
                end
                return reserved_capture if reserved_capture

                generation = @journal_state.allocate_attempt!(
                  state,
                  reservation_id: base_id,
                  window_started_at: window,
                  observed_generation: observed_generation
                )
                capture = @validator.capture(yield(generation))
                reservation = capture.reservation
                unless reservation["kind"] == "ordinary" &&
                       reservation["id"] == base_id &&
                       reservation["window_started_at"] == window &&
                       attempt_generation(reservation) == generation
                  malformed!(
                    "patrol schedule attempt capture is malformed"
                  )
                end
                # A crash after this checkpoint may skip a generation, but
                # it can never allocate the same generation twice.
                checkpoint.call
                reserve_coordinated!(
                  capture,
                  state: state,
                  checkpoint: checkpoint,
                  now: now
                )
                capture
              end
            end
          end
        end

        def fetch(occurrence_id)
          @store.fetch(occurrence_id)
        end

        def each_reserved
          return enum_for(__method__) unless block_given?

          each_recovery_active do |record|
            yield record if record.fetch("phase") == "reserved"
          end
          nil
        end

        # Normal recovery reads only the bounded durable active-ID projection.
        # Occurrence records remain authoritative, so a missing, stale, dirty,
        # or malformed projection receives one descriptor-safe history repair.
        def each_recovery_active
          return enum_for(__method__) unless block_given?

          snapshot = recovery_index_snapshot
          stale = false
          snapshot.fetch("occurrence_ids").each do |occurrence_id|
            record = @store.fetch(occurrence_id)
            unless record && recovery_active_record?(record)
              stale = true
              next
            end

            yield record
          end
          repair_recovery_index! if stale
          nil
        end

        def each_projection_pending
          return enum_for(__method__) unless block_given?

          each_recovery_active do |record|
            yield record if projection_pending_record?(record)
          end
          nil
        end

        def recovery_active? = each_recovery_active.any?
        def projection_pending? = each_projection_pending.any?

        # Exact bounded proof that a missing occurrence was finalized,
        # fully acknowledged, and retired. Callers must supply the immutable
        # capture so a digest or sequence fence cannot be applied to a
        # different occurrence.
        def terminal_fence?(capture)
          capture = @validator.capture(capture)
          @journal_state.synchronize do |state, _checkpoint|
            @journal_state.retired_occurrence?(state, capture)
          end
        end

        # Exact terminal proof for one immutable occurrence. A finalized,
        # fully acknowledged live record remains authoritative when the
        # bounded retirement-fence inventory is full; a missing record must
        # have its exact durable retirement fence.
        def terminalized?(capture)
          capture = @validator.capture(capture)
          record = @store.fetch(capture.occurrence_id)
          return terminal_fence?(capture) unless record

          record.fetch("provisional_capture") == capture.to_h &&
            retireable?(record) &&
            !recovery_active_record?(record)
        end

        def rebuild_recovery_index!
          @journal_state.synchronize do |state, checkpoint|
            @inventory_lock.synchronize("inventory") do
              generation =
                @journal_state.mark_recovery_dirty!(state)
              checkpoint.call
              snapshot = @recovery_index.write(
                generation: generation,
                occurrence_ids: recovery_active_ids_from_records
              )
              clear_recovery_index_dirty!(
                state, checkpoint, generation
              )
              snapshot
            end
          end
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

        def settle_effect!(intent, status:, outcome:, projections: [],
                           now: Time.now.utc)
          @effects.settle(
            intent, status: status, outcome: outcome,
            projections: projections, now: now
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

        def assert_publication!(receipt)
          @effects.assert_publication!(receipt)
        end

        def acknowledge_outbox!(occurrence_id, kind:, entry_id:, digest:)
          record = @store.mutate(occurrence_id) do |value|
            @outbox.acknowledge(
              value, kind: kind, entry_id: entry_id, digest: digest
            )
          end
          retire_if_terminal!(record)
          record
        end

        def recovery_backoff(now: Time.now.utc)
          @journal_state.synchronize do |state, _checkpoint|
            @journal_state.recovery_snapshot(state, now: now)
          end
        end

        def record_recovery_failure!(operation:, occurrence_id: nil,
                                     job_id: nil, error:,
                                     now: Time.now.utc)
          @journal_state.synchronize do |state, checkpoint|
            failure = @journal_state.record_recovery_failure!(
              state,
              operation: operation,
              occurrence_id: occurrence_id,
              job_id: job_id,
              error: error,
              now: now
            )
            checkpoint.call
            failure
          end
        end

        def clear_recovery_failure!(expected_generation:)
          @journal_state.synchronize do |state, checkpoint|
            cleared = @journal_state.clear_recovery_failure!(
              state,
              expected_generation: expected_generation
            )
            checkpoint.call if cleared
            cleared
          end
        end

        private

        def reserve_coordinated!(capture, state:, checkpoint:, now:)
          recovery_index = ensure_recovery_index_current_locked!(
            state, checkpoint
          )
          existing = @store.fetch(capture.occurrence_id)
          if existing
            validate_occurrence_identity!(existing, capture)
            return existing
          end
          if @journal_state.retired_occurrence?(state, capture)
            malformed!("patrol occurrence was already retired")
          end

          candidate = @store.retirement_candidate_if_full do |record|
            provisional = @validator.capture(
              record.fetch("provisional_capture")
            )
            @journal_state.retirement_fence_available?(
              state, provisional
            )
          end
          if candidate
            provisional = @validator.capture(
              candidate.fetch("provisional_capture")
            )
            # The candidate predicate above ran against this same locked state,
            # so its retirement fence cannot become unavailable here.
            @journal_state.fence_retirement!(state, provisional)
            checkpoint.call
            @store.retire!(candidate.fetch("occurrence_id"))
          end
          generation = @journal_state.mark_recovery_dirty!(state)
          checkpoint.call
          @recovery_index.write(
            generation: generation,
            occurrence_ids:
              recovery_index.fetch("occurrence_ids") +
                [ capture.occurrence_id ]
          )
          timestamp = @validator.timestamp(now)
          record = @store.mutate(capture.occurrence_id, create: true) do |value|
            if value
              validate_occurrence_identity!(value, capture)
              next value
            end
            build_record(capture, timestamp)
          end
          unless recovery_active_record?(record)
            malformed!("patrol occurrence reservation is not recovery active")
          end
          clear_recovery_index_dirty!(
            state, checkpoint, generation
          )
          record
        end

        def retire_if_terminal!(record)
          return false unless retireable?(record)

          @journal_state.synchronize do |state, checkpoint|
            @inventory_lock.synchronize("inventory") do
              recovery_index = ensure_recovery_index_current_locked!(
                state, checkpoint
              )
              current = @store.fetch(record.fetch("occurrence_id"))
              next false unless current && retireable?(current)

              provisional = @validator.capture(
                current.fetch("provisional_capture")
              )
              retire = @journal_state.fence_retirement!(
                state, provisional
              )
              generation =
                @journal_state.mark_recovery_dirty!(state)
              checkpoint.call
              @recovery_index.write(
                generation: generation,
                occurrence_ids:
                  recovery_index.fetch("occurrence_ids") -
                    [ current.fetch("occurrence_id") ]
              )
              @store.retire!(current.fetch("occurrence_id")) if retire
              retained = @store.fetch(current.fetch("occurrence_id"))
              if retained && recovery_active_record?(retained)
                malformed!(
                  "retired patrol occurrence remains recovery active"
                )
              end
              clear_recovery_index_dirty!(
                state, checkpoint, generation
              )
              retire
            end
          end
        end

        def retireable?(record)
          record.fetch("phase") == "finalized" &&
            record.fetch("outbox").all? do |entry|
              entry.fetch("acknowledged") == true
            end
        end

        def projection_pending_record?(record)
          record.fetch("outbox").any? do |entry|
            entry.fetch("acknowledged") == false
          end
        end

        def recovery_active_record?(record)
          record.fetch("phase") == "reserved" ||
            projection_pending_record?(record)
        end

        def recovery_index_snapshot
          @journal_state.synchronize do |state, checkpoint|
            @inventory_lock.synchronize("inventory") do
              ensure_recovery_index_current_locked!(
                state, checkpoint
              )
            end
          end
        end

        def repair_recovery_index!
          @journal_state.synchronize do |state, checkpoint|
            @inventory_lock.synchronize("inventory") do
              ensure_recovery_index_current_locked!(
                state, checkpoint, force: true
              )
            end
          end
        end

        def ensure_recovery_index_current_locked!(
          state, checkpoint, force: false
        )
          inventory = @journal_state.recovery_inventory(state)
          snapshot = @recovery_index.snapshot
          if !force && !inventory.fetch("dirty") && snapshot &&
             snapshot.fetch("generation") ==
               inventory.fetch("generation")
            return snapshot
          end

          snapshot = @recovery_index.write(
            generation: inventory.fetch("generation"),
            occurrence_ids: recovery_active_ids_from_records
          )
          clear_recovery_index_dirty!(
            state, checkpoint, inventory.fetch("generation")
          )
          snapshot
        end

        def clear_recovery_index_dirty!(
          state, checkpoint, generation
        )
          cleared = @journal_state.clear_recovery_dirty!(
            state, expected_generation: generation
          )
          checkpoint.call if cleared
          cleared
        end

        def recovery_active_ids_from_records
          ids = []
          each_record do |record|
            ids << record.fetch("occurrence_id") if
              recovery_active_record?(record)
          end
          ids.sort
        end

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
          unless immutable_capture_fields(provisional) ==
                 immutable_capture_fields(capture)
            malformed!(
              "patrol occurrence capture conflicts"
            )
          end
          true
        rescue KeyError
          malformed!("patrol occurrence is malformed")
        end

        def immutable_capture_fields(capture)
          [
            capture.module_name,
            capture.occurrence_id,
            capture.project,
            capture.trigger,
            capture.reservation,
            capture.owner,
            capture.owner_epoch,
            capture.selection_input,
            capture.selection,
            capture.occurred_at
          ]
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
