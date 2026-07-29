require "digest"
require "json"
require "time"
require "hive/managed_directory"
require "hive/modules/migration/stable_process_lock"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Bounded coordination metadata for one product occurrence journal.
      # It owns no work or delivery state: occurrences and their outboxes
      # remain the sole recovery authority.
      class OccurrenceJournalState
        SCHEMA = "hive-patrol-occurrence-journal-state".freeze
        SCHEMA_VERSION = 1
        MAX_BYTES = 64 * 1024
        MAX_SEQUENCE_HIGH_WATERS = 256
        MAX_RETIRED_OCCURRENCES = 128
        MAX_ERROR_CLASS_BYTES = 128
        MAX_ERROR_BYTES = 512
        BACKOFF_SCHEDULE = [ 60, 300, 900 ].freeze
        STATE_NAME = "journal-state.json".freeze

        class << self
          def normalize_error(error)
            error_class = bounded_utf8(
              error.class.name,
              max_bytes: MAX_ERROR_CLASS_BYTES,
              fallback: "AnonymousError"
            )
            message = bounded_utf8(
              error.message,
              max_bytes: MAX_ERROR_BYTES,
              fallback: "recovery failed"
            )
            {
              "error_class" => error_class,
              "error_message" => message,
              "error_digest" =>
                Digest::SHA256.hexdigest(
                  [ error_class, message ].join("\0")
                )
            }.freeze
          end

          private

          def bounded_utf8(value, max_bytes:, fallback:)
            string = value.to_s.encode(
              Encoding::UTF_8,
              invalid: :replace,
              undef: :replace,
              replace: "\uFFFD"
            )
            string = fallback if string.empty?
            return string if string.bytesize <= max_bytes

            string.byteslice(0, max_bytes)
                  .force_encoding(Encoding::UTF_8)
                  .scrub("")
          rescue EncodingError
            fallback
          end
        end

        def initialize(root:, module_name:)
          @module_name = module_name.to_s
          @directory = Hive::ManagedDirectory.new(
            root: root,
            label: "patrol occurrence journal state"
          )
          @lock = StableProcessLock.new(
            root: File.join(root, ".journal-state-locks"),
            label: "patrol occurrence journal state lock",
            stripes: 1
          )
        end

        def synchronize
          @lock.synchronize("journal-state") do
            state, original = read
            persisted = original
            checkpoint = lambda do
              bytes = canonical(state)
              validate!(state)
              if bytes != persisted
                @directory.atomic_write(
                  STATE_NAME,
                  bytes,
                  mode: 0o600,
                  expected_digest:
                    persisted && Digest::SHA256.hexdigest(persisted),
                  max_existing_bytes: MAX_BYTES
                )
                persisted = bytes
              end
              state
            end
            result = yield(state, checkpoint)
            checkpoint.call
            result
          end
        rescue Hive::ManagedDirectory::UnsafeError,
               SystemCallError, IOError => e
          raise Hive::ConfigError,
                "patrol occurrence journal state is unavailable: #{e.message}"
        end

        def allocate_attempt!(state, reservation_id:, window_started_at:,
                              observed_generation:)
          reservation_id = nonempty(reservation_id)
          window = timestamp(window_started_at)
          generation = nonnegative(observed_generation)
          digest = sequence_digest(reservation_id)
          entry = state.fetch("sequence_high_waters").find do |item|
            item.fetch("identity_digest") == digest
          end
          if entry
            unless entry.fetch("window_started_at") == window
              malformed!
            end
            generation = [
              generation, entry.fetch("high_water")
            ].max + 1
            entry["high_water"] = generation
            entry["closed"] = false
          else
            floor = state["sequence_closed_through"]
            if floor && Time.iso8601(window) <= Time.iso8601(floor)
              raise Hive::ConfigError,
                    "patrol schedule reservation is stale"
            end
            generation += 1
            state.fetch("sequence_high_waters") << {
              "identity_digest" => digest,
              "window_started_at" => window,
              "high_water" => generation,
              "closed" => false
            }
          end
          compact_sequences!(state)
          generation
        end

        def close_sequence!(state, capture)
          reservation = capture.reservation
          return unless sequenced_capture?(capture)

          digest = sequence_digest(
            nonempty(reservation["id"])
          )
          window = timestamp(
            reservation.fetch("window_started_at")
          )
          generation = positive(
            reservation.fetch("attempt_generation")
          )
          entry = state.fetch("sequence_high_waters").find do |item|
            item.fetch("identity_digest") == digest
          end
          if entry
            malformed! unless
              entry.fetch("window_started_at") == window
            entry["high_water"] = [
              entry.fetch("high_water"), generation
            ].max
            entry["closed"] = true
          else
            state.fetch("sequence_high_waters") << {
              "identity_digest" => digest,
              "window_started_at" => window,
              "high_water" => generation,
              "closed" => true
            }
          end
          compact_sequences!(state)
          true
        end

        def retirement_fence_available?(state, capture)
          return true if sequenced_capture?(capture)

          digest = occurrence_digest(capture.occurrence_id)
          retired = state.fetch("retired_occurrence_digests")
          retired.include?(digest) ||
            retired.size < MAX_RETIRED_OCCURRENCES
        end

        def fence_retirement!(state, capture)
          if sequenced_capture?(capture)
            close_sequence!(state, capture)
            return true
          end

          digest = occurrence_digest(capture.occurrence_id)
          retired = state.fetch("retired_occurrence_digests")
          return true if retired.include?(digest)
          return false if retired.size >= MAX_RETIRED_OCCURRENCES

          retired << digest
          retired.sort!
          true
        end

        def retired_occurrence?(state, capture)
          return true if retired_sequence?(state, capture)

          state.fetch("retired_occurrence_digests").include?(
            occurrence_digest(capture.occurrence_id)
          )
        end

        def retired_sequence?(state, capture)
          reservation = capture.reservation
          return false unless sequenced_capture?(capture)

          digest = sequence_digest(nonempty(reservation["id"]))
          window = timestamp(reservation.fetch("window_started_at"))
          generation = positive(
            reservation.fetch("attempt_generation")
          )
          entry = state.fetch("sequence_high_waters").find do |item|
            item.fetch("identity_digest") == digest
          end
          if entry
            malformed! unless
              entry.fetch("window_started_at") == window
            return generation < entry.fetch("high_water") ||
              (generation == entry.fetch("high_water") &&
               entry.fetch("closed"))
          end

          floor = state["sequence_closed_through"]
          floor && Time.iso8601(window) <= Time.iso8601(floor)
        end

        def recovery_snapshot(state, now:)
          now = Time.iso8601(timestamp(now))
          failure = state["recovery_failure"]
          {
            "generation" => state.fetch("recovery_generation"),
            "failure" => deep_copy(failure),
            "blocked" =>
              failure &&
              now < Time.iso8601(failure.fetch("next_eligible_at"))
          }.freeze
        end

        def record_recovery_failure!(state, operation:, occurrence_id:,
                                     job_id:, error:, now:)
          operation = nonempty(operation)
          occurrence_id = optional_nonempty(occurrence_id)
          job_id = optional_nonempty(job_id)
          failed_at = timestamp(now)
          previous = state["recovery_failure"]
          same = previous &&
                 previous.fetch("operation") == operation &&
                 previous["occurrence_id"] == occurrence_id &&
                 previous["job_id"] == job_id
          count = same ? previous.fetch("failure_count") + 1 : 1
          interval = BACKOFF_SCHEDULE[
            [ count - 1, BACKOFF_SCHEDULE.size - 1 ].min
          ]
          generation = state.fetch("recovery_generation") + 1
          diagnostic = self.class.normalize_error(error)
          failure = {
            "generation" => generation,
            "operation" => operation,
            "occurrence_id" => occurrence_id,
            "job_id" => job_id,
            "failure_count" => count,
            "failed_at" => failed_at,
            "next_eligible_at" =>
              (Time.iso8601(failed_at) + interval).utc.iso8601(6),
            **diagnostic
          }
          state["recovery_generation"] = generation
          state["recovery_failure"] = failure
          deep_copy(failure).freeze
        end

        def clear_recovery_failure!(state, expected_generation:)
          expected = nonnegative(expected_generation)
          failure = state["recovery_failure"]
          return true unless failure
          return false unless
            failure.fetch("generation") == expected

          state["recovery_failure"] = nil
          true
        end

        private

        def read
          bytes = @directory.read(
            STATE_NAME,
            max_bytes: MAX_BYTES,
            missing: true
          )
          return [ default_state, nil ] unless bytes

          state = JSON.parse(bytes)
          malformed! unless bytes == canonical(state)
          validate!(state)
          [ state, bytes ]
        rescue JSON::ParserError, EncodingError
          malformed!
        end

        def default_state
          {
            "schema" => SCHEMA,
            "schema_version" => SCHEMA_VERSION,
            "module" => @module_name,
            "sequence_closed_through" => nil,
            "sequence_high_waters" => [],
            "retired_occurrence_digests" => [],
            "recovery_generation" => 0,
            "recovery_failure" => nil
          }
        end

        def validate!(state)
          required = %w[
            module recovery_failure recovery_generation
            retired_occurrence_digests schema schema_version
            sequence_closed_through sequence_high_waters
          ]
          valid = state.is_a?(Hash) &&
                  state.keys.sort == required.sort &&
                  state["schema"] == SCHEMA &&
                  state["schema_version"] == SCHEMA_VERSION &&
                  state["module"] == @module_name &&
                  state["sequence_high_waters"].is_a?(Array) &&
                  state["sequence_high_waters"].size <=
                    MAX_SEQUENCE_HIGH_WATERS &&
                  state["retired_occurrence_digests"].is_a?(Array) &&
                  state["retired_occurrence_digests"].size <=
                    MAX_RETIRED_OCCURRENCES &&
                  state["recovery_generation"].is_a?(Integer) &&
                  state["recovery_generation"] >= 0
          malformed! unless valid
          if state["sequence_closed_through"]
            timestamp(state["sequence_closed_through"])
          end
          digests = state.fetch("sequence_high_waters").map do |entry|
            validate_sequence!(entry)
            entry.fetch("identity_digest")
          end
          malformed! unless digests.uniq == digests
          retired = state.fetch("retired_occurrence_digests")
          malformed! unless retired == retired.sort &&
                            retired.uniq == retired &&
                            retired.all? do |digest|
                              digest.to_s.match?(/\A[0-9a-f]{64}\z/)
                            end
          validate_failure!(
            state["recovery_failure"],
            generation: state.fetch("recovery_generation")
          )
          malformed! if canonical(state).bytesize > MAX_BYTES
          true
        end

        def validate_sequence!(entry)
          valid = entry.is_a?(Hash) &&
                  entry.keys.sort == %w[
                    closed high_water identity_digest window_started_at
                  ] &&
                  entry["identity_digest"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
                  entry["high_water"].is_a?(Integer) &&
                  entry["high_water"].positive? &&
                  [ true, false ].include?(entry["closed"])
          malformed! unless valid
          timestamp(entry.fetch("window_started_at"))
        end

        def validate_failure!(failure, generation:)
          return if failure.nil?

          required = %w[
            error_class error_digest error_message failed_at failure_count
            generation job_id next_eligible_at occurrence_id operation
          ]
          valid = failure.is_a?(Hash) &&
                  failure.keys.sort == required.sort &&
                  failure["generation"].is_a?(Integer) &&
                  failure["generation"].positive? &&
                  failure["generation"] <= generation &&
                  failure["failure_count"].is_a?(Integer) &&
                  failure["failure_count"].positive? &&
                  !failure["operation"].to_s.empty? &&
                  !failure["error_class"].to_s.empty? &&
                  failure["error_class"].valid_encoding? &&
                  failure["error_class"].bytesize <=
                    MAX_ERROR_CLASS_BYTES &&
                  failure["error_message"].is_a?(String) &&
                  failure["error_message"].valid_encoding? &&
                  failure["error_message"].bytesize <= MAX_ERROR_BYTES &&
                  failure["error_digest"].to_s.match?(/\A[0-9a-f]{64}\z/)
          malformed! unless valid
          optional_nonempty(failure["occurrence_id"])
          optional_nonempty(failure["job_id"])
          timestamp(failure.fetch("failed_at"))
          timestamp(failure.fetch("next_eligible_at"))
        end

        def compact_sequences!(state)
          entries = state.fetch("sequence_high_waters")
          overflow = entries.size - MAX_SEQUENCE_HIGH_WATERS
          return if overflow <= 0

          removable = entries.select do |entry|
            entry.fetch("closed")
          end.sort_by { |entry| entry.fetch("window_started_at") }
          if removable.size < overflow
            raise Hive::ConfigError,
                  "patrol sequence high-water index is full"
          end
          evicted = removable.first(overflow)
          evicted.each { |entry| entries.delete(entry) }
          floor = evicted.map do |entry|
            entry.fetch("window_started_at")
          end.max
          state["sequence_closed_through"] = [
            state["sequence_closed_through"], floor
          ].compact.max
        end

        def sequence_digest(value)
          Digest::SHA256.hexdigest(value)
        end

        def occurrence_digest(value)
          Digest::SHA256.hexdigest(nonempty(value))
        end

        def sequenced_capture?(capture)
          reservation = capture.reservation
          %w[ordinary module_hook architecture].include?(
            reservation["kind"]
          ) &&
            reservation.key?("window_started_at") &&
            reservation.key?("attempt_generation")
        end

        def timestamp(value)
          time = value.is_a?(Time) ? value : Time.iso8601(value.to_s)
          time.utc.iso8601(6)
        rescue ArgumentError, TypeError
          malformed!
        end

        def positive(value)
          integer = Integer(value)
          malformed! unless integer.positive?
          integer
        rescue ArgumentError, TypeError
          malformed!
        end

        def nonnegative(value)
          integer = Integer(value)
          malformed! if integer.negative?
          integer
        rescue ArgumentError, TypeError
          malformed!
        end

        def nonempty(value)
          string = value.to_s
          malformed! if string.empty?
          string
        end

        def optional_nonempty(value)
          return nil if value.nil?
          nonempty(value)
        end

        def canonical(value)
          Hive::WorkflowPackage::CanonicalJSON.generate(value).b
        end

        def deep_copy(value)
          value && JSON.parse(JSON.generate(value))
        end

        def malformed!
          raise Hive::ConfigError,
                "patrol occurrence journal state is malformed"
        end
      end
    end
  end
end
