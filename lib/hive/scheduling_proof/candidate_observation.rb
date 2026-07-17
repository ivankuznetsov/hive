require "time"
require "hive/scheduling_proof/action_projector"
require "hive/scheduling_proof/reason"
require "hive/diagnostic_helpers"
require "hive/secret_patterns"

module Hive
  module SchedulingProof
    module CandidateObservation
      module_function

      def build(row:, reason:, observed_at:, eligible: false, queue_position: nil,
                evidence: {}, attempt_id: nil)
        source = row.respond_to?(:to_h) ? row.to_h : {}
        fetch = ->(key) { source[key] || source[key.to_s] }
        generation = fetch.call(:condition_task_generation)
        generation = 0 unless generation.is_a?(Integer) && generation >= 0
        normalized_reason = Reason.normalize(reason)
        action = ActionProjector.project(
          reason: normalized_reason,
          action_key: fetch.call(:action),
          command: fetch.call(:suggested_command),
          stage: fetch.call(:stage),
          task_generation: generation,
          attempt_id: attempt_id
        )
        {
          "project" => fetch.call(:project),
          "task_id" => fetch.call(:id),
          "task_slug" => fetch.call(:slug),
          "task_folder" => fetch.call(:folder),
          "workflow" => fetch.call(:workflow),
          "stage" => fetch.call(:stage),
          "task_generation" => generation,
          "attempt_id" => attempt_id,
          "reason" => normalized_reason,
          "observed_at" => coerce_time(observed_at).utc.iso8601(6),
          "eligible" => eligible == true,
          "queue_position" => queue_position,
          "action" => action
        }.merge(stringify(evidence))
      end

      def stringify(value)
        value.to_h.to_h do |key, child|
          normalized = if child.is_a?(Hash)
            stringify(child)
          elsif child.is_a?(Array)
            child.map { |entry| entry.is_a?(Hash) ? stringify(entry) : entry }
          elsif child.is_a?(String)
            Hive::DiagnosticHelpers.truncate(
              Hive::SecretPatterns.redact(child).gsub(/[\r\n\t]+/, " "), 500
            )
          else
            child
          end
          [ key.to_s, normalized ]
        end
      end

      def coerce_time(value)
        return value if value.is_a?(Time)

        Time.iso8601(value.to_s)
      end
    end
  end
end
