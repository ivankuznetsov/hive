require "hive/task_journal/envelope"

module Hive
  module Finalization
    class Error < Hive::Error; end
    class InvalidEvent < Error; end
    class InvalidProducer < InvalidEvent; end
    class StaleEvidence < InvalidEvent; end

    module Event
      TYPES = %w[
        finalized
        finalize_attempt_adopted
        babysitter_activated
        babysitter_active
        babysitter_blocked
        head_superseded
        merge_ready
        merged
        no_pr_approved
        finalization_rearmed
        archive_ready
        cleanup_completed
      ].freeze

      PRODUCER_EVENTS = {
        "finalize_attempt" => %w[finalized finalize_attempt_adopted],
        "babysitter_job" => %w[
          babysitter_activated babysitter_active babysitter_blocked head_superseded merge_ready merged
        ],
        "reconciler" => %w[archive_ready cleanup_completed],
        "operator" => %w[no_pr_approved finalization_rearmed]
      }.freeze
      COORDINATES = %w[
        job_id repository pr_number pr_url head_sha head_generation finalize_attempt_id
      ].freeze
      TERMINAL_STATES = %w[merged approved_no_pr].freeze
      NO_PR_OUTCOMES = %w[abandonment superseded direct_landing].freeze

      module_function

      def finalization?(record)
        TYPES.include?(record["event_type"].to_s)
      end

      def validate!(record, records: [])
        type = record["event_type"].to_s
        raise InvalidEvent, "unknown finalization event_type #{type.inspect}" unless TYPES.include?(type)

        producer = validate_producer!(record, type)
        payload = record["payload"]
        raise InvalidEvent, "finalization event payload must be an object" unless payload.is_a?(Hash)
        validate_coordinates!(payload)

        require_relative "projection"
        current = Hive::Finalization::Projection.project(records: records)
        if type == "finalized"
          validate_finalized!(record, payload, current)
          return true
        end

        raise StaleEvidence, "finalization handoff is missing" if current.fetch("state") == "unfinalized"
        validate_task_generation!(record, current)
        coordinate_exceptions = case type
        when "head_superseded" then %w[head_sha head_generation]
        when "finalize_attempt_adopted" then [ "finalize_attempt_id" ]
        else []
        end
        validate_current_coordinates!(payload, current, except: coordinate_exceptions)

        case type
        when "finalize_attempt_adopted"
          validate_adoption!(record, producer, payload, current)
        when "head_superseded"
          validate_head_supersession!(payload, current)
        when "merge_ready"
          require_state!(current, %w[babysitter_active merge_ready], type)
        when "merged"
          require_state!(current, %w[finalized babysitter_active merge_ready blocked merged], type)
          require_non_empty!(payload, "merged_at")
        when "babysitter_activated", "babysitter_active"
          require_state!(current, %w[finalized babysitter_active blocked merge_ready], type)
        when "babysitter_blocked"
          validate_blocker!(payload["blocker"])
        when "no_pr_approved"
          require_state!(current, %w[finalized babysitter_active blocked merge_ready], type)
          unless NO_PR_OUTCOMES.include?(payload["outcome"].to_s)
            raise InvalidEvent, "unknown no-PR outcome #{payload['outcome'].inspect}"
          end
        when "finalization_rearmed"
          require_state!(current, [ "approved_no_pr" ], type)
        when "archive_ready"
          validate_archive_ready!(payload, current)
        when "cleanup_completed"
          require_state!(current, [ "archive_ready" ], type)
          unless payload["archive_ready_event_id"] == current.dig("evidence", "archive_ready_event_id")
            raise StaleEvidence, "cleanup receipt does not reference current archive_ready"
          end
        end
        validate_claim_fence!(producer, current) if producer["kind"] == "babysitter_job"
        true
      end

      def validate_producer!(record, type)
        producer = record["producer"]
        raise InvalidProducer, "finalization event requires a typed producer" unless producer.is_a?(Hash)

        kind = producer["kind"].to_s
        allowed = PRODUCER_EVENTS[kind]
        raise InvalidProducer, "unknown finalization producer #{kind.inspect}" unless allowed
        unless allowed.include?(type)
          raise InvalidProducer, "#{kind} cannot write #{type}"
        end

        case kind
        when "finalize_attempt"
          unless producer["attempt_id"] == record["attempt_id"]
            raise InvalidProducer, "finalize producer attempt does not match event attempt"
          end
        when "babysitter_job"
          require_non_empty!(producer, "job_id")
          fence = producer["claim_fence"]
          unless fence.is_a?(Integer) && fence.positive?
            raise InvalidProducer, "babysitter producer claim_fence must be positive"
          end
        when "reconciler"
          unless producer["name"] == "hive-finalization-reconciler-v1"
            raise InvalidProducer, "unknown reconciler identity"
          end
        when "operator"
          require_non_empty!(producer, "login")
          unless producer["channel"] == "local_tty" && !producer["uid"].nil?
            raise InvalidProducer, "operator producer requires local_tty uid/login identity"
          end
        end
        producer
      end

      def validate_coordinates!(payload)
        missing = COORDINATES.select do |key|
          value = payload[key]
          value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end
        raise InvalidEvent, "finalization event missing #{missing.join(', ')}" unless missing.empty?
        unless payload["pr_number"].is_a?(Integer) && payload["pr_number"].positive?
          raise InvalidEvent, "finalization pr_number must be positive"
        end
        unless payload["head_generation"].is_a?(Integer) && payload["head_generation"].positive?
          raise InvalidEvent, "finalization head_generation must be positive"
        end
        unless payload["head_sha"].to_s.match?(/\A[0-9a-f]{7,64}\z/)
          raise InvalidEvent, "finalization head_sha must be a commit SHA"
        end
      end

      def validate_finalized!(record, payload, current)
        unless payload["finalize_attempt_id"] == record["attempt_id"]
          raise InvalidEvent, "finalized handoff attempt does not match event attempt"
        end
        unless payload["head_generation"] == 1
          raise InvalidEvent, "a new finalized handoff must start at head_generation 1"
        end
        return if current.fetch("state") == "unfinalized"
        return if record["task_generation"].is_a?(Integer) &&
                  record["task_generation"] > current.fetch("task_generation")
        replacement_state = payload.dig("replacement_proof", "state")
        return if payload["supersedes_job_id"] == current["job_id"] &&
                  %w[CLOSED INVALID].include?(replacement_state) && payload["job_id"] != current["job_id"]

        raise StaleEvidence, "current finalization must be adopted or explicitly superseded"
      end

      def validate_task_generation!(record, current)
        return if record["task_generation"] == current["task_generation"]

        raise StaleEvidence, "stale task_generation for finalization event"
      end

      def validate_current_coordinates!(payload, current, except: [])
        (COORDINATES - except).each do |key|
          next if payload[key] == current[key]

          raise StaleEvidence, "stale finalization #{key}"
        end
      end

      def validate_adoption!(record, producer, payload, current)
        unless payload["finalize_attempt_id"] == record["attempt_id"] &&
               producer["attempt_id"] == record["attempt_id"]
          raise InvalidProducer, "attempt adoption must attach the current producer attempt"
        end
        if record["attempt_id"] == current["finalize_attempt_id"]
          raise StaleEvidence, "attempt adoption must use a fresh finalize attempt"
        end
      end

      def validate_head_supersession!(payload, current)
        if payload["head_sha"] == current["head_sha"]
          raise StaleEvidence, "head supersession requires a new head_sha"
        end
        unless payload["head_generation"] == current.fetch("head_generation") + 1
          raise StaleEvidence, "head supersession requires the next head_generation"
        end
      end

      def validate_archive_ready!(payload, current)
        unless TERMINAL_STATES.include?(current.fetch("state"))
          raise StaleEvidence, "archive_ready requires current terminal evidence"
        end
        unless payload["terminal_event_id"] == current.dig("evidence", "terminal_event_id")
          raise StaleEvidence, "archive_ready does not reference current terminal evidence"
        end
      end

      def validate_blocker!(blocker)
        unless blocker.is_a?(Hash) && !blocker["code"].to_s.empty? &&
               [ true, false ].include?(blocker["needs_human"]) && !blocker["source"].to_s.empty?
          raise InvalidEvent, "babysitter blocker has invalid shape"
        end
      end

      def validate_claim_fence!(producer, current)
        current_fence = current["claim_fence"]
        return unless current_fence && producer["claim_fence"] < current_fence

        raise StaleEvidence, "stale babysitter claim fence"
      end

      def require_state!(current, allowed, type)
        return if allowed.include?(current.fetch("state"))

        raise StaleEvidence, "#{type} is invalid from #{current.fetch('state')}"
      end

      def require_non_empty!(value, key)
        child = value[key]
        return unless child.nil? || (child.respond_to?(:empty?) && child.empty?)

        raise InvalidEvent, "finalization producer/event requires #{key}"
      end
    end
  end
end
